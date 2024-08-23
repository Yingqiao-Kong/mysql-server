/*****************************************************************************

Copyright (c) 1996, 2021, Oracle and/or its affiliates.

This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License, version 2.0, as published by the
Free Software Foundation.

This program is also distributed with certain software (including but not
limited to OpenSSL) that is licensed under separate terms, as designated in a
particular file or component or in included license documentation. The authors
of MySQL hereby grant you an additional permission to link the program and
your derivative works with the separately licensed software that they have
included with MySQL.

This program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. See the GNU General Public License, version 2.0,
for more details.

You should have received a copy of the GNU General Public License along with
this program; if not, write to the Free Software Foundation, Inc.,
51 Franklin St, Fifth Floor, Boston, MA 02110-1301  USA

*****************************************************************************/

/** @file include/trx0sys.h
 Transaction system

 Created 3/26/1996 Heikki Tuuri
 *******************************************************/

#ifndef trx0sys_h
#define trx0sys_h

#include "univ.i"

#include "buf0buf.h"
#include "fil0fil.h"
#include "trx0types.h"
#ifndef UNIV_HOTBACKUP
#include "mem0mem.h"
#include "mtr0mtr.h"
#include "page0types.h"
#include "ut0byte.h"
#include "ut0lst.h"
#include "ut0mutex.h"
#endif /* !UNIV_HOTBACKUP */
#include <atomic>
#include <vector>
#include "trx0trx.h"
#include "lf.h"

#ifndef UNIV_HOTBACKUP
typedef UT_LIST_BASE_NODE_T(trx_t) trx_ut_list_t;

// Forward declaration
class ReadView;

/** The transaction system */
extern trx_sys_t *trx_sys;

trx_t *current_trx();

struct rw_trx_hash_element_t {
  rw_trx_hash_element_t() : id(0), trx(nullptr) {
    mutex_create(LATCH_ID_RW_TRX_HASH_ELEMENT, &mutex);
  }

  ~rw_trx_hash_element_t() { mutex_free(&mutex); }

  trx_id_t id; /* lf_hash_init() relies on this to be first in the struct */

  /** Transaction serialization number.
  Assigned shortly before the transaction is moved to COMMITTED_IN_MEMORY
  state. Initially set to TRX_ID_MAX. */
  std::atomic<trx_id_t> no;
  trx_t *trx;
  ib_mutex_t mutex;
};

/** Wrapper around LF_HASH to store set of in memory read-write
transactions. */

class rw_trx_hash_t {
  LF_HASH hash;

  template <typename T>
  using walk_action = bool(rw_trx_hash_element_t *element, T *action);

  /** Constructor callback for lock-free allocator.

  Object is just allocated and is not yet accessible via rw_trx_hash by
  concurrent threads. Object can be reused multiple times before it is freed.
  Every time object is being reused initializer() callback is called. */

  static void rw_trx_hash_constructor(uchar *arg) {
    new (arg + LF_HASH_OVERHEAD) rw_trx_hash_element_t();
  }

  /** Destructor callback for lock-free allocator.

  Object is about to be freed and is not accessible via rw_trx_hash by
  concurrent threads. */

  static void rw_trx_hash_destructor(uchar *arg) {
    reinterpret_cast<rw_trx_hash_element_t *>(arg + LF_HASH_OVERHEAD)
        ->~rw_trx_hash_element_t();
  }

  /** Destructor callback for lock-free allocator.

  This destructor is used at shutdown. It frees remaining transaction
  objects.

  XA PREPARED transactions may remain if they haven't been committed or
  rolled back. ACTIVE transactions may remain if startup was interrupted or
  server is running in read-only mode or for certain srv_force_recovery
  levels. */

  static void rw_trx_hash_shutdown_destructor(uchar *arg) {
    rw_trx_hash_element_t *element =
        reinterpret_cast<rw_trx_hash_element_t*>(arg + LF_HASH_OVERHEAD);

    element->~rw_trx_hash_element_t();
  }

  /** Initializer callback for lock-free hash.

  Object is not yet accessible via rw_trx_hash by concurrent threads, but is
  about to become such. Object id can be changed only by this callback and
  remains the same until all pins to this object are released.

  Object trx can be changed to 0 by erase() under object mutex protection,
  which indicates it is about to be removed from lock-free hash and become
  not accessible by concurrent threads. */

  static void rw_trx_hash_initializer(rw_trx_hash_element_t *element,
                                      trx_t *trx) {
    ut_ad(element->trx == 0);
    element->trx = trx;
    element->id = trx->id;
    element->no = TRX_ID_MAX;
    trx->rw_trx_hash_element = element;
  }

  /** Gets LF_HASH pins.

  Pins are used to protect object from being destroyed or reused. They are
  normally stored in trx object for quick access. If caller doesn't have trx
  available, we try to get it using currnet_trx(). If caller doesn't have trx
  at all, temporary pins are allocated. */

