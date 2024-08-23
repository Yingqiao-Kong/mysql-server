/*****************************************************************************

Copyright (c) 1997, 2021, Oracle and/or its affiliates.

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

/** @file include/read0types.h
 Cursor read

 Created 2/16/1997 Heikki Tuuri
 *******************************************************/

#ifndef read0types_h
#define read0types_h

#include <algorithm>
#include "dict0mem.h"

#include "trx0types.h"

/** Read view lists the trx ids of those transactions for which a
consistent read should not see the modifications to the database. */
class ReadViewBase {
  /** The read should not see any transaction with trx id >= this
  value. In other words, this is the "high water mark". */
  trx_id_t m_low_limit_id;

  /** The read should see all trx ids which are strictly
  smaller (<) than this value. In other words, this is the
  low water mark". */
  trx_id_t m_up_limit_id;

  /** Set of RW transactions that was active when this snapshot was taken */
  trx_ids_t m_ids;

  /** The view does not need to see the undo logs for transactions whose
  transaction number is strictly smaller (<) than this value: they can be
  removed in purge if not needed by other views. */
  trx_id_t m_low_limit_no;

#ifdef UNIV_DEBUG
  /** The low limit number up to which read views don't need to access
  undo log records for MVCC. This could be higher than m_low_limit_no
  if purge is blocked for GTID persistence. Currently used for debug
  variable INNODB_PURGE_VIEW_TRX_ID_AGE. */
  trx_id_t m_view_low_limit_no;
#endif /* UNIV_DEBUG */

protected:
  bool empty() { return m_ids.empty(); }

  /** @return the up limit id */
  trx_id_t up_limit_id() const { return m_up_limit_id; }

public:
  ReadViewBase(): m_low_limit_id(0) {}

  /** Append state from another view.

  This method is used to find min(m_low_limit_no), min(m_low_limit_id) and
  all transaction ids below min(m_low_limit_id). These values effectively
  form oldest view.
  @param other    view to copy from */
  void append(const ReadViewBase &other) {
    ut_ad(&other != this);
    if (m_low_limit_no > other.m_low_limit_no) {
      m_low_limit_no = other.m_low_limit_no;
    }

    if (m_low_limit_id > other.m_low_limit_id) {
      m_low_limit_id = other.m_low_limit_id;
    }

    trx_ids_t::iterator dst = m_ids.begin();
    for (const trx_id_t id : other.m_ids) {
      if (id >= m_low_limit_id)
        break;
loop:
      if (dst == m_ids.end()) {
        m_ids.push_back(id);
        dst = m_ids.end();
        continue;
      }

      if (*dst < id) {
        dst++;
        goto loop;
      } else if (*dst > id)
        dst = m_ids.insert(dst, id) + 1;
    }

    m_ids.erase(std::lower_bound(dst, m_ids.end(), m_low_limit_id),
                m_ids.end());

    m_up_limit_id = m_ids.empty() ? m_low_limit_id : m_ids.front();
    ut_ad(m_up_limit_id <= m_low_limit_id);
    ut_d(m_view_low_limit_no = m_low_limit_no);
  }

  /** Creates a snapshot where exactly the transactions serialized
  before this point in time are seen in the view.
  @param[in,out] trx transaction */
  inline void snapshot(trx_t *trx);

  /** Check whether transaction id is valid.
  @param[in] id transaction id to check
  @param[in] name table name

  @todo changes_visible() was an unfortunate choice for this check.
  It should be moved towards the functions that load trx id like
  trx_read_trx_id(). No need to issue a warning, error log message should
  be enough. Although statement should ideally fail if it sees corrupt
  data. */
  static void check_trx_id_sanity(trx_id_t id, const table_name_t &name);

  /** Check whether the changes by id are visible.
  @param[in] id transaction id to check against the view
  @param[in] name table name
  @return whether the view sees the modifications of id. */
  bool changes_visible(trx_id_t id, const table_name_t &name) const
      MY_ATTRIBUTE((warn_unused_result)) {
    if (id >= m_low_limit_id) {
      check_trx_id_sanity(id, name);
      return false;
    }

    return (id < m_up_limit_id || m_ids.empty() ||
            !std::binary_search(m_ids.begin(), m_ids.end(), id));
  }

