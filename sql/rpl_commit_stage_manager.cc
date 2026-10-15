/* Copyright (c) 2019, 2021, Oracle and/or its affiliates.

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU General Public License, version 2.0,
   as published by the Free Software Foundation.

   This program is also distributed with certain software (including
   but not limited to OpenSSL) that is licensed under separate terms,
   as designated in a particular file or component or in included license
   documentation.  The authors of MySQL hereby grant you an additional
   permission to link the program and your derivative works with the
   separately licensed software that they have included with MySQL.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License, version 2.0, for more details.

   You should have received a copy of the GNU General Public License
   along with this program; if not, write to the Free Software
   Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301  USA */

#include "my_hygon.h"
#include <algorithm>

#include "sql/binlog.h"
#include "sql/debug_sync.h"  // DEBUG_SYNC
#include "sql/rpl_commit_stage_manager.h"
#include "sql/rpl_rli_pdb.h"  // Slave_worker                    // Slave_worker
#include "sql/rpl_slave_commit_order_manager.h"  // Commit_order_manager

#include "sql/mysqld.h"
#include "mysql/components/services/log_builtins.h"
class Slave_worker;
class Commit_order_manager;

bool Commit_stage_manager::binlog_group_commit_stats_enabled = false;

int g_max_numa_num = 0;
bool g_binlog_numa_initialized = false;
thread_local int thread_numa_id = 0;
thread_local bool thd_numa_bin_log_switch = false;

#define YESNO(X) ((X) ? "yes" : "no")

bool Commit_stage_manager::Mutex_queue::append(THD *first) {
  DBUG_TRACE;
  DBUG_PRINT("enter", ("first: 0x%llx", (ulonglong)first));
  DBUG_PRINT("info",
             ("m_first: 0x%llx, &m_first: 0x%llx, m_last: 0x%llx",
              (ulonglong)m_first, (ulonglong)&m_first, (ulonglong)m_last));
  int32 count = 1;
  bool empty = (m_first == nullptr);

  *m_last = first;
  DBUG_PRINT("info",
             ("m_first: 0x%llx, &m_first: 0x%llx, m_last: 0x%llx",
              (ulonglong)m_first, (ulonglong)&m_first, (ulonglong)m_last));
  /*
    Go to the last THD instance of the list. We expect lists to be
    moderately short. If they are not, we need to track the end of
    the queue as well.
  */

  while (first->next_to_commit) {
    count++;
    first = first->next_to_commit;
  }
  m_size += count;

  m_last = &first->next_to_commit;
  DBUG_PRINT("info",
             ("m_first: 0x%llx, &m_first: 0x%llx, m_last: 0x%llx",
              (ulonglong)m_first, (ulonglong)&m_first, (ulonglong)m_last));
  assert(m_first || m_last == &m_first);
  DBUG_PRINT("return", ("empty: %s", YESNO(empty)));
  return empty;
}

std::pair<bool, THD *> Commit_stage_manager::Mutex_queue::pop_front() {
  DBUG_TRACE;
  lock();
  THD *result = m_first;
  bool more = true;
  /*
    We do not set next_to_commit to nullptr here since this is only used
    in the flush stage. We will have to call fetch_queue last here,
    and will then "cut" the linked list by setting the end of that
    queue to nullptr.
  */
  if (result) m_first = result->next_to_commit;
  if (m_first == nullptr) {
    more = false;
    m_last = &m_first;
  }
  assert(m_size.load() > 0);
  --m_size;
  assert(m_first || m_last == &m_first);
  unlock();
  DBUG_PRINT("return",
             ("result: 0x%llx, more: %s", (ulonglong)result, YESNO(more)));
  return std::make_pair(more, result);
}

