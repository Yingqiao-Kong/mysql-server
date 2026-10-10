#!/bin/bash
###############################################################################
# hotspot_probe.sh —— 性能测试前的"热点摸底"
#
# 在正式跑 sysbench 性能测试之前，先用高并发（默认 128）把本次要测的每个测试项
# 各压一小段（默认 warmup 30s + run 30s），同时用 perf 采样 mysqld 的**全部线程**，
# 看看有没有异常热点：
#   * 非常明显的锁竞争（自旋 / 等待 / 锁 类函数占比畸高）
#   * 某一个函数的自身（self）占比畸高
#
# 判定规则（阈值见 ---------- 判定阈值 ----------）：
#   某个函数自身占比 > 30%                        → PAUSE（退出码 2）必须暂停测试
#   15% < 自身占比 <= 30%，或阻塞类合计 > 40%      → WARN （退出码 1）日志说明清楚后继续
#   样本数不足 / 无法按测试项切分                  → WARN （退出码 1）
#   其余                                          → OK   （退出码 0）
#   环境问题（mysqld 未运行 / 无 perf / 无免密 sudo） → 3
#   被用户中断                                     → 4
#
# sysbench 依然只由驱动「正本」（本脚本同目录的 localhost_run.sh）执行：
# 摸底开始时把正本复制成 --out 目录下的工作副本（localhost_run.sh.probe），用 sed
# 只改这份副本的并发数/时长/预热并只跑一轮。**正本与部署副本 test/sysbench/ 全程只读**，
# 因此退出（含 Ctrl-C）时无需还原，也不可能把驱动改坏。
#
# 用法: ./hotspot_probe.sh [选项]
#   --threads N      摸底并发数（默认 128）
#   --time N         每个测试项的 run 时长，秒（默认 30）
#   --warmup N       每个测试项的预热时长，秒（默认 30）
#   --freq N         perf 采样频率 Hz（默认 499；按线程计的频率）
#   --callgraph M    调用图模式 none|dwarf|fp（默认 none；dwarf 会显著变慢、文件很大）
#   --items "a b c"  只摸底这些测试项（默认取正本 localhost_run.sh 里的 test_items）
#   --budget N       perf 记录的最大秒数兜底（默认按耗时估算）
#   --out DIR        输出目录（默认 ./hotspot-probe-<日期-时间>）
#   --keep-lr        结束后保留工作副本 localhost_run.sh.probe（调试用）
#   -h, --help       显示帮助
#
# 输出（都在 --out 目录下）：
#   hotspot-probe-<时间戳>.log   人读报告（每项 Top 函数表、阻塞类占比、判定与下一步）
#   hotspot-summary.tsv          机器可读汇总（供后续步骤/脚本消费）
#   sysbench-raw.log             sysbench 原始输出
#   sysbench-ts.log              带单调时钟戳的 sysbench 输出（切分 perf 时间窗用）
#   perf.data                    perf 采样数据
#   perf-report-<item>.txt       每个测试项的 perf report 明细
###############################################################################

set -u

# ---------- 判定阈值 ----------
PAUSE_PCT=30          # 单函数自身占比超过它就暂停测试
WARN_PCT=15           # 单函数自身占比超过它就告警
BLOCK_WARN_PCT=40     # 阻塞类（自旋+等待+锁）合计占比超过它就告警
MIN_SAMPLES=5000      # 单个测试项的最少样本数，低于此数不下"通过"结论

# ---------- 默认摸底参数 ----------
PROBE_THREADS=128
PROBE_TIME=30
PROBE_WARMUP=30
PROBE_FREQ=499
CALLGRAPH="none"
OUT_DIR=""
ITEMS_OVERRIDE=""
KEEP_LR=0
BUDGET=""
PREPARE_ESTIMATE=300   # 造数据（prepare）预留时间，只用于估算 perf 兜底时长

usage() { awk 'NR>2 { if ($0 ~ /^#{20,}/) exit; sub(/^# ?/, ""); print }' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --threads)   PROBE_THREADS="$2"; shift 2 ;;
    --time)      PROBE_TIME="$2"; shift 2 ;;
    --warmup)    PROBE_WARMUP="$2"; shift 2 ;;
    --freq)      PROBE_FREQ="$2"; shift 2 ;;
    --callgraph) CALLGRAPH="$2"; shift 2 ;;
    --items)     ITEMS_OVERRIDE="$2"; shift 2 ;;
    --budget)    BUDGET="$2"; shift 2 ;;
    --out)       OUT_DIR="$2"; shift 2 ;;
    --keep-lr)   KEEP_LR=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "未知参数: $1（-h 看帮助）" >&2; exit 3 ;;
  esac
done

# ---------- 基础工具 ----------
# 单调时钟（秒，10ms 分辨率）——/proc/uptime 与 perf 样本时间戳同一时基
# （CLOCK_MONOTONIC），所以可以直接喂给 `perf report --time`。
mono_now() { local u; read -r u _ < /proc/uptime; printf '%s' "$u"; }
info() { echo "[摸底] $*"; }
warn() { echo "[摸底] WARNING: $*"; }
die()  { echo "[摸底] ERROR: $*" >&2; exit 3; }