  /**
  @param id transaction to check
  @return true if view sees transaction id */
  bool sees(trx_id_t id) const { return id < m_up_limit_id; }

  /** @return the low limit no */
  trx_id_t low_limit_no() const { return m_low_limit_no; }

  /** @return the low limit id */
  trx_id_t low_limit_id() const { return m_low_limit_id; }

#ifdef UNIV_DEBUG
  /**
  @return the view low limit number */
  trx_id_t view_low_limit_no() const { return (m_view_low_limit_no); }
#endif /* UNIV_DEBUG */

    /** Check and reduce low limit number for read view. Used to
  block purge till GTID is persisted on disk table.
  @param[in]	trx_no	transaction number to check with */
  void reduce_low_limit(trx_id_t trx_no) {
    if (trx_no < m_low_limit_no) {
      /* Save low limit number set for Read View for MVCC. */
      ut_d(m_view_low_limit_no = m_low_limit_no);
      m_low_limit_no = trx_no;
    }
  }
};

/** A ReadView with extra members required for trx_t::read_view. */
class ReadView: public ReadViewBase {
  friend struct TrxFactory;
  /** View state.

  Implemented as atomic to allow mutex-free view close and re-use.
  Non-owner thread is allowed to call is_open() alone without mutex
  protection as well. E.g. trx_sys.view_count() does this.

  If non-owner thread intends to access other members as well, both
  is_open() and other members accesses must be protected by m_mutex.
  E.g. copy_to(). */
  std::atomic<bool> m_open;

  /** For synchronisation with purge coordinator. */
  mutable ib_mutex_t m_mutex;

  /** Trx id of creating transaction.
  Used exclusively by the read view owner thread. */
  trx_id_t m_creator_trx_id;

public:
  ReadView();
  ~ReadView();

  void init() { mutex_create(LATCH_ID_READ_VIEW_MUTEX, &m_mutex); }
  void destroy() { mutex_free(&m_mutex); }

  /** Opens a read view where exactly the transactions serialized before this
  point in time are seen in the view.

  View becomes visible to purge thread. Intended to be called by the ReadView
  owner thread.

  @param[in,out] trx transaction */
  void open(trx_t *trx);

  /** Closes the view.

  View becomes not visible to purge thread. Intended to be called by the
  ReadView owner thread. */
  void close() { m_open.store(false, std::memory_order_relaxed); }

  /** Returns true if view is open. */
  bool is_open() const { return m_open.load(std::memory_order_relaxed); }

  /** Sets the creator transaction id.

  This should be set only for views created by RW transactions.
  Intended to be called by the ReadView owner thread. */
  void set_creator_trx_id(trx_id_t id) {
    ut_ad(id > 0);
    ut_ad(m_creator_trx_id == 0);

    m_creator_trx_id = id;
  }

  /** Writes the limits to the file.
  @param file file to write to */
  void print_limits(FILE *file) const {
    mutex_enter(&m_mutex);

    if (is_open()) {
      fprintf(file, "Trx read view will not see trx with"
                    " id >= " TRX_ID_FMT ", sees < " TRX_ID_FMT "\n",
                    low_limit_id(), up_limit_id());
    }

    mutex_exit(&m_mutex);
  }

  /** A wrapper around ReadViewBase::changes_visible().
  Intended to be called by the ReadView owner thread. */
  bool changes_visible(trx_id_t id, const table_name_t &name) const {
    return (id == m_creator_trx_id ||
            ReadViewBase::changes_visible(id, name));
  }

  /** A wrapper around ReadViewBase::append().
  Intended to be called by the purge coordinator task. */
  void append_to(ReadViewBase *to) const {
    mutex_enter(&m_mutex);

    if (is_open()) {
      to->append(*this);
    }

    mutex_exit(&m_mutex);
  }
};
#endif