  LF_PINS *get_pins(trx_t *trx) {
    if (!trx->rw_trx_hash_pins) {
      trx->rw_trx_hash_pins = lf_hash_get_pins(&hash);
      ut_a(trx->rw_trx_hash_pins != nullptr);
    }
    return trx->rw_trx_hash_pins;
  }

  template <typename T> struct eliminate_duplicates_arg {
    trx_ids_t ids;
    walk_action<T> *action;
    T *argument;
    eliminate_duplicates_arg(size_t size, walk_action<T> *act, T *arg):
      action(act), argument(arg) { ids.reserve(size); }
  };

  template <typename T>
  static bool eliminate_duplicates(rw_trx_hash_element_t *element,
                                   eliminate_duplicates_arg<T> *arg) {
    for (trx_ids_t::iterator it = arg->ids.begin();
         it != arg->ids.end(); it++) {
      if (*it == element->id)
        return false;
    }
    arg->ids.push_back(element->id);
    return arg->action(element, arg->argument);
  }

#ifdef UNIV_DEBUG
  template <typename T> struct debug_iterator_arg {
    walk_action<T> *action;
    T *argument;
  };

  static void validate_element(trx_t *trx) {
    ut_ad(!trx->read_only || !trx->rsegs.m_redo.rseg);
    ut_ad(!trx_is_autocommit_non_locking(trx));
    /* trx->state can be anything except TRX_STATE_NOT_STARTED */
    mutex_enter(&trx->mutex);
    ut_ad(trx_state_eq(trx, TRX_STATE_ACTIVE) ||
          trx_state_eq(trx, TRX_STATE_COMMITTED_IN_MEMORY) ||
          trx_state_eq(trx, TRX_STATE_PREPARED));
    mutex_exit(&trx->mutex);
  }

  template <typename T>
  static bool debug_iterator(rw_trx_hash_element_t *element,
                            debug_iterator_arg<T> *arg) {
    mutex_enter(&element->mutex);
    if (element->trx) {
      validate_element(element->trx);
    }
    mutex_exit(&element->mutex);
    return arg->action(element, arg->argument);
  }
#endif

 public:
  void init() {
    lf_hash_init(&hash, sizeof(rw_trx_hash_element_t), LF_HASH_UNIQUE, 0,
                 sizeof(trx_id_t), nullptr, &my_charset_bin);
    hash.alloc.constructor = rw_trx_hash_constructor;
    hash.alloc.destructor = rw_trx_hash_destructor;
    hash.initialize =
        reinterpret_cast<lf_hash_init_func *>(rw_trx_hash_initializer);
  }

  void destroy() {
    hash.alloc.destructor = rw_trx_hash_shutdown_destructor;
    lf_hash_destroy(&hash);
  }

  /** Releases LF_HASH pins.

  Must be called by thread that owns trx_t object when the latter is being
  "detached" from thread (e.g. released to the pool by trx_free()). Can be
  called earlier if thread is expected not to use rw_trx_hash.

  Since pins are not allowed to be transferred to another thread,
  initialisation thread calls this for recovered transactions. */

  void put_pins(trx_t *trx) {
    if (trx->rw_trx_hash_pins) {
      lf_hash_put_pins(trx->rw_trx_hash_pins);
      trx->rw_trx_hash_pins = nullptr;
    }
  }

  /** Finds trx object in lock-free hash with given id.

  Only ACTIVE or PREPARED trx objects may participate in hash. Nevertheless
  the transaction may get committed before this method returns.

  With do_ref_count == false the caller may dereference returned trx pointer
  only if lock_sys->mutex was acquired before calling find().

  With do_ref_count == true caller may dereference trx even if it is not
  holding lock_sys->mutex. Caller is responsible for calling
  trx_release_reference() when it is done playing with trx.

  Ideally this method should get caller rw_trx_hash_pins along with trx
  object as a parameter, similar to insert() and erase(). However most
  callers lose trx early in their call chains and it is not that easy to pass
  them through.

  So we take more expensive approach: get trx through current_thd()->ha_data.
  Some threads don't have trx attached to THD, and at least server
  initialisation thread, fts_optimize_thread, srv_master_thread,
  dict_stats_thread, srv_monitor_thread, btr_defragment_thread don't even
  have THD at all. For such cases we allocate pins only for duration of
  search and free them immediately.

  This has negative performance impact and should be fixed eventually (by
  passing caller_trx as a parameter). Still stream of DML is more or less Ok.

  @return
    @retval 0 not found
    @retval pointer to trx */

