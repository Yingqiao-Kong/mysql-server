#!/bin/bash
###############################################################################
# sysbench_with_monitor.sh
# 包装 localhost_run.sh，在测试前和测试运行期间监控系统负载。
# 若检测到高负载干扰（CPU 占用聚集 >3 核心或同名进程聚集 >5），
# 则中止当前测试，等待负载降低后自动重启测试。
#
# 用法: ./sysbench_with_monitor.sh [localhost_run.sh 的参数]
###############################################################################

# ---------- 配置 ----------
# 高负载判定阈值：CPU 使用率 > 50% 的非排除进程 pcpu 之和 / 100 > 该值
LOAD_THRESHOLD=3
# 单次检测中 pcpu 大于此值的进程才计入
PCPU_FLOOR=50.0
# 同名进程聚集阈值：同名进程数超过该值则判定为高负载
SAME_NAME_THRESHOLD=5
# 运行中监控间隔（秒）
MONITOR_INTERVAL=10
# 负载等待重试间隔（秒）
WAIT_INTERVAL=30
# MySQL PID 文件路径（用于排除 mysqld 进程）
MYSQL_PID_FILE="$HOME/database/txsql/install/mysql.sock/../mysqld.pid"
# 最大重试次数
MAX_RETRIES=10

# ---------- 函数 ----------

# 计算当前高负载占用的 CPU 核心数（排除 mysql/sysbench/自身）
calc_high_load_cpus() {
  local mysql_pid=""
  # 尝试多种方式获取 mysql pid
  if [ -f "$MYSQL_PID_FILE" ]; then
    mysql_pid=$(cat "$MYSQL_PID_FILE" 2>/dev/null)
  fi
  if [ -z "$mysql_pid" ]; then
    mysql_pid=$(ps -eo pid,comm --no-headers | grep '[m]ysqld' | head -1 | awk '{print $1}')
  fi
  local my_pid=$$

  ps -eo pid,pcpu,comm --no-headers | \
    awk -v mysql_pid="$mysql_pid" \
        -v my_pid="$my_pid" \
        -v pcpu_floor="$PCPU_FLOOR" \
    '$2 > pcpu_floor && $1 != mysql_pid && $1 != my_pid && $3 !~ /sysbench/ && $3 !~ /monitor/ && $3 !~ /^ps$/ && $3 !~ /mysqld/ { sum += $2 }
     END { printf "%d", (sum + 0) / 100 }'
}

# 检查是否存在同名进程聚集（超过阈值个同名进程 CPU > 50%，排除 mysql/sysbench/自身）
# 返回值：0 = 存在同名聚集（繁忙），1 = 无同名聚集（正常）
check_same_name_cluster() {
  local mysql_pid=""
  if [ -f "$MYSQL_PID_FILE" ]; then
    mysql_pid=$(cat "$MYSQL_PID_FILE" 2>/dev/null)
  fi
  if [ -z "$mysql_pid" ]; then
    mysql_pid=$(ps -eo pid,comm --no-headers | grep '[m]ysqld' | head -1 | awk '{print $1}')
  fi
  local my_pid=$$

  ps -eo pid,pcpu,comm --no-headers | \
    awk -v mysql_pid="$mysql_pid" \
        -v my_pid="$my_pid" \
        -v pcpu_floor="$PCPU_FLOOR" \
        -v threshold="$SAME_NAME_THRESHOLD" \
    '$2 > pcpu_floor && $1 != mysql_pid && $1 != my_pid && $3 !~ /sysbench/ && $3 !~ /monitor/ && $3 !~ /^ps$/ && $3 !~ /mysqld/ { name_count[$3]++ }
     END { found=0; for (n in name_count) if (name_count[n] > threshold) found=1; exit !found }'
}

# 列出当前同名进程聚集详情（供告警展示）
list_same_name_clusters() {
  local mysql_pid=""
  if [ -f "$MYSQL_PID_FILE" ]; then
    mysql_pid=$(cat "$MYSQL_PID_FILE" 2>/dev/null)
  fi
  if [ -z "$mysql_pid" ]; then
    mysql_pid=$(ps -eo pid,comm --no-headers | grep '[m]ysqld' | head -1 | awk '{print $1}')
  fi
  local my_pid=$$

  echo "=== 同名进程聚集列表 ==="
  ps -eo pid,pcpu,comm --no-headers | \
    awk -v mysql_pid="$mysql_pid" -v my_pid="$my_pid" -v pcpu_floor="$PCPU_FLOOR" -v threshold="$SAME_NAME_THRESHOLD" \
    '$2 > pcpu_floor && $1 != mysql_pid && $1 != my_pid && $3 !~ /sysbench/ && $3 !~ /monitor/ && $3 !~ /^ps$/ && $3 !~ /mysqld/ { name_count[$3]++; procs[$3] = procs[$3] sprintf("  PID=%-8s CPU=%.1f%%\n", $1, $2) }
     END { for (n in name_count) if (name_count[n] > threshold) { printf "  进程名: %s (数量: %d, 超过阈值 %d)\n", n, name_count[n], threshold; printf "%s", procs[n] } }'
  echo "======================"
}