# 从 `perf report --header` 的输出里取样本数。
# perf 会把大数字缩写成 1M / 211K 这种形式（带 SI 后缀），不能直接拿去比大小，
# 必须先把后缀还原成整数，否则 `[ "$samples" -lt 5000 ]` 会报
# "integer expression expected" 并静默把判定降级成 OK。
samples_of_report() {
  local raw
  raw="$(grep -m1 '^# Samples:' "$1" 2>/dev/null | awk '{print $3}')"
  awk -v s="$raw" 'BEGIN{
    if (s == "") { print 0; exit }
    m = 1
    if      (s ~ /[Kk]$/) m = 1000
    else if (s ~ /[Mm]$/) m = 1000000
    else if (s ~ /[Gg]$/) m = 1000000000
    printf "%d", (s + 0) * m
  }'
}

# ---------- 定位 localhost_run.sh 与 mysqld ----------
# 报告里的"复现"命令要用脚本自身的绝对路径（本脚本用 readlink -f 自定位，
# 因此放在仓库里跑、或由宿主从别处加载本 skill，解析出来都对）。
SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
SCRIPTS_DIR="$(cd "$(dirname "$SELF")" && pwd)"

# 摸底只读「正本」：仓库正本 tools/skills/mysql-sysbench-test/scripts/localhost_run.sh
LR_SRC="$SCRIPTS_DIR/localhost_run.sh"
[ -x "$LR_SRC" ] || die "找不到可执行的驱动正本 $LR_SRC
请检查 skill 安装是否完整（仓库正本：tools/skills/mysql-sysbench-test/scripts/localhost_run.sh）。"

# 顺手把正本同步到部署副本 test/sysbench/localhost_run.sh，保持两份一致
# （幂等；同步失败不致命，摸底仍按正本执行）
if [ -x "$SCRIPTS_DIR/sync_localhost_run.sh" ]; then
  "$SCRIPTS_DIR/sync_localhost_run.sh" --quiet \
    || warn "正本 → 部署副本同步失败，摸底仍按正本执行。"
fi