  trx_t *find(trx_t *caller_trx, trx_id_t trx_id, bool do_ref_count = false) {
    if (!trx_id) {
      return nullptr;
    }

    trx_t *trx = nullptr;
    LF_PINS *pins = caller_trx ? get_pins(caller_trx) : lf_hash_get_pins(&hash);
    ut_a(pins != nullptr);

    auto element = reinterpret_cast<rw_trx_hash_element_t *>(
        lf_hash_search(&hash, pins, reinterpret_cast<const void *>(&trx_id),
                       sizeof(trx_id_t)));

    if (element) {
      mutex_enter(&element->mutex);

      lf_hash_search_unpin(pins);
      if ((trx = element->trx)) {
        ut_d(validate_element(trx));
        if (do_ref_count) {
          trx->reference();
        }
      }

      mutex_exit(&element->mutex);
    } else {
      lf_hash_search_unpin(pins);
    }

    if (!caller_trx) {
      lf_hash_put_pins(pins);
    }

    return trx;
  }

  /** Inserts trx to lock-free hash.

  Object becomes accessible via rw_trx_hash. */

  void insert(trx_t *trx) {
    ut_d(validate_element(trx));

    int res =
        lf_hash_insert(&hash, get_pins(trx), reinterpret_cast<void *>(trx));
    ut_a(res == 0);
  }

  /** Removes trx from lock-free hash.

  Object becomes not accessible via rw_trx_hash. But it still can be pinned
  by concurrent find(), which is supposed to release it immediately after
  it sees object trx is 0. */

  void erase(trx_t *trx) {
    ut_d(validate_element(trx));

    mutex_enter(&trx->rw_trx_hash_element->mutex);
    trx->rw_trx_hash_element->trx = nullptr;
    mutex_exit(&trx->rw_trx_hash_element->mutex);

    int res = lf_hash_delete(&hash, get_pins(trx),
                             reinterpret_cast<const void *>(&trx->id),
                             sizeof(trx_id_t));
    ut_a(res == 0);
  }

  /** Returns the number of elements in the hash.

  The number is exact only if hash is protected against concurrent
  modifications (e.g. single threaded startup or hash is protected
  by some mutex). Otherwise the number may be used as a hint only,
  because it may change even before this method returns. */

  uint32_t size() { return hash.count.load(std::memory_order_relaxed); }

  /** Iterates the hash.

  @param caller_trx  used to get/set pins
  @param action      called for every element in hash
  @param argument    opque argument passed to action

  May return the same element multiple times if hash is under contention.
  If caller doesn't like to see the same transaction multiple times, it has
  to call iterate_no_dups() instead.

  May return element with committed transaction. If caller doesn't like to
  see committed transactions, it has to skip those under element mutex:

    mutex_enter(&element->mutex);
    if (trx_t trx = element->trx)
    {
      // trx is protected against commit in this branch
    }
    mutex_exit(&element->mutex);

  May miss concurrently inserted transactions.

  @return
    @retval 0 iteration completed successfully
    @retval 1 iteration was interrupted (action returned 1) */

  template <typename T>
  int iterate(trx_t *caller_trx, walk_action<T> *action, T *argument = nullptr) {
    LF_PINS *pins = caller_trx ? get_pins(caller_trx) : lf_hash_get_pins(&hash);
    ut_a(pins);

#ifdef UNIV_DEBUG
    debug_iterator_arg<T> debug_arg = { action, argument };
    action = reinterpret_cast<decltype(action)>(debug_iterator<T>);
    argument = reinterpret_cast<T*>(&debug_arg);
#endif

    int res = lf_hash_iterate(&hash, pins,
        reinterpret_cast<hash_walk_action>(action),
        const_cast<void*>(static_cast<const void*>(argument)));

    if (!caller_trx) {
      lf_hash_put_pins(pins);
    }
    return res;
  }

  template <typename T>
  int iterate(walk_action<T> *action, T *argument = nullptr) {
    return iterate(current_trx(), action, argument);
  }

  /** Iterates the hash and eliminates duplicate elements.

  @sa iterate() */

  template <typename T>
  int iterate_no_dups(trx_t *caller_trx, walk_action<T> *action,
                      T *argument = nullptr) {
    eliminate_duplicates_arg<T> arg(size() + 32, action, argument);
    return iterate(caller_trx, eliminate_duplicates<T>, &arg);
  }

  template <typename T>
  int iterate_no_dups(walk_action<T> *action, T *argument = nullptr) {
    return iterate_no_dups(current_trx(), action, argument);
  }
};

/** Checks if a page address is the trx sys header page.
@param[in]	page_id	page id
@return true if trx sys header page */
UNIV_INLINE
bool trx_sys_hdr_page(const page_id_t &page_id);

/** Creates and initializes the central memory structures for the transaction
 system. This is called when the database is started.
 @return min binary heap of rsegs to purge */
purge_pq_t *trx_sys_init_at_db_start(void);
/** Creates the trx_sys instance and initializes purge_queue and mutex. */
void trx_sys_create(void);
/** Creates and initializes the transaction system at the database creation. */
void trx_sys_create_sys_pages(void);

