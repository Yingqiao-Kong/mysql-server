#!/bin/bash

# ATTENTION:
# 初次使用本脚本时，一定要提前修改socket、ip、port、auto-inc、db-ps-node、table、table-size等参数的值，确认好测试配置

enable_binlog_removing=1
#sleep 10800

test_items=("oltp_insert" "oltp_update_index" "oltp_delete" "oltp_point_select" "oltp_read_write")
test_items=("oltp_read_write" "oltp_write_only" "oltp_update_index" "oltp_insert" "oltp_delete")
test_items=("oltp_read_write" "oltp_write_only")
#test_items=("oltp_read_write")
threads=(64 128 256 512)  # 默认并发压力；备选档见下方注释行，改默认直接改这一行
#threads=(10 40 70 100)
#threads=(400)

sysbench_bind_nodes=("8-11")
force_clean_and_regenerate_data_at_item_test_start=0 # 为1时，强制要求每个测试项测试时删除前一个测试项的数据，并重新生成数据

bin_dir="$HOME/tools/sysbench-master/install/bin"
lua_dir="$HOME/tools/sysbench-master/install/share/sysbench"

# REPO: 当前测试仓库名（mysql / polarDb / txsql）。默认 mysql，可用环境变量 REPO=<name> 覆盖。
REPO="${REPO:-mysql}"
INSTALL_DIR="$HOME/database/$REPO/install"

# 通信方式（由 skill 步骤 0 询问后写入，下列两行必须配套）：
#   1) unix socket：socket 非空 且 ip="localhost"  → 走 --mysql-socket
#   2) tcp/ip     ：socket=""  且 ip="127.0.0.1"   → 走 --mysql-host/--mysql-port
# 注（sysbench 的真实行为；2026-10-10 读源码 + 探针在 8.0.44 客户端库上实测）：
#   * sysbench 的 mysql driver 只要收到**非空** --mysql-socket，就丢弃 --mysql-host，
#     把 host 硬编码成 "localhost"（src/drivers/mysql/drv_mysql.c:483-516），因此必然
#     走 unix socket —— 此时 ip 那行写什么都无所谓（写 IP 也一样走 socket）。
#     传空串与不传等价（sb_options.c:139 ⇒ 列表为空）。
#   * 只有 socket 为空时才用 ip/port。此时若 ip 仍是 "localhost"（或空），libmysqlclient
#     会去连**编译默认的 socket** /var/lib/mysql/mysql.sock，而不是 TCP（实测报 2002），
#     所以 tcp/ip 档必须显式写 IP —— 这就是两行必须成对改的原因。
socket="$INSTALL_DIR/mysql.sock"  # 非空 ⇒ sysbench 一定走 socket（并丢弃 ip）；置空才走 TCP/IP
ip="localhost"                    # 仅 socket 为空时才生效；那时必须写 IP，写 localhost 会去连默认 socket
port=4306
run_time=100
user="root"
passwd="123456"
auto_inc="on"
db_ps_mode="auto"
tables=32
table_size=1000000
warmup_time="20"
rounds=1
thread_init_timeout=3000
report_interval=10

config_dir="$INSTALL_DIR/my.cnf"
cat $config_dir

echo
cat /proc/version

echo
cat /proc/cmdline

echo
ldd --version

echo
df -h
binlog_dir=`cat $config_dir | grep 'log-bin' | awk -F '=' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}'`
binlog_dir=`dirname $binlog_dir`
dev=`df $binlog_dir | tail -1 | awk '{print $1}'`
disk=`lsblk -o NAME,TYPE,SIZE,MOUNTPOINT --inverse $dev | tail -1 | sed 's/└─\([^ ]*\).*/\1/' | sed 's/ //g'`
disk_queue_scheduler=`cat /sys/block/$disk/queue/scheduler`
if (( $? != 0 ));then
    echo "Retry to detect disk..."
    disk=`lsblk -o NAME,TYPE,SIZE,MOUNTPOINT --inverse $dev | tail -1 | sed 's/\([^ ]*\).*/\1/' | sed 's/ //g'`
    disk_queue_scheduler=`cat /sys/block/$disk/queue/scheduler`
fi

echo
echo "${disk}'s disk informations:"
echo "    ${disk}'s queue schedule is '$disk_queue_scheduler'"
model_number=`sudo smartctl -a /dev/${disk} | grep "Model Number:"`
echo "    $model_number"
capacity=`sudo smartctl -a /dev/${disk} | grep "Total NVM Capacity"`
echo "    $capacity"
LBA_size=`sudo smartctl -a /dev/${disk} | grep "Namespace 1 Formatted LBA Size"`
echo "    $LBA_size"
echo