void Commit_stage_manager::init(PSI_mutex_key key_LOCK_flush_queue,
                                PSI_mutex_key key_LOCK_sync_queue,
                                PSI_mutex_key key_LOCK_commit_queue,
                                PSI_mutex_key key_LOCK_done,
                                PSI_cond_key key_COND_done,
                                PSI_cond_key key_COND_flush_queue) {
  if (m_is_initialized) return;
  m_is_initialized = true;

  mysql_mutex_init(key_LOCK_done, &m_lock_done, MY_MUTEX_INIT_FAST);
  mysql_cond_init(key_COND_done, &m_stage_cond_binlog);
  mysql_cond_init(key_COND_done, &m_stage_cond_commit_order);
  mysql_cond_init(key_COND_flush_queue, &m_stage_cond_leader);
#ifndef NDEBUG
  leader_thd = nullptr;

  /**
    reuse key_COND_done 'cos a new PSI object would be wasteful in !NDEBUG
  */
  mysql_cond_init(key_COND_done, &m_cond_preempt);
#endif

  /**
    Initialize mutex for flush, sync and commit stage queue. The binlog flush
    stage and commit order flush stage share same mutex.
  */
  mysql_mutex_init(key_LOCK_flush_queue, &m_queue_lock[BINLOG_FLUSH_STAGE],
                   MY_MUTEX_INIT_FAST);
  mysql_mutex_init(key_LOCK_sync_queue, &m_queue_lock[SYNC_STAGE],
                   MY_MUTEX_INIT_FAST);
  mysql_mutex_init(key_LOCK_commit_queue, &m_queue_lock[COMMIT_STAGE],
                   MY_MUTEX_INIT_FAST);

  m_queue[BINLOG_FLUSH_STAGE].init(&m_queue_lock[BINLOG_FLUSH_STAGE]);
  m_queue[SYNC_STAGE].init(&m_queue_lock[SYNC_STAGE]);
  m_queue[COMMIT_STAGE].init(&m_queue_lock[COMMIT_STAGE]);
  m_queue[COMMIT_ORDER_FLUSH_STAGE].init(&m_queue_lock[BINLOG_FLUSH_STAGE]);

  if(!g_binlog_numa_initialized){
    return;
  }
  if(g_max_numa_num <= 0){
    g_binlog_numa_initialized = false;
    return;
  }

  try {
    m_numa_queue = new Mutex_queue[g_max_numa_num][STAGE_COUNTER];
  } catch (const std::bad_alloc&) {
    g_binlog_numa_initialized = false;
    return;
  }

  m_numa_queue_lock = (mysql_mutex_t (*)[STAGE_COUNTER-1])malloc(
           g_max_numa_num * sizeof(mysql_mutex_t[STAGE_COUNTER-1])
  );
  if (m_numa_queue_lock == NULL) {
    delete[] m_numa_queue;
    m_numa_queue = nullptr;
    g_binlog_numa_initialized = false;
    return;
  }

  for (int j = 0; j < g_max_numa_num; j++) {
    mysql_mutex_init(key_LOCK_flush_queue, &m_numa_queue_lock[j][BINLOG_FLUSH_STAGE],
                     MY_MUTEX_INIT_FAST);
    mysql_mutex_init(key_LOCK_sync_queue, &m_numa_queue_lock[j][SYNC_STAGE],
                     MY_MUTEX_INIT_FAST);
    mysql_mutex_init(key_LOCK_commit_queue, &m_numa_queue_lock[j][COMMIT_STAGE],
                     MY_MUTEX_INIT_FAST);
    m_numa_queue[j][BINLOG_FLUSH_STAGE].init(&m_numa_queue_lock[j][BINLOG_FLUSH_STAGE]);
    m_numa_queue[j][SYNC_STAGE].init(&m_numa_queue_lock[j][SYNC_STAGE]);
    m_numa_queue[j][COMMIT_STAGE].init(&m_numa_queue_lock[j][COMMIT_STAGE]);
    m_numa_queue[j][COMMIT_ORDER_FLUSH_STAGE].init(&m_numa_queue_lock[j][BINLOG_FLUSH_STAGE]);
  }
}

void Commit_stage_manager::deinit() {
  if (!m_is_initialized) return;
  m_is_initialized = false;

  for (size_t i = 0; i < STAGE_COUNTER - 1; ++i)
    mysql_mutex_destroy(&m_queue_lock[i]);

  if(g_binlog_numa_initialized){
    for (int j = 0; j < g_max_numa_num; j++) {
       for (size_t i = 0; i < STAGE_COUNTER - 1; ++i){
           mysql_mutex_destroy(&m_numa_queue_lock[j][i]);
       }
    }
    free(m_numa_queue_lock);
    m_numa_queue_lock = nullptr;
    delete[] m_numa_queue;
    m_numa_queue = nullptr;
  }
  mysql_cond_destroy(&m_stage_cond_binlog);
  mysql_cond_destroy(&m_stage_cond_commit_order);
  mysql_cond_destroy(&m_stage_cond_leader);
  mysql_mutex_destroy(&m_lock_done);
}