/** Find the page number in the TRX_SYS page for a given slot/rseg_id
@param[in]	rseg_id		slot number in the TRX_SYS page rseg array
@return page number from the TRX_SYS page rseg array */
page_no_t trx_sysf_rseg_find_page_no(ulint rseg_id);

/** Look for a free slot for a rollback segment in the trx system file copy.
@param[in,out]	mtr		mtr
@return slot index or ULINT_UNDEFINED if not found */
ulint trx_sysf_rseg_find_free(mtr_t *mtr);

/** Gets a pointer to the transaction system file copy and x-locks its page.
 @return pointer to system file copy, page x-locked */
UNIV_INLINE
trx_sysf_t *trx_sysf_get(mtr_t *mtr); /*!< in: mtr */

/** Gets the space of the nth rollback segment slot in the trx system
file copy.
@param[in]	sys_header	trx sys file copy
@param[in]	i		slot index == rseg id
@param[in]	mtr		mtr
@return space id */
UNIV_INLINE
space_id_t trx_sysf_rseg_get_space(trx_sysf_t *sys_header, ulint i, mtr_t *mtr);

/** Gets the page number of the nth rollback segment slot in the trx system
file copy.
@param[in]	sys_header	trx sys file copy
@param[in]	i		slot index == rseg id
@param[in]	mtr		mtr
@return page number, FIL_NULL if slot unused */
UNIV_INLINE
page_no_t trx_sysf_rseg_get_page_no(trx_sysf_t *sys_header, ulint i,
                                    mtr_t *mtr);

/** Sets the space id of the nth rollback segment slot in the trx system
file copy.
@param[in]	sys_header	trx sys file copy
@param[in]	i		slot index == rseg id
@param[in]	space		space id
@param[in]	mtr		mtr */
UNIV_INLINE
void trx_sysf_rseg_set_space(trx_sysf_t *sys_header, ulint i, space_id_t space,
                             mtr_t *mtr);

/** Set the page number of the nth rollback segment slot in the trx system
file copy.
@param[in]	sys_header	trx sys file copy
@param[in]	i		slot index == rseg id
@param[in]	page_no		page number, FIL_NULL if the slot is reset to
                                unused
@param[in]	mtr		mtr */
UNIV_INLINE
void trx_sysf_rseg_set_page_no(trx_sysf_t *sys_header, ulint i,
                               page_no_t page_no, mtr_t *mtr);

#ifdef UNIV_DEBUG
/* Flag to control TRX_RSEG_N_SLOTS behavior debugging. */
extern uint trx_rseg_n_slots_debug;
#endif
#endif /* !UNIV_HOTBACKUP */

/** Writes a trx id to an index page. In case that the id size changes in some
future version, this function should be used instead of mach_write_...
@param[in]	ptr	pointer to memory where written
@param[in]	id	id */
UNIV_INLINE
void trx_write_trx_id(byte *ptr, trx_id_t id);

#ifndef UNIV_HOTBACKUP
/** Reads a trx id from an index page. In case that the id size changes in
 some future version, this function should be used instead of
 mach_read_...
 @return id */
UNIV_INLINE
trx_id_t trx_read_trx_id(
    const byte *ptr); /*!< in: pointer to memory from where to read */

/** Persist transaction number limit below which all transaction GTIDs
are persisted to disk table.
@param[in]	gtid_trx_no	transaction number */
void trx_sys_persist_gtid_num(trx_id_t gtid_trx_no);

/** @return oldest transaction number yet to be committed. */
trx_id_t trx_sys_oldest_trx_no();

/** Get a list of all binlog prepared transactions.
@param[out]	trx_ids	all prepared transaction IDs. */
void trx_sys_get_binlog_prepared(std::vector<trx_id_t> &trx_ids);

/** Get current binary log positions stored.
@param[out]	file	binary log file name
@param[out]	offset	binary log file offset */
void trx_sys_read_binlog_position(char *file, uint64_t &offset);

/** Update binary log position if not already updated. This is called
by clone to update any stale binary log position if any transaction
is yet to update the binary log position in SE.
@param[in]	last_file	last noted binary log file name
@param[in]	last_offset	last noted binary log offset
@param[in]	file		current binary log file name
@param[in]	offset		current binary log file offset
@return true, if binary log position is updated with current. */
bool trx_sys_write_binlog_position(const char *last_file, uint64_t last_offset,
                                   const char *file, uint64_t offset);

/** Updates the offset information about the end of the MySQL binlog entry
which corresponds to the transaction being committed, external XA transaction
being prepared or rolled back. In a MySQL replication slave updates the latest
master binlog position up to which replication has proceeded.
@param[in]	trx	Current transaction
@param[in,out]	mtr	Mini-transaction for update */
void trx_sys_update_mysql_binlog_offset(trx_t *trx, mtr_t *mtr);

/** Shutdown/Close the transaction system. */
void trx_sys_close(void);

