#!/bin/bash
###############################################################################
# iostat_run_monitor.sh —— sysbench「run 阶段」iostat(w_await) 采集助手
#
# 本文件是 mysql-sysbench-test skill 的组件，被 sysbench 驱动（正本
# scripts/localhost_run.sh 及其部署副本 test/sysbench/localhost_run.sh）的 hook
# 以 source 方式加载，不要单独手工改成别的调用形式。本文件必须与驱动**同目录**
# （驱动按「与自身同目录」定位它；sync_localhost_run.sh 会把两份一起放到部署目录）：
#
#     source "<与驱动同目录>/iostat_run_monitor.sh"
#     # ... 配置变量之后 ...
#     iostat_run_begin "$item" "$thd" "$config_dir"   # 紧挨 $cmd_run 之前
#     $cmd_run
#     iostat_run_end                                  # 紧挨 $cmd_run 之后
#
# 采集规则：
#   1) 只采集 run 阶段：iostat 在 sysbench run 进程起来之前启动、在它退出之后
#      停止；prepare / cleanup 阶段一律不采集。
#   2) 只监控存放 MySQL 数据与日志的盘：由 my.cnf 的 datadir / log-bin /
#      relay-log / innodb_log_group_home_dir / innodb_undo_directory /
#      innodb_temp_tablespaces_dir / slow_query_log_file 反查所在块设备
#      （整盘，如 nvme1n1），去重后只把这些设备交给 iostat。
#      不含 tmpdir（临时目录）与 log-error（错误日志在安装目录/系统盘，
#      与本次 IO 负载无关）。ramfs/tmpfs 上的路径没有块设备，会被跳过。
#   3) iostat -x，采样间隔固定 10 秒（可用 IOSTAT_RUN_INTERVAL 覆盖）。
#   4) 每个「测试项 × 并发」的 run 阶段结束后，向当前输出（即测试日志）追加一行：
#        run期间iostat - w_await为：12.34,9.87,10.02,...
#      每个数值是该盘一个 10 秒区间的写平均等待时间（w_await，毫秒），按时间
#      先后用逗号分隔。多块盘时逐盘标注：
#        run期间iostat - w_await为：nvme1n1(12.34,...) nvme2n1(3.21,...)
#      采集失败时打印：
#        run期间iostat - 未采集：<原因>（原始输出：<路径>）
#
# 环境变量：
#   IOSTAT_RUN_MONITOR=0            关闭采集（默认 1 开启）
#   IOSTAT_RUN_ITEMS="a b"          覆盖监控的测试项清单
#   IOSTAT_RUN_INTERVAL=10          采样间隔秒数（默认 10）
#   IOSTAT_RUN_RAW_DIR=/tmp/iostat-run-monitor
#                                   原始 iostat 输出与诊断目录
#   IOSTAT_RUN_KEEP_RAW=1           保留原始输出（默认 1；0 = 成功时删除）
#   MYSQL_SYSBENCH_MYCNF=<path>     覆盖 my.cnf 路径
#
# 自检与安装：
#   iostat_run_monitor.sh --probe [my.cnf]   只打印识别到的数据/日志盘，不采样
#   iostat_run_monitor.sh --sample [秒数]    立即采样一次并打印各盘 w_await 序列
#   iostat_run_monitor.sh --install [localhost_run.sh]    幂等安装 hook（先备份）
#   iostat_run_monitor.sh --uninstall [localhost_run.sh]  移除 hook（先备份）
###############################################################################

# 默认监控的测试项：混合读写 / 纯写 / insert / delete / update_index /
# update_non_index（oltp 前缀是 sysbench 的测试项名）
IOSTAT_RUN_ITEMS_DEFAULT="oltp_read_write oltp_write_only oltp_insert oltp_delete oltp_update_index oltp_update_non_index"
: "${IOSTAT_RUN_MONITOR:=1}"
: "${IOSTAT_RUN_INTERVAL:=10}"
: "${IOSTAT_RUN_RAW_DIR:=/tmp/iostat-run-monitor}"
: "${IOSTAT_RUN_KEEP_RAW:=1}"
: "${IOSTAT_RUN_ITEMS:=$IOSTAT_RUN_ITEMS_DEFAULT}"