template <bool UseThreadMutex>
bool Commit_stage_manager::enroll_for_impl(
    StageID stage, THD *thd,
    mysql_mutex_t *stage_mutex, mysql_mutex_t *enter_mutex) {
  mysql_mutex_t *done_mutex =
      UseThreadMutex ? &thd->LOCK_commit_done : &m_lock_done;
  mysql_cond_t *order_cond =
      UseThreadMutex ? &thd->COND_commit_order : &m_stage_cond_commit_order;
  mysql_cond_t *done_cond =
      UseThreadMutex ? &thd->COND_commit_done : &m_stage_cond_binlog;

  DBUG_TRACE;

  // If the queue was empty: we're the leader for this batch
  DBUG_PRINT("debug",
             ("Enqueue 0x%llx to queue for stage %d", (ulonglong)thd, stage));

  int numa_id = 0;
  bool leader = false;
  if(thd_numa_bin_log_switch){
    numa_id = thd->thd_numa_id;
    lock_numa_queue(stage, numa_id);
    leader = m_numa_queue[numa_id][stage].append(thd);
  }else{
    lock_queue(stage);
    leader = m_queue[stage].append(thd);
  }

  /*
   if its FLUSH stage queue (BINLOG_FLUSH_STAGE or COMMIT_ORDER_FLUSH_STAGE)
   and not empty then this thread should not become leader as other queue
   already has leader. The leader acquires enter_mutex.
  */
  if (leader) {
    if (stage == COMMIT_ORDER_FLUSH_STAGE) {
      leader = m_queue[BINLOG_FLUSH_STAGE].is_empty();
    } else if (stage == BINLOG_FLUSH_STAGE &&
               !m_queue[COMMIT_ORDER_FLUSH_STAGE].is_empty()) {
      /*
        The current thread is the first one in the binlog queue, but there is
        already a leader for the commit order queue. Then we need to change
        leader, so the commit order leader changes to follower and the current
        threads becomes leader.

        The reason we need to change leader is that the commit order leader
        cannot be leader for binlog threads, since commit order threads have to
        leave the commit group before the binlog threads are done.

        The process to change leader is as follows:
        1. The first thread to enter the flush stage is a commit order thread.
           It becomes commit order leader.
        2. The commit order leader tries to acquire the stage mutex. This may
           take some time, since the mutex is held by the leader for the
           previous commit group.
        3. Meanwhile, a binlog thread enters the flush stage. It reaches this
           point, and waits for signal from the commit order leader.
        4. The commit order leader gets the stage mutex. Then it checks if any
           binlog thread entered the flush stage, finds that one did, and
           decides to change leader.
        5. The commit order leader signals the binlog leader, becomes follower,
           and waits for the commit to complete (just like other followers do).
        6. The binlog leader wakes up by the signal that the commit order leader
           sent in step 5, and performs the group commit.
      */
      CONDITIONAL_SYNC_POINT_FOR_TIMESTAMP("before_binlog_leader_wait");
      while (thd->tx_commit_pending)
        mysql_cond_wait(&m_stage_cond_leader,
                        &m_queue_lock[BINLOG_FLUSH_STAGE]);
    }
  }

  if(thd_numa_bin_log_switch){
    unlock_numa_queue(stage, numa_id);
  }else{
    unlock_queue(stage);
  }

  /* Notify next transaction in commit order that it can enter the queue. */
  if (stage == BINLOG_FLUSH_STAGE) {
    Commit_order_manager::finish_one(thd);
    CONDITIONAL_SYNC_POINT_FOR_TIMESTAMP("after_binlog_leader_wait");
  } else if (stage == COMMIT_ORDER_FLUSH_STAGE) {
    Commit_order_manager::finish_one(thd);
  }

  /*
    We do not need to unlock the stage_mutex if it is LOCK_log when rotating
    binlog caused by logging incident log event, since it should be held
    always during rotation.
  */
  bool need_unlock_stage_mutex =
      !(mysql_bin_log.is_rotating_caused_by_incident &&
        stage_mutex == mysql_bin_log.get_log_lock());

  /*
    The stage mutex can be nullptr if we are enrolling for the first
    stage.
  */
  if (stage_mutex && need_unlock_stage_mutex) mysql_mutex_unlock(stage_mutex);

#ifndef NDEBUG
  DBUG_PRINT("info", ("This is a leader thread: %d (0=n 1=y)", leader));

  DEBUG_SYNC(thd, "after_enrolling_for_stage");

  switch (stage) {
    case BINLOG_FLUSH_STAGE:
      DEBUG_SYNC(thd, "bgc_after_enrolling_for_flush_stage");
      break;
    case SYNC_STAGE:
      DEBUG_SYNC(thd, "bgc_after_enrolling_for_sync_stage");
      break;
    case COMMIT_STAGE:
      DEBUG_SYNC(thd, "bgc_after_enrolling_for_commit_stage");
      break;
    case COMMIT_ORDER_FLUSH_STAGE:
      break;
    default:
      // not reached
      assert(0);
  }

  DBUG_EXECUTE_IF("assert_leader", assert(leader););
  DBUG_EXECUTE_IF("assert_follower", assert(!leader););
#endif

  /*
    If the queue was not empty, we're a follower and wait for the
    leader to process the queue. If we were holding a mutex, we have
    to release it before going to sleep.
  */
  if (!leader) {
    CONDITIONAL_SYNC_POINT_FOR_TIMESTAMP("before_follower_wait");
    if (!UseThreadMutex) mysql_mutex_lock(&m_lock_done);
#ifndef NDEBUG
    /*
      Leader can be awaiting all-clear to preempt follower's execution.
      With setting the status the follower ensures it won't execute anything
      including thread-specific code.
    */
    if (UseThreadMutex) mysql_mutex_lock(&m_lock_done);
    thd->get_transaction()->m_flags.ready_preempt = 1;
    if (leader_await_preempt_status) mysql_cond_signal(&m_cond_preempt);
    if (UseThreadMutex) mysql_mutex_unlock(&m_lock_done);
#endif

    if (UseThreadMutex) mysql_mutex_lock(&thd->LOCK_commit_done);
    while (thd->tx_commit_pending) {
      if (stage == COMMIT_ORDER_FLUSH_STAGE) {
        mysql_cond_wait(order_cond, done_mutex);
      } else {
        mysql_cond_wait(done_cond, done_mutex);
      }
    }
    mysql_mutex_unlock(done_mutex);

    return false;
  }

#ifndef NDEBUG
  if (stage == Commit_stage_manager::SYNC_STAGE)
    DEBUG_SYNC(thd, "bgc_between_flush_and_sync");
#endif

  bool need_lock_enter_mutex = false;
  if (leader && enter_mutex != nullptr) {
    /*
      We do not lock the enter_mutex if it is LOCK_log when rotating binlog
      caused by logging incident log event, since it is already locked.
    */
    need_lock_enter_mutex = !(mysql_bin_log.is_rotating_caused_by_incident &&
                              enter_mutex == mysql_bin_log.get_log_lock());

    if (need_lock_enter_mutex)
      mysql_mutex_lock(enter_mutex);
    else
      mysql_mutex_assert_owner(enter_mutex);
  }

  if (stage == COMMIT_ORDER_FLUSH_STAGE) {
    CONDITIONAL_SYNC_POINT_FOR_TIMESTAMP(
        "after_commit_order_thread_becomes_leader");
    lock_queue(stage);

    if (!m_queue[BINLOG_FLUSH_STAGE].is_empty()) {
      if (need_lock_enter_mutex) mysql_mutex_unlock(enter_mutex);

      THD *binlog_leader = m_queue[BINLOG_FLUSH_STAGE].get_leader();
      binlog_leader->tx_commit_pending = false;

      mysql_cond_signal(&m_stage_cond_leader);
      unlock_queue(stage);

      mysql_mutex_lock(done_mutex);
      /* wait for signal from binlog leader */
      CONDITIONAL_SYNC_POINT_FOR_TIMESTAMP(
          "before_commit_order_leader_waits_for_binlog_leader");
      while (thd->tx_commit_pending)
        mysql_cond_wait(order_cond, done_mutex);
      mysql_mutex_unlock(done_mutex);

      leader = false;
      return leader;
    }
  }

  return leader;
}