/** Determine if there are incomplete transactions in the system.
@return whether incomplete transactions need rollback */
UNIV_INLINE
bool trx_sys_need_rollback();

/** Reads number of recovered transactions which have state
equal to TRX_STATE_ACTIVE (so are not prepared transactions).
@return number of active recovered transactions */
size_t trx_sys_recovered_active_trxs_count();

/** Validates lists of transactions at the very beginning of the
pre-dd-shutdown phase. */
void trx_sys_before_pre_dd_shutdown_validate();

/** Validates lists of transactions at the very end of the
pre-dd-shutdown phase. */
void trx_sys_after_pre_dd_shutdown_validate();

/** Validates lists of transactions after all background threads
of InnoDB exited during shutdown of MySQL. */
void trx_sys_after_background_threads_shutdown_validate();

#endif /* !UNIV_HOTBACKUP */

/** Initialize trx_sys_undo_spaces, called once during srv_start(). */
void trx_sys_undo_spaces_init();

/** Free the resources occupied by trx_sys_undo_spaces,
called once during thread de-initialization. */
void trx_sys_undo_spaces_deinit();

/** The automatically created system rollback segment has this id */
#define TRX_SYS_SYSTEM_RSEG_ID 0

/** The offset of the transaction system header on the page */
#define TRX_SYS FSEG_PAGE_DATA

/** Transaction system header */
/*------------------------------------------------------------- @{ */
/** In old versions of InnoDB, this persisted the value of
get_max_trx_id(). Now, the field TRX_RSEG_MAX_TRX_ID in rollback
segment header pages and the fields TRX_UNDO_TRX_ID, TRX_UNDO_TRX_NO
in undo log pages are used instead. The field only exists for the
purpose of upgrading from older MySQL or MariaDB versions. */
#define TRX_SYS_TRX_ID_STORE 0
#define TRX_SYS_FSEG_HEADER     \
  8 /*!< segment header for the \
    tablespace segment the trx  \
    system is created into */
#define TRX_SYS_RSEGS (8 + FSEG_HEADER_SIZE)
/*!< the start of the array of
rollback segment specification
slots */
/*------------------------------------------------------------- @} */

/* Originally, InnoDB defined TRX_SYS_N_RSEGS as 256 but created only one
rollback segment.  It initialized some arrays with this number of entries.
We must remember this limit in order to keep file compatibility. */
constexpr size_t TRX_SYS_OLD_N_RSEGS = 256;

/* The system temporary tablespace was originally allocated rseg_id slot
numbers 1 through 32 in the TRX_SYS page.  But those slots were not used
because those Rollback segments were recreated at startup and after any
crash. These slots are now used for redo-enabled rollback segments.
The default number of rollback segments in the temporary tablespace
remains the same. */
constexpr size_t TRX_SYS_OLD_TMP_RSEGS = 32;

/** Maximum length of MySQL binlog file name, in bytes. */
#define TRX_SYS_MYSQL_LOG_NAME_LEN 512
/** Contents of TRX_SYS_MYSQL_LOG_MAGIC_N_FLD */
#define TRX_SYS_MYSQL_LOG_MAGIC_N 873422344

#if UNIV_PAGE_SIZE_MIN < 4096
#error "UNIV_PAGE_SIZE_MIN < 4096"
#endif
/** The offset of the MySQL binlog offset info in the trx system header */
#define TRX_SYS_MYSQL_LOG_INFO (UNIV_PAGE_SIZE - 1000)
#define TRX_SYS_MYSQL_LOG_MAGIC_N_FLD \
  0 /*!< magic number which is        \
    TRX_SYS_MYSQL_LOG_MAGIC_N         \
    if we have valid data in the      \
    MySQL binlog info */
#define TRX_SYS_MYSQL_LOG_OFFSET_HIGH \
  4 /*!< high 4 bytes of the offset   \
    within that file */
#define TRX_SYS_MYSQL_LOG_OFFSET_LOW                             \
  8                               /*!< low 4 bytes of the offset \
                                  within that file */
#define TRX_SYS_MYSQL_LOG_NAME 12 /*!< MySQL log file name */

/** Reserve next 8 bytes for transaction number up to which GTIDs
are persisted to table */
#define TRX_SYS_TRX_NUM_GTID \
  (TRX_SYS_MYSQL_LOG_INFO + TRX_SYS_MYSQL_LOG_NAME + TRX_SYS_MYSQL_LOG_NAME_LEN)
#define TRX_SYS_TRX_NUM_END = (TRX_SYS_TRX_NUM_GTID + 8)

/** Doublewrite buffer */
/** @{ */
/** The offset of the doublewrite buffer header on the trx system header page */
#define TRX_SYS_DOUBLEWRITE (UNIV_PAGE_SIZE - 200)
/*-------------------------------------------------------------*/
#define TRX_SYS_DOUBLEWRITE_FSEG \
  0 /*!< fseg header of the fseg \
    containing the doublewrite   \
    buffer */