# 列出当前高负载进程（供告警展示）
list_high_load_procs() {
  local mysql_pid=""
  if [ -f "$MYSQL_PID_FILE" ]; then
    mysql_pid=$(cat "$MYSQL_PID_FILE" 2>/dev/null)
  fi
  if [ -z "$mysql_pid" ]; then
    mysql_pid=$(ps -eo pid,comm --no-headers | grep '[m]ysqld' | head -1 | awk '{print $1}')
  fi
  local my_pid=$$

  echo "=== 高负载进程列表 ==="
  ps -eo pid,pcpu,comm --no-headers | \
    awk -v mysql_pid="$mysql_pid" -v my_pid="$my_pid" -v pcpu_floor="$PCPU_FLOOR" \
    '$2 > pcpu_floor && $1 != mysql_pid && $1 != my_pid && $3 !~ /sysbench/ && $3 !~ /monitor/ && $3 !~ /^ps$/ && $3 !~ /mysqld/ { printf "  PID=%-8s CPU=%.1f%%  CMD=%s\n", $1, $2, $3 }'
  echo "======================"
}

# 测试前等待负载降低
wait_for_low_load() {
  local attempt=0
  while true; do
    local load_cpus=$(calc_high_load_cpus)
    local cluster_busy=0
    check_same_name_cluster && cluster_busy=1
    if [ "$load_cpus" -le "$LOAD_THRESHOLD" ] && [ "$cluster_busy" -eq 0 ]; then
      echo "[负载检查] 系统负载正常 (高负载CPU核心数: ${load_cpus}，阈值: ${LOAD_THRESHOLD}；同名进程聚集: 无)，可以开始测试。"
      return 0
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$MAX_RETRIES" ]; then
      echo "[负载检查] 等待超时 (${MAX_RETRIES} 次)，强制继续测试。"
      return 1
    fi
    if [ "$load_cpus" -gt "$LOAD_THRESHOLD" ]; then
      echo "[负载检查] WARNING: 检测到高负载进程占用 ${load_cpus} 个CPU核心 (阈值: ${LOAD_THRESHOLD})，等待负载降低... (第${attempt}次)"
      list_high_load_procs
    fi
    if [ "$cluster_busy" -eq 1 ]; then
      echo "[负载检查] WARNING: 检测到同名进程聚集 (超过 ${SAME_NAME_THRESHOLD} 个同名进程 CPU > ${PCPU_FLOOR}%)，等待负载降低... (第${attempt}次)"
      list_same_name_clusters
    fi
    sleep "$WAIT_INTERVAL"
  done
}

# ---------- 主流程 ----------

RETRY_COUNT=0

# 从当前工作目录查找 localhost_run.sh
RUN_SH="$(pwd)/localhost_run.sh"
if [ ! -x "$RUN_SH" ]; then
  echo "ERROR: 在当前目录 $(pwd) 下找不到可执行的 localhost_run.sh"
  echo "请先 cd 到 $HOME/database/<REPO>/test/sysbench 目录再运行本脚本。"
  exit 1
fi

while true; do
  # 1) 测试前负载检查
  wait_for_low_load

  # 2) 启动 sysbench 测试（后台）
  echo "[监控] 启动 sysbench 测试..."
  LOG_FILE="perf-monitored-$(date +%Y-%m-%d-%H-%M).log"
  $RUN_SH "$@" > "$LOG_FILE" 2>&1 &
  RUN_PID=$!

  # 3) 运行中每 10 秒监控负载
  INTERRUPTED=0
  while kill -0 "$RUN_PID" 2>/dev/null; do
    sleep "$MONITOR_INTERVAL"
    if ! kill -0 "$RUN_PID" 2>/dev/null; then
      break
    fi
    local_load=$(calc_high_load_cpus)
    cluster_busy=0
    check_same_name_cluster && cluster_busy=1
    if [ "$local_load" -gt "$LOAD_THRESHOLD" ] || [ "$cluster_busy" -eq 1 ]; then
      echo "[监控] ALERT: 测试运行期间检测到高负载干扰 (占用 ${local_load} CPU核心${cluster_busy:+，存在同名进程聚集})，中止当前测试！"
      list_high_load_procs
      [ "$cluster_busy" -eq 1 ] && list_same_name_clusters
      kill -TERM "$RUN_PID" 2>/dev/null
      wait "$RUN_PID" 2>/dev/null
      INTERRUPTED=1
      break
    fi
  done

  # 4) 如果未被中断，测试正常完成
  if [ "$INTERRUPTED" -eq 0 ]; then
    wait "$RUN_PID" 2>/dev/null
    EXIT_CODE=$?
    echo "[监控] sysbench 测试正常完成 (退出码: ${EXIT_CODE})。"
    echo "[监控] 日志文件: ${LOG_FILE}"
    # 输出日志内容
    cat "$LOG_FILE"
    exit "$EXIT_CODE"
  fi

  # 5) 被中断 → 等待负载降低后重试
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
    echo "[监控] 已达到最大重试次数 (${MAX_RETRIES})，放弃测试。上次日志: ${LOG_FILE}"
    exit 1
  fi
  echo "[监控] 第 ${RETRY_COUNT} 次重试：等待高负载消失后重新启动测试..."
  wait_for_low_load
done