bool Commit_stage_manager::enroll_for(StageID stage, THD *thd,
                                      mysql_mutex_t *stage_mutex,
                                      mysql_mutex_t *enter_mutex) {
  if (my_cpu_is_hygon()) {
    return enroll_for_impl<true>(stage, thd, stage_mutex, enter_mutex);
  }
  return enroll_for_impl<false>(stage, thd, stage_mutex, enter_mutex);
}

THD *Commit_stage_manager::Mutex_queue::fetch_and_empty_acquire_lock() {
  lock();
  THD *ret = fetch_and_empty();
  unlock();
  return ret;
}

THD *Commit_stage_manager::Mutex_queue::fetch_and_empty_skip_acquire_lock() {
  assert_owner();
  return fetch_and_empty();
}

THD *Commit_stage_manager::Mutex_queue::fetch_and_empty() {
  DBUG_TRACE;
  DBUG_PRINT("enter",
             ("m_first: 0x%llx, &m_first: 0x%llx, m_last: 0x%llx",
              (ulonglong)m_first, (ulonglong)&m_first, (ulonglong)m_last));
  THD *result = m_first;
  m_first = nullptr;
  m_last = &m_first;
  DBUG_PRINT("info",
             ("m_first: 0x%llx, &m_first: 0x%llx, m_last: 0x%llx",
              (ulonglong)m_first, (ulonglong)&m_first, (ulonglong)m_last));
  DBUG_PRINT("info", ("fetched queue of %d transactions", m_size.load()));
  DBUG_PRINT("return", ("result: 0x%llx", (ulonglong)result));
  assert(m_size.load() >= 0);
  m_size.store(0);
  return result;
}