#define TRX_SYS_DOUBLEWRITE_MAGIC FSEG_HEADER_SIZE
/*!< 4-byte magic number which
shows if we already have
created the doublewrite
buffer */
#define TRX_SYS_DOUBLEWRITE_BLOCK1 (4 + FSEG_HEADER_SIZE)
/*!< page number of the
first page in the first
sequence of 64
(= FSP_EXTENT_SIZE) consecutive
pages in the doublewrite
buffer */
#define TRX_SYS_DOUBLEWRITE_BLOCK2 (8 + FSEG_HEADER_SIZE)
/*!< page number of the
first page in the second
sequence of 64 consecutive
pages in the doublewrite
buffer */
#define TRX_SYS_DOUBLEWRITE_REPEAT \
  12 /*!< we repeat                \
     TRX_SYS_DOUBLEWRITE_MAGIC,    \
     TRX_SYS_DOUBLEWRITE_BLOCK1,   \
     TRX_SYS_DOUBLEWRITE_BLOCK2    \
     so that if the trx sys        \
     header is half-written        \
     to disk, we still may         \
     be able to recover the        \
     information */
/** If this is not yet set to TRX_SYS_DOUBLEWRITE_SPACE_ID_STORED_N,
we must reset the doublewrite buffer, because starting from 4.1.x the
space id of a data page is stored into
FIL_PAGE_ARCH_LOG_NO_OR_SPACE_ID. */
#define TRX_SYS_DOUBLEWRITE_SPACE_ID_STORED (24 + FSEG_HEADER_SIZE)

/*-------------------------------------------------------------*/
/** Contents of TRX_SYS_DOUBLEWRITE_MAGIC */
#define TRX_SYS_DOUBLEWRITE_MAGIC_N 536853855
/** Contents of TRX_SYS_DOUBLEWRITE_SPACE_ID_STORED */
#define TRX_SYS_DOUBLEWRITE_SPACE_ID_STORED_N 1783657386

/** Size of the doublewrite block in pages */
#define TRX_SYS_DOUBLEWRITE_BLOCK_SIZE FSP_EXTENT_SIZE

/** @} */

/** List of undo tablespace IDs. */
class Space_Ids : public std::vector<space_id_t, ut_allocator<space_id_t>> {
 public:
  void sort() { std::sort(begin(), end()); }

  bool contains(space_id_t id) {
    if (size() == 0) {
      return (false);
    }

    iterator it = std::find(begin(), end(), id);

    return (it != end());
  }

  iterator find(space_id_t id) { return (std::find(begin(), end(), id)); }
};

#ifndef UNIV_HOTBACKUP
/** The transaction system central memory data structure. */
struct trx_sys_t {
 private:
  /** The smallest number not yet assigned as a transaction id or transaction
  number. Accessed and updated with atomic operations. */
  char pad0[ut::INNODB_CACHE_LINE_SIZE];
  std::atomic<trx_id_t> m_max_trx_id;

  /** Solves race conditions between register_rw() and snapshot_ids()
  as well as race condition between assign_new_trx_no() and snapshot_ids().
  @sa register_rw()
  @sa assign_new_trx_no()
  @sa snapshot_ids() */
  char pad1[ut::INNODB_CACHE_LINE_SIZE];
  std::atomic<trx_id_t> m_rw_trx_hash_version;

  char pad2[ut::INNODB_CACHE_LINE_SIZE];

public:
  TrxSysMutex mutex; /*!< mutex protecting mysql_trx_list and gtid */

#ifdef UNIV_DEBUG
  trx_id_t rw_max_trx_no; /*!< Max trx number of read-write
                          transactions added for purge. */
#endif                    /* UNIV_DEBUG */

  char pad3[ut::INNODB_CACHE_LINE_SIZE]; /*!< To avoid false sharing */
  trx_ut_list_t mysql_trx_list; /*!< List of transactions created
                                for MySQL. All user transactions are
                                on mysql_trx_list. The rw_trx_hash
                                can contain system transactions and
                                recovered transactions that will not
                                be in the mysql_trx_list.
                                mysql_trx_list may additionally contain
                                transactions that have not yet been
                                started in InnoDB. */

  char pad4[ut::INNODB_CACHE_LINE_SIZE]; /*!< To avoid false sharing */
  Rsegs rsegs; /*!< Vector of pointers to rollback
               segments. These rsegs are iterated
               and added to the end under a read
               lock. They are deleted under a write
               lock while the vector is adjusted.
               They are created and destroyed in
               single-threaded mode. */

  Rsegs tmp_rsegs; /*!< Vector of pointers to rollback
                   segments within the temp tablespace;
                   This vector is created and destroyed
                   in single-threaded mode so it is not
                   protected by any mutex because it is
                   read-only during multi-threaded
                   operation. */