# REPO：驱动器 my.cnf/socket 所在仓库。优先环境变量，其次从当前目录推断，最后默认 mysql。
if [ -z "${REPO:-}" ]; then
  case "$PWD" in
    "$HOME"/database/*) REPO="${PWD#"$HOME"/database/}"; REPO="${REPO%%/*}" ;;
    *)                  REPO="mysql" ;;
  esac
fi
INSTALL_DIR="$HOME/database/$REPO/install"
SOCKET="$INSTALL_DIR/mysql.sock"

command -v perf >/dev/null 2>&1 || die "找不到 perf，请先安装 perf"
command -v stdbuf >/dev/null 2>&1 || die "找不到 stdbuf（coreutils），无法保证按行时间戳"
sudo -n true 2>/dev/null || die "当前账户没有免密 sudo；perf 采样 mysqld 需要 root（mysqld 带 cap_sys_nice=ep，是 non-dumpable 进程）"

find_mysqld_pid() {
  local p
  p=$(ps -eo pid=,comm=,args= --no-headers 2>/dev/null \
      | awk -v s="$SOCKET" '$2=="mysqld" && index($0,s){print $1; exit}')
  [ -n "$p" ] && { printf '%s' "$p"; return 0; }
  local f
  for f in "$INSTALL_DIR/mysqld.pid" "$INSTALL_DIR"/*/mysqld.pid; do
    [ -f "$f" ] || continue
    p=$(head -1 "$f" 2>/dev/null | tr -dc '0-9')
    [ -n "$p" ] && [ -d "/proc/$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

MYSQLD_PID="$(find_mysqld_pid)" || die "找不到绑定在 $SOCKET 上的 mysqld 进程，请先按步骤 1 启动 MySQL"

# mysqld 的 cap_sys_nice=ep 让 /proc/<pid>/exe 变成 non-dumpable，免密免不了 sudo。
# 只用于报告里的 addr2line 提示，取不到就退化成占位符，不影响摸底本身。
MYSQL_BIN="$(sudo readlink -f "/proc/$MYSQLD_PID/exe" 2>/dev/null || true)"
[ -n "$MYSQL_BIN" ] || MYSQL_BIN="<mysqld 二进制路径>"

# ---------- 要摸底哪些测试项 ----------
# 注意：localhost_run.sh 里常有多行 test_items=（一行一个候选场景），
# bash 取最后一行生效，所以这里也必须取最后一次赋值。
read_test_items() {
  awk '/^[[:space:]]*test_items=\(/ {
         line=$0
         sub(/^[^(]*\(/, "", line); sub(/\).*/, "", line)
         gsub(/"/, "", line)
         last=line
       }
       END { print last }' "$LR_SRC"
}

# --items 指定后，把工作副本里的候选 test_items 收敛成只剩摸底的那几项
rewrite_test_items() {
  local items_q="" i
  for i in $PROBE_ITEMS; do items_q="$items_q\"$i\" "; done
  items_q="${items_q% }"
  awk -v repl="test_items=($items_q)" '
    { line[NR]=$0; if ($0 ~ /^[[:space:]]*test_items=/) last=NR }
    END {
      for (i=1;i<=NR;i++) {
        if (i == last)                              print repl
        else if (line[i] ~ /^[[:space:]]*test_items=/) continue
        else                                        print line[i]
      }
      if (last == 0) print repl
    }' "$LR_SH" > "$LR_SH.probe.tmp" && mv "$LR_SH.probe.tmp" "$LR_SH"
}

if [ -n "$ITEMS_OVERRIDE" ]; then
  PROBE_ITEMS="$ITEMS_OVERRIDE"
else
  PROBE_ITEMS="$(read_test_items)"
  [ -n "$PROBE_ITEMS" ] || die "无法从 $LR_SRC 里解析出 test_items，请用 --items 显式指定"
fi

# ---------- 输出目录 ----------
STAMP="$(date +%Y-%m-%d-%H%M)"
[ -n "$OUT_DIR" ] || OUT_DIR="$(pwd)/hotspot-probe-$STAMP"
mkdir -p "$OUT_DIR" || die "无法创建输出目录 $OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
REPORT="$OUT_DIR/hotspot-probe-$STAMP.log"
SUMMARY="$OUT_DIR/hotspot-summary.tsv"
TSLOG="$OUT_DIR/sysbench-ts.log"
RAWLOG="$OUT_DIR/sysbench-raw.log"
PERF_DATA="$OUT_DIR/perf.data"
PERF_PID_FILE="$OUT_DIR/perf.pid"
LR_BAK="$OUT_DIR/localhost_run.sh.orig"   # 本次摸底所用正本的快照（只读留档，便于比对）
LR_SH="$OUT_DIR/localhost_run.sh.probe"   # 摸底工作副本：sed 与运行都只针对它
RESULTS_DIR="$OUT_DIR/results"
mkdir -p "$RESULTS_DIR"

# ---------- 生成 / 清理摸底工作副本（正本与部署副本全程不被改写）----------
LR_EDITED=0

edit_localhost_run() {
  # 从正本生成工作副本，并留一份正本快照供比对/复现
  cp -p "$LR_SRC" "$LR_BAK" || die "备份正本 $LR_SRC 失败"
  cp -p "$LR_SRC" "$LR_SH"  || die "从正本生成工作副本 $LR_SH 失败"

  # 只跑一轮、单个并发、缩短时长；tables/table_size 等一律保持原样，
  # 保证摸底的数据集与正式测试完全一致。
  sed -i -E "s|^rounds=.*|rounds=1|"                          "$LR_SH"
  sed -i -E "s|^threads=\(.*\)|threads=($PROBE_THREADS)|"      "$LR_SH"
  sed -i -E "s|^run_time=.*|run_time=$PROBE_TIME|"             "$LR_SH"
  sed -i -E "s|^warmup_time=.*|warmup_time=\"$PROBE_WARMUP\"|"  "$LR_SH"
  # 摸底时保证一个测试项只造一次数据（第一项造完，后续 oltp_* 项复用）
  sed -i -E "s|^force_clean_and_regenerate_data_at_item_test_start=.*|force_clean_and_regenerate_data_at_item_test_start=0|" "$LR_SH"

  if [ -n "$ITEMS_OVERRIDE" ]; then
    rewrite_test_items
  fi

  grep -qE "^threads=\($PROBE_THREADS\)" "$LR_SH" || die "改写工作副本的 threads 失败（格式变了？）"
  grep -qF "$(echo $PROBE_ITEMS | awk '{print $1}')" "$LR_SH" || die "改写工作副本的 test_items 失败（格式变了？）"
  LR_EDITED=1
}

# 正本/部署副本从未被改写，这里只需清理工作副本（无需"还原"）
cleanup_localhost_run_copy() {
  [ "$LR_EDITED" -eq 1 ] || return 0
  LR_EDITED=0
  if [ "$KEEP_LR" -eq 1 ]; then
    warn "--keep-lr：保留工作副本 $LR_SH（正本快照：$LR_BAK）"
    return 0
  fi
  rm -f "$LR_SH" && info "已清理摸底工作副本（正本 $LR_SRC 全程未被改写）" \
                || warn "清理工作副本 $LR_SH 失败，正本未受影响"
}

# ---------- perf 生命周期 ----------
PERF_JOB=""
stop_perf() {
  [ -n "$PERF_JOB" ] || return 0
  local p
  p="$(tr -dc '0-9' < "$PERF_PID_FILE" 2>/dev/null)"
  if [ -n "$p" ] && [ -d "/proc/$p" ]; then
    sudo kill -INT "$p" 2>/dev/null
  fi
  wait "$PERF_JOB" 2>/dev/null
  PERF_JOB=""
}

cleanup() {
  local rc=$?
  stop_perf
  cleanup_localhost_run_copy
  exit $rc
}
trap cleanup EXIT INT TERM

# ---------- 背景负载检查（与 sysbench_with_monitor.sh 同样的两条判据）----------
bg_load_cores() {
  ps -eo pid=,pcpu=,comm= --no-headers 2>/dev/null | awk -v mp="$MYSQLD_PID" -v me="$$" -v f=50 '
    $2+0 > f && $1 != mp && $1 != me && $3 !~ /^sysbench$/ && $3 !~ /^perf$/ && $3 !~ /^ps$/ && $3 !~ /^stdbuf$/ { s += $2 }
    END { printf "%d", (s+0)/100 }'
}
bg_same_name_clusters() {
  ps -eo pid=,pcpu=,comm= --no-headers 2>/dev/null | awk -v mp="$MYSQLD_PID" -v me="$$" -v f=50 '
    $2+0 > f && $1 != mp && $1 != me && $3 !~ /^sysbench$/ && $3 !~ /^perf$/ && $3 !~ /^ps$/ && $3 !~ /^stdbuf$/ { c[$3]++ }
    END { n=0; for (k in c) if (c[k] > 5) n++; print n+0 }'
}
check_bg_load() {
  local a=0 cores clu
  while :; do
    cores="$(bg_load_cores)"; clu="$(bg_same_name_clusters)"
    if [ "$cores" -le 3 ] && [ "$clu" -eq 0 ]; then
      info "背景负载检查通过（高负载 CPU 核数 $cores ≤ 3，同名进程聚集 无）"
      BG_LOAD="正常 (cores=$cores, cluster=0)"
      return 0
    fi
    a=$((a+1))
    if [ "$a" -ge 3 ]; then
      warn "背景负载偏高（cores=$cores, cluster=$clu），未等到负载降低，继续摸底但结果可能失真"
      BG_LOAD="偏高 (cores=$cores, cluster=$clu)"
      return 1
    fi
    warn "背景负载偏高（cores=$cores, cluster=$clu），等 30s 重试（第 $a 次）"
    sleep 30
  done
}

# ---------- 估算 perf 兜底时长 ----------
if [ -z "$BUDGET" ]; then
  n_items=$(echo $PROBE_ITEMS | wc -w)
  BUDGET=$(( PREPARE_ESTIMATE + n_items * (PROBE_WARMUP + PROBE_TIME + 20) + 180 ))
fi

# ---------- 开跑 ----------
info "mysqld pid = $MYSQLD_PID (socket $SOCKET)"
info "摸底测试项: $PROBE_ITEMS"
info "摸底并发 = $PROBE_THREADS，每项 warmup ${PROBE_WARMUP}s + run ${PROBE_TIME}s"
info "输出目录: $OUT_DIR"
[ "$CALLGRAPH" = "none" ] || warn "调用图模式 $CALLGRAPH 会显著变慢并把 perf.data 撑到数 GB"

check_bg_load || true

edit_localhost_run
info "已生成摸底工作副本：rounds=1 threads=($PROBE_THREADS) run_time=$PROBE_TIME warmup_time=$PROBE_WARMUP（正本与部署副本未被改写）"

CG_ARGS=""
[ "$CALLGRAPH" != "none" ] && CG_ARGS="--call-graph $CALLGRAPH"

info "启动 perf record（兜底上限 ${BUDGET}s）..."
sudo sh -c "echo \$\$ > '$PERF_PID_FILE'; exec perf record -o '$PERF_DATA' -p $MYSQLD_PID -F $PROBE_FREQ $CG_ARGS -- sleep $BUDGET" \
     > "$OUT_DIR/perf-record.out" 2>&1 &
PERF_JOB=$!
sleep 2
_p="$(tr -dc '0-9' < "$PERF_PID_FILE" 2>/dev/null)"
if [ -z "$_p" ] || ! sudo kill -0 "$_p" 2>/dev/null; then
  die "perf record 启动失败，见 $OUT_DIR/perf-record.out"
fi

info "开始 sysbench 摸底压测（perf 已在采样）..."
# 摸底不是正式测试：关掉驱动里 hook 的 run 阶段 iostat(w_await) 采集，
# 免得给摸底日志添乱、也不与 perf 采样抢同一批 CPU/IO（正式测试时才采集）。
export IOSTAT_RUN_MONITOR=0
# stdbuf 强制行缓冲：否则 sysbench 写管道时按 4KB 块刷，时间戳会成串、无法切分窗口
stdbuf -oL -eL "$LR_SH" 2>&1 \
  | while IFS= read -r _line; do printf '%s\t%s\n' "$(mono_now)" "$_line"; done > "$TSLOG"
LR_RC=${PIPESTATUS[0]}
cut -f2- "$TSLOG" > "$RAWLOG"

info "sysbench 摸底结束（退出码 $LR_RC），停止 perf ..."
stop_perf

if grep -qE 'fail to (prepare|cleanup)' "$RAWLOG" 2>/dev/null; then
  die "sysbench prepare/cleanup 失败，摸底无效，见 $RAWLOG"
fi
if [ "$LR_RC" -ne 0 ]; then
  warn "驱动退出码 $LR_RC，见 $RAWLOG"
fi
if ! grep -q "Captured and wrote" "$OUT_DIR/perf-record.out" 2>/dev/null; then
  warn "perf 未见正常收尾信息，见 $OUT_DIR/perf-record.out"
fi
# 判断有没有采到样本。整份 perf report（94MB perf.data 上输出几百 MB）在这里毫无必要，
# `--percent-limit 100` 让表格一行都不打，只剩 header + `# Samples:` 那一行。
# 注意：不能用 `--header-only` —— 它只打 header，而 `# Samples:` 是 report 主体打的，
# 用 --header-only 会永远匹配不到，把一次正常的摸底判成"无样本"。
if ! sudo perf report -i "$PERF_DATA" --header --stdio --percent-limit 100 2>/dev/null \
     | grep -qE '^# Samples: [1-9]'; then
  die "perf.data 无可读样本（$PERF_DATA），本次摸底无效"
fi

cleanup_localhost_run_copy

###############################################################################
# ---------- 分析 ----------
###############################################################################

# 从带时间戳的日志里切出每个测试项的 perf 时间窗。
#
# **只取 run 阶段，不含 warmup。** 摸底默认 warmup=30s + run=30s，如果从
# `... <item>.lua ... run` 那一行开始切，窗口里有一半样本来自预热前的爬坡
# （线程刚起、buffer pool/AHI 还在建），热点画像会被污染。预热的意义恰恰是
# 让被测阶段处于稳态，所以归因窗口必须落在 run 阶段。
#
# run 起点怎么拿（按可靠性排序）：
#   1. 第一条 `[ Ns ] thds: ...` 中间报告行 —— 它一定是 run 开始后第 N 秒打印的，
#      所以 run 起点 = 该行时间戳 - N（实测与 `Threads started! + warmup` 吻合到 0.01s）
#   2. 没有中间报告行（run_time < report_interval）时：`Threads started!` 时间戳 + `Warmup time: Ns`
#   3. 都拿不到：退回 `... <item>.lua ... run` 那一行（含 warmup，日志里会标注）
# 终点 = `execution time (avg/stddev)` 之后 1s（此时 run 阶段刚结束、sysbench 即将退出）
#
# 输出: item \t start \t end \t tps \t p95
parse_windows() {
  awk -F'\t' '
  {
    ts=$1; last=ts
    line=$0; sub(/^[^\t]*\t/, "", line)

    if (line ~ /start to run test: /) {
      if (cur != "") close_it(ts)
      cur=""; next
    }
    if (line ~ /\.lua/ && line ~ /(^|[ \t])run[ \t]*$/) {
      # 取测试项名：必须"先砍 .lua 之后、再取 basename"。顺序不能反——
      # 命令行里 --mysql-socket=.../mysql.sock 排在 .lua 之后，先按斜杠切会切到 mysql.sock 上。
      t=line; sub(/\.lua.*/, "", t); sub(/.*\//, "", t)
      if (t == "") next
      if (cur != "" && cur != t) close_it(ts)
      cur=t
      if (!(cur in anchor)) { anchor[cur]=ts; order[++n]=cur }
      next
    }
    if (cur != "") {
      if (line ~ /^\[ *[0-9]+s *\]/) {
        v=line; sub(/^\[ */, "", v); sub(/s *\].*/, "", v)
        if (!(cur in runstart)) runstart[cur]=ts-v
      }
      if (line == "Threads started!" && !(cur in tstart)) tstart[cur]=ts
      if (line ~ /^Warmup time: *[0-9]+s/) {
        v=line; sub(/^Warmup time: */, "", v); sub(/s.*/, "", v); warm[cur]=v+0
      }
      v=line
      if (sub(/.*transactions:[ \t]+[0-9]+[ \t]+\(/, "", v)) { sub(/[ \t].*/, "", v); tps[cur]=v }
      v=line
      if (sub(/.*95th percentile:[ \t]*/, "", v))            { sub(/[^0-9.].*/, "", v); p95[cur]=v }
      if (line ~ /execution time \(avg\/stddev\)/)           { endtight[cur]=ts }
    }
  }
  function close_it(ts,   c) {
    if (cur == "") return
    c=cur
    if      (c in runstart) { start[c]=runstart[c]; src[c]="run" }
    else if ((c in tstart) && (c in warm)) { start[c]=tstart[c]+warm[c]; src[c]="run(ts+warm)" }
    else                    { start[c]=anchor[c]; src[c]="含warmup(退回锚点)" }
    if (c in endtight) end[c]=endtight[c]+1.0
    else               end[c]=ts
    cur=""
  }
  END {
    if (cur != "") close_it(last)
    for (i=1;i<=n;i++) {
      st=start[order[i]]; en=end[order[i]]
      # 时间列必须显式给小数位：%s 走 awk 的 CONVFMT(默认 %.6g)，在 ~9e5 量级的
      # CLOCK_MONOTONIC 时间戳上只剩 ~1s 分辨率，会把 31.09s 的窗口印成 32s，
      # 而且这两个值原样传给 perf report --time。
      if (st == "" || en == "") continue
      printf "%s\t%.2f\t%.2f\t%s\t%s\t%s\n", order[i], st, en, tps[order[i]], p95[order[i]], src[order[i]]
    }
  }' "$TSLOG"
}

WINDOWS_TSV="$OUT_DIR/windows.tsv"
parse_windows > "$WINDOWS_TSV"
[ -s "$WINDOWS_TSV" ] || warn "无法从 sysbench 日志切出测试项时间窗，退化为全会话聚合（无法按测试项归因）"

# 从 perf report 输出里抽 Top 函数 + 分类占比。
# 前 15 行是明细（自身占比 \t 类别 \t 态 \t 函数），最后一行 ##SUM 是合计。
analyze_perf_report() {
  awk '
  BEGIN {
    spin_re = "ut_delay|_mm_pause|px_pause|pause|spin_loop|UT_RELAX"
    wait_re = "lll_lock|lll_unlock|pthread_mutex|pthread_cond|pthread_rwlock|futex|os_event|os_cond|sched_yield|nanosleep|epoll_wait|__GI___libc_|mysql_mutex|mysql_cond|mysql_rwlock"
    lock_re = "rw_lock|lock_rec|lock_table|lock_clust|lock_sec|lock_wait|lock_sys|lock0lock|trx_sys|sync_array|mutex_enter|mutex_exit|que_thread|mdl_|MDL_|ib_mutex"
  }
  function classify(s,   x) {
    x = tolower(s)
    if (x ~ spin_re) return "自旋"
    if (x ~ wait_re) return "等待"
    if (x ~ lock_re) return "锁"
    return "其他"
  }
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*[0-9]+\.[0-9]+%/ {
    pct = $1; sub(/%$/, "", pct); pct += 0
    rest = $0
    sub(/^[[:space:]]*[0-9]+\.[0-9]+%[[:space:]]+/, "", rest)
    state = "用户态"
    if (rest ~ /^\[k\]/) state = "内核态"
    sub(/^\[[.kgu]\] /, "", rest)
    sub(/^\[unknown\] /, "", rest)
    sub(/[[:space:]][[:space:]]+.*$/, "", rest)     # 截到第一段连续空白
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", rest)
    if (rest == "") next
    cls = classify(rest)
    if      (cls == "自旋") spin += pct
    else if (cls == "等待") wait += pct
    else if (cls == "锁")   lock += pct
    if (state == "内核态") kern += pct
    else                   user += pct
    if (++i <= 15) printf "%s\t%s\t%s\t%s\n", pct, cls, state, rest
  }
  END {
    printf "##SUM\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%d\n", spin, wait, lock, spin+wait+lock, user, kern, user+kern, i
  }'
}

# 单个测试项：切窗口 → perf report → 解析
#
# 排序必须用 `--sort overhead`（按自身占比降序）。用 `--sort symbol` 是按**函数名字典序**
# 排列，表格第一行只是名字最靠前的那个函数，不是最热的那个 —— 而 Top1 恰恰是判定的依据，
# 会直接把 20%+ 的热点判成 OK。
ITEM_SAMPLES=""
probe_one_item() {
  local item="$1" s="$2" e="$3"
  local rf="$OUT_DIR/perf-report-$item.txt"
  local out="$RESULTS_DIR/$item.out"
  : > "$out"
  sudo perf report -i "$PERF_DATA" --stdio --header --time "$s,$e" \
       --sort overhead --call-graph none -F overhead,symbol --percent-limit 0.01 \
       > "$rf" 2>"$rf.err"
  ITEM_SAMPLES="$(samples_of_report "$rf")"
  if ! grep -qE '^[[:space:]]*[0-9]+\.[0-9]+%' "$rf" 2>/dev/null; then
    warn "$item：窗口 $s,$e 内没有样本（见 $rf.err）"
    return 1
  fi
  analyze_perf_report < "$rf" > "$out"
  return 0
}

for item in $PROBE_ITEMS; do
  w="$(awk -F'\t' -v it="$item" '$1==it{print; exit}' "$WINDOWS_TSV")"
  s=""; e=""
  if [ -n "$w" ]; then s="$(echo "$w" | cut -f2)"; e="$(echo "$w" | cut -f3)"; fi
  if [ -z "$s" ] || [ -z "$e" ]; then
    warn "$item：日志里没有对应的时间窗，跳过 perf 归因"
    continue
  fi
  wsrc="$(echo "$w" | cut -f6)"
  [ "$wsrc" = "run" ] || warn "$item：归因窗口起点不是从中间报告行推出来的（$wsrc），可能含预热段"
  info "$item：perf 时间窗 $s ~ $e（宽 $(awk -v a="$s" -v b="$e" 'BEGIN{printf "%.1f", b-a}')s）"
  probe_one_item "$item" "$s" "$e" && info "$item：样本 $ITEM_SAMPLES" || true
done

# 一项都没切出来 → 退化为全会话聚合
if [ ! -s "$WINDOWS_TSV" ]; then
  sudo perf report -i "$PERF_DATA" --stdio --header --sort overhead --call-graph none \
       -F overhead,symbol --percent-limit 0.01 > "$OUT_DIR/perf-report-ALL.txt" 2>/dev/null
  analyze_perf_report < "$OUT_DIR/perf-report-ALL.txt" > "$RESULTS_DIR/ALL.out"
fi

###############################################################################
# ---------- 生成报告 ----------
###############################################################################

{
echo "# 热点摸底报告（hotspot probe）"
echo
echo "- 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "- 机器: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')  （$(nproc) 逻辑 CPU）"
echo "- mysqld: pid=$MYSQLD_PID  socket=$SOCKET"
echo "- 摸底参数: 并发=$PROBE_THREADS，每项 warmup=${PROBE_WARMUP}s + run=${PROBE_TIME}s，测试项: $PROBE_ITEMS"
echo "- 归因窗口: 每个测试项**只取 run 阶段**（不含 warmup），窗口 ≈ run 时长 + 1s；起止点推算方式见 windows.tsv 第 6 列"
echo "- perf: 采样 mysqld 全线程（-p $MYSQLD_PID），-F $PROBE_FREQ，callgraph=$CALLGRAPH"
echo "- 背景负载: ${BG_LOAD:-未检查}"
echo "- 判定阈值: 单函数自身占比 > ${PAUSE_PCT}% → **PAUSE 暂停测试**；> ${WARN_PCT}% 或阻塞类合计 > ${BLOCK_WARN_PCT}% → WARN；样本 < ${MIN_SAMPLES} → 样本不足"
echo "- 原始数据: $OUT_DIR"
echo
echo "## 汇总"
echo
echo "| 测试项 | 样本数 | 窗口(s) | Top1 函数 | Top1 自身占比 | 自旋 | 等待 | 锁 | 阻塞类合计 | 内核态 | TPS | p95(ms) | 判定 |"
echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|"
} > "$REPORT"

: > "$SUMMARY"
printf 'item\tverdict\tsamples\twindow_s\ttop1_sym\ttop1_pct\tspin_pct\twait_pct\tlock_pct\tblock_pct\tkernel_pct\ttps\tp95\n' >> "$SUMMARY"

PAUSE_HITS=""; WARN_HITS=""
n_pause=0; n_warn=0
overall_rc=0

for item in $PROBE_ITEMS; do
  f="$RESULTS_DIR/$item.out"
  # 真实样本数取 perf 的窗口内计数
  samples=0
  rf="$OUT_DIR/perf-report-$item.txt"
  if [ -s "$rf" ]; then
    samples="$(samples_of_report "$rf")"
  fi
  [ -n "$samples" ] || samples=0
  w="$(awk -F'\t' -v it="$item" '$1==it{print; exit}' "$WINDOWS_TSV")"
  win="-"; tps="-"; p95="-"
  if [ -n "$w" ]; then
    win="$(awk -v a="$(echo "$w"|cut -f2)" -v b="$(echo "$w"|cut -f3)" 'BEGIN{printf "%.1f", b-a}')"
    tps="$(echo "$w" | cut -f4)"; [ -n "$tps" ] || tps="-"
    p95="$(echo "$w" | cut -f5)"; [ -n "$p95" ] || p95="-"
  fi

  spin=0; waitp=0; lockp=0; block=0; kern=0; top1="-"; top1p=0
  if [ -s "$f" ]; then
    sum="$(grep -m1 '^##SUM' "$f")"
    spin="$(echo "$sum"|cut -f2)"; waitp="$(echo "$sum"|cut -f3)"; lockp="$(echo "$sum"|cut -f4)"
    block="$(echo "$sum"|cut -f5)"; kern="$(echo "$sum"|cut -f7)"
    top1="$(awk -F'\t' '!/^##SUM/{print $4; exit}' "$f")"
    top1p="$(awk -F'\t' '!/^##SUM/{print $1; exit}' "$f")"
    [ -n "$top1" ] || top1="-"
    [ -n "$top1p" ] || top1p=0
  fi

  # 判定：先看单函数自身占比，再看阻塞类，最后才看样本数
  verdict="OK"
  if awk -v a="$top1p" -v b="$PAUSE_PCT" 'BEGIN{exit !(a+0 > b+0)}'; then
    verdict="PAUSE"
  elif awk -v a="$top1p" -v b="$WARN_PCT" 'BEGIN{exit !(a+0 > b+0)}'; then
    verdict="WARN"
  elif awk -v a="$block" -v b="$BLOCK_WARN_PCT" 'BEGIN{exit !(a+0 > b+0)}'; then
    verdict="WARN(阻塞类偏高)"
  elif [ ! -s "$f" ]; then
    verdict="WARN(无样本)"
  elif [ "$samples" -lt "$MIN_SAMPLES" ]; then
    verdict="WARN(样本不足)"
  fi

  case "$verdict" in
    PAUSE) n_pause=$((n_pause+1)); PAUSE_HITS="$PAUSE_HITS $item"
           [ "$overall_rc" -lt 2 ] && overall_rc=2 ;;
    WARN*) n_warn=$((n_warn+1)); WARN_HITS="$WARN_HITS $item"
           [ "$overall_rc" -lt 1 ] && overall_rc=1 ;;
  esac

  printf '| %s | %s | %s | `%s` | %s%% | %s%% | %s%% | %s%% | %s%% | %s%% | %s | %s | **%s** |\n' \
    "$item" "$samples" "$win" "$top1" "$top1p" "$spin" "$waitp" "$lockp" "$block" "$kern" "$tps" "$p95" "$verdict" >> "$REPORT"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$item" "$verdict" "$samples" "$win" "$top1" "$top1p" "$spin" "$waitp" "$lockp" "$block" "$kern" "$tps" "$p95" >> "$SUMMARY"
done

# ---------- 明细 ----------
{
echo
echo "## 明细"
} >> "$REPORT"

for item in $PROBE_ITEMS; do
  f="$RESULTS_DIR/$item.out"
  [ -s "$f" ] || continue
  sum="$(grep -m1 '^##SUM' "$f")"
  {
  echo
  echo "### $item"
  echo
  echo "- 自旋类 \`$(echo "$sum"|cut -f2)%\` · 等待类 \`$(echo "$sum"|cut -f3)%\` · 锁类 \`$(echo "$sum"|cut -f4)%\` · **阻塞类合计 \`$(echo "$sum"|cut -f5)%\`**"
  echo "- 内核态 \`$(echo "$sum"|cut -f7)%\` · 用户态 \`$(echo "$sum"|cut -f6)%\`"
  echo
  echo "| # | 函数 | 自身占比 | 类别 | 态 |"
  echo "|---|---|---|---|---|"
  awk -F'\t' -v p="$PAUSE_PCT" -v w="$WARN_PCT" \
    '!/^##SUM/{ m=""; if ($1+0 > p+0) m=" ⚠️（超过 " p "%，须暂停）"; else if ($1+0 > w+0) m=" ⚠️";
       printf "| %d | `%s`%s | %s%% | %s | %s |\n", ++i, $4, m, $1, $2, $3 }' "$f"
  } >> "$REPORT"
done

# ---------- 判读与下一步 ----------
{
echo
echo "## 判读"
echo
if [ "$n_pause" -gt 0 ]; then
  echo "**结论：PAUSE —— 存在异常热点，按规则暂停测试。**"
  echo
  echo "以下测试项有单个函数自身占比超过 ${PAUSE_PCT}%："
  for item in $PAUSE_HITS; do
    f="$RESULTS_DIR/$item.out"
    [ -s "$f" ] || f="$RESULTS_DIR/ALL.out"
    echo "- \`$item\`：\`$(awk -F'\t' '!/^##SUM/{print $4}' "$f" | head -1)\` 自身占比 $(awk -F'\t' '!/^##SUM/{print $1; exit}' "$f")%"
  done
  echo
  echo "请先把这个热点报告给用户，确认根因/处置方式之后再决定是否继续性能测试；**不要直接开跑**。"
  echo "常见成因：自旋预算过大（\`innodb_sync_spin_loops\`/\`innodb_spin_wait_delay\`/\`innodb_spin_wait_pause_multiplier\` 乘积过大，\`ut_delay\` 会独占热点）、"
  echo "某个全局锁串行化（\`trx_sys\`/\`lock_sys\`/\`rw_lock_*\`）、日志/刷脏路径瓶颈、或并发数远超 CPU 核数导致的排队。"
  echo
  echo "如果这个函数既不是自旋也不是等锁（例如 \`my_lfind\` 这种查表/指针追逐），它很可能是**访存延迟**热点："
  echo "用上面的 IP 直方图 + \`addr2line\` 看到最热的那条指令是 load，就说明卡在等缓存行/内存，"
  echo "**调自旋参数、查锁竞争都不会有改善**，要从数据结构（链长、布局、局部性）上找办法。"
elif [ "$n_warn" -gt 0 ]; then
  echo "**结论：WARN —— 没有超过 ${PAUSE_PCT}% 的单函数热点，但存在需要说明的情况，已在上面写清；可以继续正式测试。**"
  echo
  for item in $WARN_HITS; do
    f="$RESULTS_DIR/$item.out"
    [ -s "$f" ] || f="$RESULTS_DIR/ALL.out"
    if [ -s "$f" ]; then
      echo "- \`$item\`：Top1 \`$(awk -F'\t' '!/^##SUM/{print $4}' "$f" | head -1)\` ($(awk -F'\t' '!/^##SUM/{print $1; exit}' "$f")%)"
    else
      echo "- \`$item\`：无样本 / 无时间窗"
    fi
  done
else
  echo "**结论：OK —— 各测试项的并发热点分布正常，没有单函数自身占比超过 ${PAUSE_PCT}% 的异常热点。**"
fi
echo
echo "进一步定位（时间窗见汇总表，来源见 sysbench-ts.log）："
echo
echo '```bash'
echo "sudo perf report -i $PERF_DATA --stdio --time <start>,<end> --sort overhead,dso     # 看是哪个模块在烧"
echo "sudo perf report -i $PERF_DATA --stdio --time <start>,<end> --sort overhead,pid     # 看是哪些线程在烧"
echo "sudo perf report -i $PERF_DATA --stdio --time <start>,<end> --sort overhead -F overhead,symbol,overhead_sys,overhead_us"
echo "cat $OUT_DIR/perf-report-<item>.txt          # 该测试项的 Top 函数明细（已按自身占比降序）"
echo "grep -n 'start to run test' $TSLOG                                                # 看时间窗来源"
echo
echo "# 若热点集中在某一个函数上，继续定位到函数里的具体指令（热点常常就是一条 load）："
echo "sudo perf script -i $PERF_DATA --time <start>,<end> -F ip,sym \\"
echo "  | awk '{print \$1}' | sort | uniq -c | sort -rn | head -20   # 最热的 IP"
echo "addr2line -e $MYSQL_BIN -f -C -i 0x<最热的IP>                     # IP → 源码行"
echo '```'
echo
echo "> 提示：内核态样本里有一部分是 **perf 自己**（\`perf_event_*\`、\`x86_pmu_*\`、采样中断里的"
echo "> \`_raw_spin_lock\` 等）。它们通常合计几个百分点，属正常采样开销；"
echo "> 若合计明显偏高（比如 >10%），说明 \`--freq\` 对本机并发偏高，可降到 199 再摸一次。"
echo
echo "## 复现"
echo
echo '```bash'
echo "cd \$HOME/database/$REPO/test/sysbench   # 正式测试仍从这里起（驱动正本见下）"
# 用脚本自身的绝对路径：本脚本用 readlink -f 自定位，写死相对路径在换目录、换宿主时
# 一定会错。
echo "$SELF --threads $PROBE_THREADS --time $PROBE_TIME --warmup $PROBE_WARMUP --freq $PROBE_FREQ"
echo "# 正式测试（驱动正本 → 部署副本自动同步）:"
echo "$SCRIPTS_DIR/sysbench_with_monitor.sh"
echo '```'
} >> "$REPORT"

# ---------- 屏幕横幅 ----------
echo
echo "================================================================"
if [ "$n_pause" -gt 0 ]; then
  echo "[摸底] 结论: PAUSE —— 存在异常热点，必须暂停测试"
  for item in $PAUSE_HITS; do
    f="$RESULTS_DIR/$item.out"; [ -s "$f" ] || f="$RESULTS_DIR/ALL.out"
    echo "        $item : $(awk -F'\t' '!/^##SUM/{print $4}' "$f" | head -1) 自身占比 $(awk -F'\t' '!/^##SUM/{print $1; exit}' "$f")% (> ${PAUSE_PCT}%)"
  done
elif [ "$n_warn" -gt 0 ]; then
  echo "[摸底] 结论: WARN —— 有需要说明的热点（未超 ${PAUSE_PCT}%），已在日志写清，可继续测试"
else
  echo "[摸底] 结论: OK —— 未发现异常热点"
fi
echo "[摸底] 报告: $REPORT"
echo "[摸底] 汇总: $SUMMARY"
echo "================================================================"

exit $overall_rc