void Commit_stage_manager::wait_count_or_timeout(ulong count, long usec,
                                                 StageID stage) {
  long to_wait = DBUG_EVALUATE_IF("bgc_set_infinite_delay", LONG_MAX, usec);
  /*
    For testing purposes while waiting for inifinity
    to arrive, we keep checking the queue size at regular,
    small intervals. Otherwise, waiting 0.1 * infinite
    is too long.
   */
  long delta = DBUG_EVALUATE_IF("bgc_set_infinite_delay", 100000,
                                std::max<long>(1, (to_wait * 0.1)));

  if(thd_numa_bin_log_switch){
     int numa_id = thread_numa_id;
      while (
          to_wait > 0 &&
          (count == 0 || static_cast<ulong>(m_numa_queue[numa_id][stage].get_size()) < count)) {
#ifndef NDEBUG
      if (current_thd) DEBUG_SYNC(current_thd, "bgc_wait_count_or_timeout");
#endif
       my_sleep(delta);
       to_wait -= delta;
     }
  }else{
     while (
         to_wait > 0 &&
         (count == 0 || static_cast<ulong>(m_queue[stage].get_size()) < count)) {
#ifndef NDEBUG
       if (current_thd) DEBUG_SYNC(current_thd, "bgc_wait_count_or_timeout");
#endif
       my_sleep(delta);
       to_wait -= delta;
     }
  }
}

void Commit_stage_manager::update_group_commit_stats(StageID stage,
                                                     int32 count) {
  if (!binlog_group_commit_stats_enabled) return;

  /* COMMIT_ORDER_FLUSH_STAGE is not shown by SHOW STATUS. */
  if (count <= 0 || stage == COMMIT_ORDER_FLUSH_STAGE) return;

  Binlog_group_commit_stats &stats = m_group_commit_stats[stage];
  stats.group_count.fetch_add(1, std::memory_order_relaxed);
  stats.transaction_count.fetch_add(static_cast<ulonglong>(count),
                                    std::memory_order_relaxed);
}

THD *Commit_stage_manager::fetch_queue_acquire_lock(StageID stage) {
  DBUG_PRINT("debug", ("Fetching queue for stage %d", stage));
  /*
    The size of the queue is the size of the group taken from it, and it is
    reset by the fetch, so read it while the queue lock is held.
  */
  m_queue[stage].lock();
  const int32 count = m_queue[stage].get_size();
  THD *first = m_queue[stage].fetch_and_empty_skip_acquire_lock();
  m_queue[stage].unlock();
  update_group_commit_stats(stage, count);
  return first;
}