  /** Length of the TRX_RSEG_HISTORY list (update undo logs for committed
   * transactions). */
  std::atomic<uint64_t> rseg_history_len;
  bool is_shutdown;

  char pad5[ut::INNODB_CACHE_LINE_SIZE];
  /** Lock-free hash of in memory read-write transactions. */
  rw_trx_hash_t rw_trx_hash;

  char pad6[ut::INNODB_CACHE_LINE_SIZE];
  std::atomic<ulint> n_prepared_trx; /*!< Number of transactions currently
                                     in the XA PREPARED state */

  bool found_prepared_trx; /*!< True if XA PREPARED trxs are
                           found. */

  /** Determine if the specified transaction or any older one might
  be active.
  @param caller_trx  used to get/set pins
  @param id          transaction identifier
  @return whether any transaction not newer than id might be active*/
  bool find_same_or_older(trx_t *caller_trx, trx_id_t id) {
    return rw_trx_hash.iterate(caller_trx, find_same_or_older_callback, &id);
  }

  /** Returns the minimum trx->no in hash */
  trx_id_t get_min_trx_no() {
    trx_id_t no;
    while ((no = get_max_trx_id()) != get_rw_trx_hash_version()) {
      ut_delay(1);
    }

    rw_trx_hash.iterate(get_min_trx_no_callback, &no);
    return no;
  }

  /** Determines the maximum transaction id.
  @return maximum currently allocated trx id */
  trx_id_t get_max_trx_id(void) {
    return m_max_trx_id.load(std::memory_order_relaxed);
  }

  /** Allocates and assigns new transaction serialisation number.

  There's a gap between m_max_trx_id increment and transaction serialisation
  number becoming visible through rw_trx_hash. While we're in this gap
  concurrent thread may come and do MVCC snapshot without seeing allocated
  but not yet assigned serialisation number. Then at some point purge thread
  may clone this view. As a result it won't see newly allocated serialisation
  number and may remove "unnecessary" history data of this transaction from
  rollback segments.

  m_rw_trx_hash_version is intended to solve this problem. MVCC snapshot has
  to wait until m_max_trx_id == m_rw_trx_hash_version, which effectively
  means that all transaction serialisation numbers up to m_max_trx_id are
  available through rw_trx_hash.

  We rely on refresh_rw_trx_hash_version() to issue RELEASE memory barrier so
  that m_rw_trx_hash_version increment happens after
  trx->rw_trx_hash_element->no becomes visible through rw_trx_hash.

  @param trx transaction */
  void assign_new_trx_no(trx_t *trx) {
    trx->no = get_new_trx_id_no_refresh();
    trx->rw_trx_hash_element->no.store(trx->no, std::memory_order_relaxed);
    refresh_rw_trx_hash_version();
  }

  /** Takes MVCC snapshot.

  To reduce malloc probablility we reserve rw_trx_hash.size() + 32 elements
  in ids.

  For details about get_rw_trx_hash_version() != get_max_trx_id() spin
  @sa register_rw() and @sa assign_new_trx_no().

  We rely on get_rw_trx_hash_version() to issue ACQUIRE memory barrier so
  that loading of m_rw_trx_hash_version happens before accessing rw_trx_hash.

  To optimise snapshot creation rw_trx_hash.iterate() is being used instead
  of rw_trx_hash.iterate_no_dups(). It means that some transaction
  identifiers may appear multiple times in ids.

  @param[in,out] caller_trx used to get access to rw_trx_hash_pins
  @param[out]    ids        array to store registered transaction identifiers
  @param[out]    max_trx_id variable to store m_max_trx_id value
  @param[out]    min_trx_no variable to store min(trx->no) value */
  void snapshot_ids(trx_t *caller_trx, trx_ids_t *ids, trx_id_t *max_trx_id,
                    trx_id_t *min_trx_no) {
    ut_ad(!mutex_own(&mutex));
    snapshot_ids_arg arg(ids);

    while ((arg.m_id = get_rw_trx_hash_version()) != get_max_trx_id()) {
      ut_delay(1);
    }

    arg.m_no = arg.m_id;
    ids->clear();
    ids->reserve(rw_trx_hash.size() + 32);

    rw_trx_hash.iterate(caller_trx, copy_one_id, &arg);

    *max_trx_id = arg.m_id;
    *min_trx_no = arg.m_no;
  }

  void init_max_trx_id(trx_id_t value) {
    m_max_trx_id = value;
    m_rw_trx_hash_version.store(value, std::memory_order_relaxed);
  }