ps_server_process=`ps aux | grep mysqld | grep port`
echo "$ps_server_process"
echo

server_pid=`echo "$ps_server_process" | awk '{print $2}'`
server_Cpus_allowed_list=`cat /proc/$server_pid/status | grep Cpus_allowed_list`
echo "$server_pid's $server_Cpus_allowed_list"
echo

# mysqld 各线程的调度类（RT 测试时用来确认 FIFO 是否真正生效）；脚本不存在则跳过。
# 从原 test/sysbench/localhost_run.sh 并入正本，避免同步时丢掉这一行观测信息。
[ -x "$INSTALL_DIR/show_sched_class.sh" ] && "$INSTALL_DIR/show_sched_class.sh" $server_pid | grep FIFO
echo

# >>> mysql-sysbench-test: iostat-run-monitor (begin) >>>
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

# $1: initial command
function clean_prepare() {
    cmd_cleanup="$1 cleanup"
    $cmd_cleanup >> /dev/null
    if test $? -ne 0; then
        echo "------fail to cleanup------"
        exit
    else
        echo "------cleanup done. Success!------"
    fi

    cmd_prepare="$1 prepare"
    echo "$cmd_prepare"
    $cmd_prepare >> /dev/null
    if test $? -ne 0; then
        echo "------fail to prepare------"
        exit
    else
        echo "------prepare done. Success!------"
    fi
}

prev_item=''
for round in $(seq $rounds);
do
    for item in ${test_items[@]};
    do
        echo "start to run test: ${item}"
        echo

        # 如果前一个测试项是oltp_read_write、oltp_write_only或者oltp_read_only，则下一个测试项不重新生成数据
        generate_data=1
        if [[ "$prev_item" = "oltp_read_write" || "$prev_item" = "oltp_write_only" || "$prev_item" = "oltp_read_only" ]];then
            generate_data=0
        fi

        thd_count=0
        for thd in ${threads[@]};
        do
            if [ -n "$socket" ]; then
                cmd_init="$bin_dir/sysbench $lua_dir/$item.lua --auto-inc=$auto_inc --db-ps-mode=$db_ps_mode --tables=$tables --table_size=$table_size --mysql-socket=$socket --mysql-host=$ip --mysql-port=$port --mysql-user=$user --mysql-password=$passwd --mysql-db=test_db --threads=$thd --time=$run_time --report-interval=$report_interval  --thread-init-timeout=$thread_init_timeout --warmup-time=$warmup_time"
            else
                cmd_init="$bin_dir/sysbench $lua_dir/$item.lua --auto-inc=$auto_inc --db-ps-mode=$db_ps_mode --tables=$tables --table_size=$table_size --mysql-host=$ip --mysql-port=$port --mysql-user=$user --mysql-password=$passwd --mysql-db=test_db --threads=$thd --time=$run_time --report-interval=$report_interval --thread-init-timeout=$thread_init_timeout --warmup-time=$warmup_time"
            fi

            if [ -n "$sysbench_bind_nodes" ]; then
                cmd="numactl -N ${sysbench_bind_nodes[0]} -m ${sysbench_bind_nodes[0]} $cmd_init"
            else
                cmd="$cmd_init"
            fi

            thd_count=$thd_count+1
            # 运行第一个并发压力时，根据上一个测试项是哪个测试项，来判断是否清除上一个测试项的数据，并为当前测试项重新生成数据
            if [[ ($thd_count -eq 1) ]]; then
                if [[ ($force_clean_and_regenerate_data_at_item_test_start -ne 1) && ($generate_data -eq 1) ]]; then
                    clean_prepare "$cmd"
                elif [ ${force_clean_and_regenerate_data_at_item_test_start} -eq 1 ]; then
                    clean_prepare "$cmd"
                fi
            else
                # 如果是一些特殊的测试项如oltp_insert或者oltp_delete，则每次并发测试时均重新造数据
                if [ "${item}" = "oltp_insert" -o "${item}" = "oltp_delete" ]; then
                    clean_prepare "$cmd"
                fi
            fi

            cmd_run="$cmd run"
            echo $cmd_run
            iostat_run_begin "$item" "$thd" "$config_dir"   # <<< mysql-sysbench-test: iostat-run-monitor
            $cmd_run
            iostat_run_end                                  # <<< mysql-sysbench-test: iostat-run-monitor
            echo

            sleep 5
        done

        if (( $enable_binlog_removing == 1 )); then
            ./client
        fi

        sleep 5
        prev_item=$item
    done
done
