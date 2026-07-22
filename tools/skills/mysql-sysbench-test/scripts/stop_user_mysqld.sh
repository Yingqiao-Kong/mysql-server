#!/bin/bash
###############################################################################
# stop_user_mysqld.sh
# 关闭当前 Linux 账户下所有已启动的 mysqld / mysqld_safe 进程。
# 在 launch.sh 启动新版本前调用，避免端口、socket、数据目录冲突。
#
# 用法: stop_user_mysqld.sh [REPO]
#   REPO 可选，如 txsql / mysql / polarDb；若提供则优先尝试该 install/mysql.sock
###############################################################################
set -u

CURRENT_USER=$(whoami)
REPO=${1:-}

has_user_mysqld() {
  pgrep -u "$CURRENT_USER" -f 'mysqld_safe' >/dev/null 2>&1 && return 0
  pgrep -u "$CURRENT_USER" -f 'bin/mysqld ' >/dev/null 2>&1 && return 0
  return 1
}

list_user_mysqld() {
  pgrep -u "$CURRENT_USER" -af 'mysqld_safe|bin/mysqld ' 2>/dev/null || true
}

try_mysqladmin_shutdown() {
  local sock="$1"
  [[ -S "$sock" ]] || return 0
  if timeout 3 mysqladmin -uroot -p123456 --socket="$sock" ping >/dev/null 2>&1; then
    echo "尝试 mysqladmin shutdown (socket=$sock)..."
    timeout 45 mysqladmin -uroot -p123456 --socket="$sock" shutdown >/dev/null 2>&1 || true
  fi
}

stop_via_wrappers() {
  local basedirs basedir
  basedirs=$(pgrep -u "$CURRENT_USER" -af 'bin/mysqld --defaults' 2>/dev/null \
    | sed -n 's#.*--basedir=\([^ ]*\).*#\1#p' | sort -u)
  for basedir in $basedirs; do
    if [[ -x "${basedir}/mysqld" ]]; then
      echo "执行 ${basedir}/mysqld stop..."
      timeout 30 "${basedir}/mysqld" stop 2>/dev/null || true
    fi
  done
}

wait_for_exit() {
  local i
  for i in $(seq 1 30); do
    has_user_mysqld || return 0
    sleep 1
  done
  return 1
}

force_kill() {
  echo "强制终止残留 mysqld 进程..."
  pkill -u "$CURRENT_USER" -TERM -f 'mysqld_safe' 2>/dev/null || true
  pkill -u "$CURRENT_USER" -TERM -f 'bin/mysqld --defaults' 2>/dev/null || true
  sleep 3
  pkill -u "$CURRENT_USER" -9 -f 'mysqld_safe' 2>/dev/null || true
  pkill -u "$CURRENT_USER" -9 -f 'bin/mysqld --defaults' 2>/dev/null || true
  sleep 2
}

main() {
  if ! has_user_mysqld; then
    echo "当前账户 ($CURRENT_USER) 无运行中的 MySQL 进程，跳过关闭步骤。"
    return 0
  fi

  echo "检测到当前账户 ($CURRENT_USER) 下有 MySQL 进程："
  list_user_mysqld

  if [[ -n "$REPO" ]]; then
    try_mysqladmin_shutdown "$HOME/database/${REPO}/install/mysql.sock"
  fi
  for sock in $HOME/database/*/install/mysql.sock; do
    [[ -e "$sock" ]] || continue
    try_mysqladmin_shutdown "$sock"
  done

  stop_via_wrappers

  if wait_for_exit; then
    echo "MySQL 进程已正常退出。"
    return 0
  fi

  force_kill

  if has_user_mysqld; then
    echo "警告：仍有 MySQL 进程未能关闭：" >&2
    list_user_mysqld >&2
    return 1
  fi
  echo "MySQL 进程已通过强制终止关闭。"
  return 0
}

main "$@"