_iostat_run_pid=""
_iostat_run_raw=""
_iostat_run_devs=""
_iostat_run_announced=0

###############################################################################
# 小工具
###############################################################################

# my.cnf 的 key 里 - 与 _ 等价（log-bin 与 log_bin 是同一个变量）
_iostat_run_norm_key() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d '_-'; }

# 取 my.cnf 里某个变量的值（取最后一次赋值，与 bash 语义一致）
_iostat_run_cfg_get() {  # $1=my.cnf $2=key
  local v
  v=$(awk -v want="$(_iostat_run_norm_key "$2")" '
    function norm(s) { s = tolower(s); gsub(/[-_]/, "", s); return s }
    {
      line = $0
      sub(/[[:space:]]*#.*/, "", line)
      i = index(line, "=")
      if (i == 0) next
      k = substr(line, 1, i - 1)
      v = substr(line, i + 1)
      gsub(/[[:space:]]/, "", k)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if (norm(k) == want) val = v
    }
    END { if (val != "") print val }
  ' "$1" 2>/dev/null)
  v=${v%\"}; v=${v#\"}; v=${v%\'}; v=${v#\'}
  [[ -n "$v" ]] || return 1
  printf '%s\n' "$v"
}

# 定位 my.cnf：优先 $MYSQL_SYSBENCH_MYCNF，其次调用方传入的路径，再次常见位置
_iostat_run_mycnf() {  # $1 = localhost_run.sh 里的 config_dir（可选）
  local c="${1:-}"
  if [[ -n "${MYSQL_SYSBENCH_MYCNF:-}" && -r "${MYSQL_SYSBENCH_MYCNF}" ]]; then
    printf '%s\n' "$MYSQL_SYSBENCH_MYCNF"; return 0
  fi
  if [[ -n "$c" && -r "$c" ]]; then printf '%s\n' "$c"; return 0; fi
  for c in "$HOME/database/mysql/install/my.cnf" "$HOME/database"/*/install/my.cnf; do
    [[ -r "$c" ]] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# 由 /dev/xxx 向上找到整盘设备名（nvme1n1p1 -> nvme1n1）
_iostat_run_whole_disk() {  # $1=/dev/xxx
  local d="$1" t pk
  while :; do
    t=$(lsblk -ndo TYPE "$d" 2>/dev/null | head -1 | tr -d ' ')
    [[ -z "$t" ]] && break
    [[ "$t" == "disk" ]] && { basename "$d"; return 0; }
    pk=$(lsblk -ndo PKNAME "$d" 2>/dev/null | head -1 | tr -d ' ')
    # 防自环（个别环境下 PKNAME 会等于自己）
    [[ -z "$pk" || "$pk" == "$(basename "$d")" ]] && break
    d="/dev/$pk"
  done
  basename "$1"
}

# 路径所在块设备（整盘）；没有块设备（ramfs/tmpfs 等）返回 1
_iostat_run_dev_of_path() {  # $1=目录或文件路径
  local p="$1" src
  [[ -e "$p" ]] || return 1
  src=$(df -P "$p" 2>/dev/null | awk 'NR > 1 && $1 ~ /^\/dev\// { print $1 }' | tail -1)
  [[ -n "$src" ]] || return 1
  _iostat_run_whole_disk "$src"
}

_iostat_run_has() {  # $1=值，$2..=集合
  local x="$1"; shift
  local i
  for i in "$@"; do [[ "$i" == "$x" ]] && return 0; done
  return 1
}

# 该测试项是否在监控清单里
_iostat_run_wanted() {  # $1=item
  local it="${1:-}" w
  for w in $IOSTAT_RUN_ITEMS; do [[ "$it" == "$w" ]] && return 0; done
  return 1
}

###############################################################################
# 设备识别
###############################################################################

# 输出去重后的整盘设备名（每行一个）；诊断明细写 $IOSTAT_RUN_RAW_DIR/detect.log
_iostat_run_devices() {  # $1=my.cnf
  local cfg="$1" datadir k v dir dev
  local -a out=()
  local log="$IOSTAT_RUN_RAW_DIR/detect.log"

  datadir=$(_iostat_run_cfg_get "$cfg" datadir) || datadir=""
  for k in datadir log-bin relay-log innodb_log_group_home_dir \
           innodb_undo_directory innodb_temp_tablespaces_dir slow_query_log_file; do
    v=$(_iostat_run_cfg_get "$cfg" "$k") || continue
    case "$k" in
      # 这几项是目录
      datadir|innodb_log_group_home_dir|innodb_undo_directory|innodb_temp_tablespaces_dir)
        dir="$v" ;;
      # 这几项是文件基名，取其目录
      *) dir=$(dirname "$v") ;;
    esac
    # 相对路径按 datadir 解析（innodb_undo_directory=./ 这类）
    if [[ "$dir" != /* ]]; then
      [[ -n "$datadir" ]] || continue
      dir="$datadir/${dir#./}"
    fi
    if [[ ! -d "$dir" ]]; then
      printf 'skip\t%s\t目录不存在: %s\n' "$k" "$dir" >> "$log" 2>/dev/null
      continue
    fi
    if ! dev=$(_iostat_run_dev_of_path "$dir"); then
      printf 'skip\t%s\t无块设备(ramfs/tmpfs?): %s\n' "$k" "$dir" >> "$log" 2>/dev/null
      continue
    fi
    printf 'use\t%s\t%s\t%s\n' "$k" "$dir" "$dev" >> "$log" 2>/dev/null
    _iostat_run_has "$dev" ${out[@]+"${out[@]}"} && continue
    out+=("$dev")
  done

  ((${#out[@]})) || return 1
  printf '%s\n' "${out[@]}"
}

###############################################################################
# 采集：begin / end
###############################################################################

# 上一轮若被强杀（例如负载监控中止了测试）可能留下 iostat，先收掉。
# 判据读 /proc/PID/cmdline（不用 pkill -f：这个环境里 -f 会匹配到调用者自身）。
_iostat_run_kill_stale() {
  local pf="$IOSTAT_RUN_RAW_DIR/.current.pid" pid cl i
  [[ -r "$pf" ]] || return 0
  pid=$(head -1 "$pf" 2>/dev/null)
  [[ -n "$pid" && -r "/proc/$pid/cmdline" ]] || return 0
  cl=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
  [[ "$cl" == *iostat* && "$cl" == *"$IOSTAT_RUN_RAW_DIR"* ]] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  for i in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  kill -9 "$pid" 2>/dev/null || true
}

# run 阶段开始：只对监控清单内的测试项启动 iostat
iostat_run_begin() {  # $1=item $2=threads $3=my.cnf(即 localhost_run.sh 的 config_dir)
  local item="${1:-}" thd="${2:-}" cfg="${3:-}" devs
  _iostat_run_pid=""; _iostat_run_raw=""; _iostat_run_devs=""

  [[ "${IOSTAT_RUN_MONITOR:-1}" == "0" ]] && return 0
  _iostat_run_wanted "$item" || return 0

  if ! command -v iostat >/dev/null 2>&1; then
    echo "run期间iostat - 未采集：找不到 iostat 命令（sysstat 未安装）"
    return 0
  fi

  mkdir -p "$IOSTAT_RUN_RAW_DIR" 2>/dev/null || true
  : > "$IOSTAT_RUN_RAW_DIR/detect.log" 2>/dev/null || true

  if ! cfg=$(_iostat_run_mycnf "$cfg"); then
    echo "run期间iostat - 未采集：找不到 my.cnf，无法确定数据/日志所在盘"
    return 0
  fi
  if ! devs=$(_iostat_run_devices "$cfg"); then
    echo "run期间iostat - 未采集：从 $cfg 反查不到数据/日志所在块设备（详见 $IOSTAT_RUN_RAW_DIR/detect.log）"
    return 0
  fi

  _iostat_run_kill_stale

  _iostat_run_raw="$IOSTAT_RUN_RAW_DIR/${item}-thd${thd:-x}.txt"
  _iostat_run_devs="$devs"

  # 每次 driver 运行只播报一次监控盘，便于日志自解释
  if [[ "$_iostat_run_announced" == "0" ]]; then
    _iostat_run_announced=1
    echo "run期间iostat - 监控盘：$(printf '%s' "$devs" | tr '\n' ' ')（-x，间隔 ${IOSTAT_RUN_INTERVAL}s；仅 run 阶段）"
  fi

  # -y：跳过开机以来的第一份统计，只留区间统计
  # shellcheck disable=SC2086
  iostat -y -x "$IOSTAT_RUN_INTERVAL" $devs > "$_iostat_run_raw" 2>"$_iostat_run_raw.err" &
  _iostat_run_pid=$!
  printf '%s\n' "$_iostat_run_pid" > "$IOSTAT_RUN_RAW_DIR/.current.pid" 2>/dev/null || true
  return 0
}

# run 阶段结束：停 iostat、解析 w_await、追加一行到日志
iostat_run_end() {
  local pid="$_iostat_run_pid" raw="$_iostat_run_raw" devs="$_iostat_run_devs"
  local i parsed out d v why
  _iostat_run_pid=""
  [[ -n "$pid" ]] || return 0

  kill -TERM "$pid" 2>/dev/null || true
  for i in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$IOSTAT_RUN_RAW_DIR/.current.pid" 2>/dev/null || true

  # shellcheck disable=SC2086
  parsed=$(_iostat_run_parse "$raw" $devs)
  if [[ -z "$parsed" ]]; then
    why="iostat 未产出可用样本（run 阶段短于 ${IOSTAT_RUN_INTERVAL}s，或设备名不被 iostat 接受）"
    if [[ -s "${raw}.err" ]]; then
      why=$(tr '\n' ' ' < "${raw}.err" | tr -s ' ' | cut -c1-160)
    fi
    echo "run期间iostat - 未采集：${why}（原始输出：${raw}）"
    return 0
  fi

  if [[ "$(printf '%s\n' "$parsed" | wc -l)" -eq 1 ]]; then
    echo "run期间iostat - w_await为：$(printf '%s\n' "$parsed" | cut -f2)"
  else
    out=""
    while IFS=$'\t' read -r d v; do
      [[ -n "$d" ]] || continue
      out="${out}${out:+ }${d}(${v})"
    done <<< "$parsed"
    echo "run期间iostat - w_await为：${out}"
  fi

  [[ "${IOSTAT_RUN_KEEP_RAW:-1}" == "1" ]] || rm -f "$raw" "${raw}.err" 2>/dev/null || true
  return 0
}

###############################################################################
# 解析 iostat 输出
###############################################################################

# 输出：每块盘一行 "<设备>\t<v1,v2,...>"（v 为各 10 秒区间的 w_await）
_iostat_run_parse() {  # $1=raw文件  $2..=设备名
  local raw="$1"; shift
  local devs
  devs=$(printf '%s ' "$@")
  awk -v devs="$devs" '
    BEGIN { n = split(devs, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") want[a[i]] = 1 }
    # 每份区间统计以 Device 表头开始，从表头里找 w_await 的列号
    /^Device/ { idx = 0; for (i = 1; i <= NF; i++) if ($i == "w_await") idx = i; next }
    idx > 0 && NF > 1 {
      if (!($1 in want)) next
      if (NF < idx) next
      vals[$1] = (vals[$1] == "" ? $idx : vals[$1] "," $idx)
    }
    END { n = split(devs, a, " "); for (i = 1; i <= n; i++) if (a[i] in vals) print a[i] "\t" vals[a[i]] }
  ' "$raw"
}

###############################################################################
# 安装 / 卸载 localhost_run.sh 里的 hook（幂等，先备份）
###############################################################################

_iostat_run_install() {  # $1=localhost_run.sh（默认 ./localhost_run.sh）
  local lr="${1:-localhost_run.sh}"
  [[ -f "$lr" ]] || { echo "找不到 $lr" >&2; return 1; }
  python3 - "$lr" <<'PY'
import sys, re, os, time, shutil

path = sys.argv[1]
BEGIN = '# >>> mysql-sysbench-test: iostat-run-monitor (begin) >>>'
END = '# <<< mysql-sysbench-test: iostat-run-monitor (end) <<<'
CALL = '# <<< mysql-sysbench-test: iostat-run-monitor'

BLOCK = '''# >>> mysql-sysbench-test: iostat-run-monitor (begin) >>>
###############################################################################
# run 阶段 iostat（w_await）采集 —— 由 mysql-sysbench-test skill 提供，勿手改
# 只对 oltp_read_write / oltp_write_only / oltp_insert / oltp_delete /
# oltp_update_index / oltp_update_non_index 采集，且只覆盖下面 $cmd_run 的
# 生命周期（prepare / cleanup 阶段不采集）。采集规则、日志格式、关闭方式
# （IOSTAT_RUN_MONITOR=0）见 skill 的 SKILL.md「2.5 run 阶段 iostat（w_await）采集」。
# 逻辑全在 skill 脚本内；脚本缺失时这里退化为空操作，不影响测试。
###############################################################################
# hook 脚本与本驱动**成对存放**：正本/运行时副本同在 skill 的 scripts/ 下，部署副本由
# sync_localhost_run.sh 一并放到 test/sysbench/。故按「与自身同目录」定位，不依赖任何
# 宿主安装路径；也可用 SKILL_SCRIPTS_DIR 显式指定。
IOSTAT_RUN_MONITOR_SH="${SKILL_SCRIPTS_DIR:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)}/iostat_run_monitor.sh"
[ -r "$IOSTAT_RUN_MONITOR_SH" ] && source "$IOSTAT_RUN_MONITOR_SH"
command -v iostat_run_begin >/dev/null 2>&1 || { iostat_run_begin() { :; }; iostat_run_end() { :; }; }
# <<< mysql-sysbench-test: iostat-run-monitor (end) <<<
'''

src = open(path, encoding='utf-8').read()
if BEGIN in src:
    print('已安装（发现标记 %s），跳过' % BEGIN)
    sys.exit(0)

# 1) source 块：插到 "# $1: initial command" 之前；没有就退到第一个函数定义之前
m = re.search(r'^# \$1: initial command\n', src, re.M)
if m:
    pos = m.start()
else:
    m = re.search(r'^(function\s+\w+\s*\(\)|\w+\s*\(\)\s*\{)', src, re.M)
    if not m:
        sys.stderr.write('未找到插入锚点（期望 "# $1: initial command" 或函数定义），'
                         '请按 SKILL.md 手工安装\n')
        sys.exit(2)
    pos = m.start()
out = src[:pos] + BLOCK + '\n' + src[pos:]

# 2) 调用点：在 cmd_run/echo/$cmd_run 三行组里，$cmd_run 前后各插一行
ind = r'(?P<ind>[ \t]*)'
pat = re.compile(ind + r'cmd_run="\$cmd run"\n(?P=ind)echo \$cmd_run\n(?P=ind)\$cmd_run\n')
hit = pat.search(out)
if not hit:
    sys.stderr.write('未找到 $cmd_run 调用点（期望 cmd_run="$cmd run" / echo $cmd_run / '
                     '$cmd_run 三行相邻），请按 SKILL.md 手工安装；未做任何修改\n')
    sys.exit(2)
i = hit.group('ind')
repl = (i + 'cmd_run="$cmd run"\n'
        + i + 'echo $cmd_run\n'
        + i + 'iostat_run_begin "$item" "$thd" "$config_dir"   ' + CALL + '\n'
        + i + '$cmd_run\n'
        + i + 'iostat_run_end                                  ' + CALL + '\n')
out = out[:hit.start()] + repl + out[hit.end():]

bak = '%s.bak-%s' % (path, time.strftime('%Y%m%d-%H%M'))
shutil.copy2(path, bak)
open(path, 'w', encoding='utf-8').write(out)
print('已安装 hook：%s（备份：%s）' % (path, bak))
PY
}

_iostat_run_uninstall() {  # $1=localhost_run.sh（默认 ./localhost_run.sh）
  local lr="${1:-localhost_run.sh}"
  [[ -f "$lr" ]] || { echo "找不到 $lr" >&2; return 1; }
  python3 - "$lr" <<'PY'
import sys, re, time, shutil

path = sys.argv[1]
BEGIN = '# >>> mysql-sysbench-test: iostat-run-monitor (begin) >>>'
END = '# <<< mysql-sysbench-test: iostat-run-monitor (end) <<<'
CALL = '# <<< mysql-sysbench-test: iostat-run-monitor'

src = open(path, encoding='utf-8').read()
if BEGIN not in src:
    print('未发现 hook 标记，跳过')
    sys.exit(0)

# 去掉 BEGIN..END 这一段，以及安装时补上的那一个空行（保证与安装前逐字节一致）
lines = src.splitlines(keepends=True)
keep, skip, drop_blank = [], False, False
for ln in lines:
    if drop_blank:
        drop_blank = False
        if ln.strip() == '':
            continue
    if BEGIN in ln:
        skip = True
        continue
    if skip:
        if END in ln:
            skip = False
            drop_blank = True
        continue
    keep.append(ln)
out = ''.join(keep)
# 去掉两行调用
out = ''.join(ln for ln in out.splitlines(keepends=True) if CALL not in ln)

bak = '%s.bak-%s' % (path, time.strftime('%Y%m%d-%H%M'))
shutil.copy2(path, bak)
open(path, 'w', encoding='utf-8').write(out)
print('已移除 hook：%s（备份：%s）' % (path, bak))
PY
}

###############################################################################
# 自检入口（直接执行本文件时才走这里；被 source 时不执行）
###############################################################################

_iostat_run_main() {
  local cmd="${1:---probe}" cfg devs raw pid
  case "$cmd" in
    --probe|--devices)
      if ! cfg=$(_iostat_run_mycnf "${2:-}"); then
        echo "找不到 my.cnf；可用 MYSQL_SYSBENCH_MYCNF=<path> 指定" >&2
        return 1
      fi
      mkdir -p "$IOSTAT_RUN_RAW_DIR" 2>/dev/null || true
      : > "$IOSTAT_RUN_RAW_DIR/detect.log" 2>/dev/null || true
      echo "my.cnf: $cfg"
      echo "数据/日志路径与所在盘："
      if devs=$(_iostat_run_devices "$cfg"); then
        sed 's/^/  /' "$IOSTAT_RUN_RAW_DIR/detect.log"
        echo "→ 监控盘：$(printf '%s' "$devs" | tr '\n' ' ')"
      else
        sed 's/^/  /' "$IOSTAT_RUN_RAW_DIR/detect.log"
        echo "→ 未识别到任何块设备" >&2
        return 1
      fi
      ;;
    --install)
      _iostat_run_install "${2:-localhost_run.sh}"
      ;;
    --uninstall)
      _iostat_run_uninstall "${2:-localhost_run.sh}"
      ;;
    --sample)
      local secs="${2:-30}"
      if ! cfg=$(_iostat_run_mycnf ""); then return 1; fi
      mkdir -p "$IOSTAT_RUN_RAW_DIR" 2>/dev/null || true
      : > "$IOSTAT_RUN_RAW_DIR/detect.log" 2>/dev/null || true
      if ! devs=$(_iostat_run_devices "$cfg"); then return 1; fi
      raw="$IOSTAT_RUN_RAW_DIR/sample.txt"
      echo "采样 ${secs}s（间隔 ${IOSTAT_RUN_INTERVAL}s）@ $(printf '%s' "$devs" | tr '\n' ' ')"
      # shellcheck disable=SC2086
      iostat -y -x "$IOSTAT_RUN_INTERVAL" $devs > "$raw" 2>"$raw.err" &
      pid=$!
      sleep "$secs"
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      # shellcheck disable=SC2086
      _iostat_run_parse "$raw" $devs | while IFS=$'\t' read -r d v; do
        echo "  $d: $v"
      done
      ;;
    *)
      sed -n '2,45p' "$0"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _iostat_run_main "$@"
  exit $?
fi