  /** Registers read-write transaction.

  Transaction becomes visible to MVCC.
  There's a gap between m_max_trx_id increment and transaction becoming
  visible through rw_trx_hash. While we're in this gap concurrent thread may
  come and do MVCC snapshot. As a result concurrent read view will be able to
  observe records owned by this transaction even before it was committed.

  m_rw_trx_hash_version is intended to solve this problem. MVCC snapshot has
  to wait until m_max_trx_id == m_rw_trx_hash_version, which effectively
  means that all transactions up to m_max_trx_id are available through
  rw_trx_hash.

  We rely on refresh_rw_trx_hash_version() to issue RELEASE memory barrier so
  that m_rw_trx_hash_version increment happens after transaction becomes
  visible through rw_trx_hash. */
  void register_rw(trx_t *trx) {
    trx->id = get_new_trx_id_no_refresh();
    rw_trx_hash.insert(trx);
    refresh_rw_trx_hash_version();
  }

  /** Deregisters read-write transaction. */
  void deregister_rw(trx_t *trx) {
    rw_trx_hash.erase(trx);
  }

  trx_t *find(trx_t *caller_trx, trx_id_t id, bool do_ref_count = true) {
    return rw_trx_hash.find(caller_trx, id, do_ref_count);
  }

  bool is_registered(trx_t *caller_trx, trx_id_t id) {
    return (id > 0 && find(caller_trx, id, false));
  }

  /** Clones the oldest view and stores it in view.

  No need to call ReadView::close(). The caller owns the view that
  is passed in. This function is called by purge thread to determine
  whether it should purge the delete marked record or not. */
  void clone_oldest_view(ReadViewBase *view) const;

  /** @return the number of active views */
  size_t view_count() {
    size_t count = 0;

    mutex_enter(&mutex);
    for (const trx_t *trx = UT_LIST_GET_FIRST(mysql_trx_list); trx;
         trx = UT_LIST_GET_NEXT(mysql_trx_list, trx)) {
      if (trx->read_view->is_open()) {
        ++count;
      }
    }
    mutex_exit(&mutex);

    return count;
  }

private:
  static bool find_same_or_older_callback(rw_trx_hash_element_t *element,
                                          trx_id_t *id) {
    return element->id <= *id;
  }

  static bool get_min_trx_no_callback(rw_trx_hash_element_t *element,
                                      trx_id_t *min_no) {
    trx_id_t no = element->no.load(std::memory_order_relaxed);
    if (no < *min_no) {
      *min_no = no;
    }
    return false;
  }

  struct snapshot_ids_arg {
    snapshot_ids_arg(trx_ids_t *ids): m_ids(ids) {}
    trx_ids_t *m_ids;
    trx_id_t m_id;
    trx_id_t m_no;
  };

  /** Getter for m_rw_trx_hash_version, must issue ACQUIRE memory barrier. */
  trx_id_t get_rw_trx_hash_version() {
    return m_rw_trx_hash_version.load(std::memory_order_acquire);
  }

  static bool copy_one_id(rw_trx_hash_element_t *element,
                          snapshot_ids_arg *arg) {
    if (element->id < arg->m_id) {
      trx_id_t no = element->no.load(std::memory_order_relaxed);
      arg->m_ids->push_back(element->id);

      if (no < arg->m_no) {
        arg->m_no = no;
      }
    }
    return false;
  }

  /** Increments m_rw_trx_hash_version, must issue RELEASE memory barrier. */
  void refresh_rw_trx_hash_version() {
    m_rw_trx_hash_version.fetch_add(1, std::memory_order_release);
  }

  /** Allocates new transaction id without refreshing rw_trx_hash version.

  This method is extracted for exclusive use by register_rw() and
  assign_new_trx_no() where new id must be allocated atomically with
  payload of these methods from MVCC snapshot point of view.

  VERY important: after the database is started, max_trx_id value is
  divisible by TRX_SYS_TRX_ID_WRITE_MARGIN, and the following if
  will evaluate to TRUE when this function is first time called,
  and the value for trx id will be written to disk-based header!
  Thus trx id values will not overlap when the database is
  repeatedly started!

  @sa assign_new_trx_no()
  @return new transaction id */
  trx_id_t get_new_trx_id_no_refresh() {
    return m_max_trx_id.fetch_add(1, std::memory_order_relaxed);
  }
};
#endif /* !UNIV_HOTBACKUP */

/** A list of undo tablespace IDs found in the TRX_SYS page.
This cannot be part of the trx_sys_t object because it is initialized before
that object is created. These are the old type of undo tablespaces that do not
have space_IDs in the reserved range nor contain an RSEG_ARRAY page. */
extern Space_Ids *trx_sys_undo_spaces;

/** Test if trx_sys->mutex is owned. */
#define trx_sys_mutex_own() (trx_sys->mutex.is_owned())

/** Acquire the trx_sys->mutex. */
#define trx_sys_mutex_enter()     \
  do {                            \
    mutex_enter(&trx_sys->mutex); \
  } while (0)

/** Release the trx_sys->mutex. */
#define trx_sys_mutex_exit() \
  do {                       \
    trx_sys->mutex.exit();   \
  } while (0)

#include "trx0sys.ic"

#endif
