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

###############################################################################
# 怎么认出"这是 MySQL 进程"
#
# **不看命令行里有没有那串字**，而是读 /proc/PID/cmdline 的 argv 结构：
#   真 mysqld_safe : argv[0]=/bin/sh, argv[1]=<...>/bin/mysqld_safe（shebang 执行）
#   真 mysqld      : argv[0]=<...>/bin/mysqld
#
# 别写成"argv 里任意一项 basename == mysqld"：安装目录下那份 mysql.server 包装脚本
# 也叫 mysqld，被 shebang 执行时 argv[1] 正是 mysqld —— launch.sh 里 `mysqld start`
# 正在跑的时候会被误杀。按 argv 的**位置**判才不会撞上。
#
# 为什么必须这么改：旧版用 `pgrep -f 'mysqld_safe'`，而 -f 是把正则匹配到进程的
# **整条命令行**、只用 -u 限定了 uid。于是任何"命令行里出现过 mysqld_safe 这串字"的
# 同 uid 进程都会被算成 MySQL 进程，紧接着 force_kill 对这份名单发 TERM 再发 KILL：
#   - 执行本脚本的包装 shell 自己。Claude Code 的 Bash 工具把整条命令文本塞进
#     `bash -c '...'` 的 argv，只要同一条命令里出现过一次这串字就会中招（已实际发生，
#     工具侧返回 exit 144）
#   - vim / less / tail 正在看 mysqld_safe 相关路径的进程
#   - 用户自己终端里正敲着 `ps -ef | grep mysqld_safe` 的命令
# 而 -9 不可捕获、被杀进程没有清理机会。现在按 argv 结构判，这类进程在结构上就
# 不可能再被认成 MySQL。
###############################################################################

# 读 /proc/PID/cmdline 的 argv，判断该 pid 是不是真的 mysqld / mysqld_safe。
is_mysql_pid() {
  local pid="$1" a0 a1
  local -a argv=()
  [[ -r "/proc/$pid/cmdline" ]] || return 1
  mapfile -d '' -t argv < "/proc/$pid/cmdline" 2>/dev/null || return 1
  a0="${argv[0]:-}"; a1="${argv[1]:-}"
  [[ "${a0##*/}" == "mysqld" ]] && return 0        # mysqld 服务器本体
  [[ "${a1##*/}" == "mysqld_safe" ]] && return 0   # mysqld_safe：argv[0] 是 /bin/sh
  return 1
}

# 候选先由两条网捞：comm 精确匹配（-x，不受命令行文本影响）与带路径边界的 -f
# （防某个变体改了 comm 而漏判），再逐个用 argv 结构确认（防误判）。
matching_pids() {
  local pid
  {
    pgrep -u "$CURRENT_USER" -x mysqld      2>/dev/null || true
    pgrep -u "$CURRENT_USER" -x mysqld_safe 2>/dev/null || true
    pgrep -u "$CURRENT_USER" -f '(^|/)(mysqld|mysqld_safe)( |$)' 2>/dev/null || true
  } | sort -un | while read -r pid; do
        is_mysql_pid "$pid" && echo "$pid"
      done
}

# 完整取出命令行，**不要截断**：stop_via_wrappers 要拿它解析 --basedir=，而
# --basedir= 的值恰好落在第 200 字符之后，一截断就切出一个不存在的路径，
# [[ -x "${basedir}/mysqld" ]] 必然失败，脚本会静默跳过 wrapper 关闭直接进 force_kill。
# 只给屏幕显示用的地方自己 cut。
cmdline_of() {
  tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null
}

has_user_mysqld() {
  [[ -n "$(matching_pids)" ]]
}

list_user_mysqld() {
  local pid
  for pid in $(matching_pids); do
    echo "  pid=$pid  $(cmdline_of "$pid" | cut -c1-200)"
  done
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
  local pid basedirs basedir
  basedirs=$(for pid in $(matching_pids); do cmdline_of "$pid"; echo; done \
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

# 只对 matching_pids 确认过的 pid 逐个发信号——不再用 `pkill -f`，那等于把名单交给
# 正则现算一遍，正是上面那段注释里误杀的来源。
force_kill() {
  echo "强制终止残留 mysqld 进程..."
  local pid
  for pid in $(matching_pids); do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 3
  for pid in $(matching_pids); do kill -9 "$pid" 2>/dev/null || true; done
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