THD *Commit_stage_manager::fetch_queue_skip_acquire_lock(StageID stage) {
  DBUG_PRINT("debug", ("Fetching queue for stage %d", stage));
  /* The caller holds the queue lock, see fetch_queue_acquire_lock(). */
  const int32 count = m_queue[stage].get_size();
  THD *first = m_queue[stage].fetch_and_empty_skip_acquire_lock();
  update_group_commit_stats(stage, count);
  return first;
}

THD *Commit_stage_manager::fetch_numa_queue_acquire_lock(StageID stage, int numa_id) {
  DBUG_PRINT("debug", ("Fetching queue for stage %d", stage));
  return m_numa_queue[numa_id][stage].fetch_and_empty_acquire_lock();
}

THD *Commit_stage_manager::fetch_numa_queue_skip_acquire_lock(StageID stage, int numa_id) {
  DBUG_PRINT("debug", ("Fetching queue for stage %d", stage));
  return m_numa_queue[numa_id][stage].fetch_and_empty_skip_acquire_lock();
}

THD *Commit_stage_manager::fetch_sync_queue_acquire_lock(StageID stage, int numa_id, bool *skip_sync) {
  DBUG_PRINT("debug", ("Fetching queue for stage %d", stage));
  THD *ret = nullptr;
  int sync_size = 0;
  for (int j = 0; j < g_max_numa_num; j++) {
    m_numa_queue[j][stage].lock();
    sync_size = m_numa_queue[j][stage].get_size();
    if(j == numa_id){
      if( m_numa_queue[j][SYNC_STAGE].get_last_sync_queue_size() == sync_size){
           *skip_sync = true;
      }
      m_numa_queue[j][SYNC_STAGE].set_last_sync_queue_size(0);
      ret = m_numa_queue[numa_id][stage].fetch_and_empty_skip_acquire_lock();
    }else{
      m_numa_queue[j][SYNC_STAGE].set_last_sync_queue_size(sync_size);
    }
    m_numa_queue[j][stage].unlock();
  }
  return ret;
}

void Commit_stage_manager::process_final_stage_for_ordered_commit_group(
    THD *first) {
  if (first != nullptr) {
    gtid_state->update_commit_group(first);
    signal_done(first, Commit_stage_manager::COMMIT_ORDER_FLUSH_STAGE);
  }
}

template <bool UseThreadMutex>
void Commit_stage_manager::signal_done_impl(THD *queue, StageID stage) {
  if (!UseThreadMutex) {
    mysql_mutex_lock(&m_lock_done);

    for (THD *thd = queue; thd; thd = thd->next_to_commit) {
      thd->tx_commit_pending = false;
    }

    /* if thread belong to commit order wake only commit order queue threads */
    if (stage == COMMIT_ORDER_FLUSH_STAGE)
      mysql_cond_broadcast(&m_stage_cond_commit_order);
    else
      mysql_cond_broadcast(&m_stage_cond_binlog);

    mysql_mutex_unlock(&m_lock_done);
  } else {
    THD *cur = queue;
    THD *next = nullptr;

    while (cur) {
      /*
        Fetch next pointer before wake cur, since cur may quit or be reused
        before we fetch its next_to_commit.
      */
      next = cur->next_to_commit;

      mysql_mutex_lock(&cur->LOCK_commit_done);
      cur->tx_commit_pending = false;

      if (stage == COMMIT_ORDER_FLUSH_STAGE)
        mysql_cond_signal(&cur->COND_commit_order);
      else
        mysql_cond_signal(&cur->COND_commit_done);

      mysql_mutex_unlock(&cur->LOCK_commit_done);

      cur = next;
    }
  }
}

void Commit_stage_manager::signal_done(THD *queue, StageID stage) {
  if (my_cpu_is_hygon()) {
    return signal_done_impl<true>(queue, stage);
  }
  return signal_done_impl<false>(queue, stage);
}

#ifndef NDEBUG
void Commit_stage_manager::clear_preempt_status(THD *head) {
  assert(head);

  mysql_mutex_lock(&m_lock_done);
  while (!head->get_transaction()->m_flags.ready_preempt) {
    leader_await_preempt_status = true;
    mysql_cond_wait(&m_cond_preempt, &m_lock_done);
  }
  leader_await_preempt_status = false;
  mysql_mutex_unlock(&m_lock_done);
}
#endif

Commit_stage_manager &Commit_stage_manager::get_instance() {
  static Commit_stage_manager shared_instance;
  return shared_instance;
}
