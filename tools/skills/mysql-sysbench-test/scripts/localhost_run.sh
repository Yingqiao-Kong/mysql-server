#!/bin/bash

enable_binlog_removing=1
#sleep 10800

test_items=("oltp_read_write" "oltp_write_only" "oltp_read_only")
threads=(50 200 400)


sysbench_bind_nodes=("4-7")
force_clean_and_regenerate_data_at_item_test_start=0 # 为1时，强制要求每个测试项测试时删除前一个测试项的数据，并重新生成数据

bin_dir="/home/liuwei/tools/sysbench-master/install/bin"
lua_dir="/home/liuwei/tools/sysbench-master/install/share/sysbench"
ip="localhost"
run_time=80
rounds=1
user="root"
passwd="123456"
auto_inc="on"
warmup_time="40"
thread_init_timeout=3000
tables=32
table_size=1000000
# REPO: 当前测试仓库名（mysql / polarDb / txsql）。默认按本脚本所在位置自动探测
# （本脚本位于 $HOME/database/<repo>/test/sysbench/ 下），可用环境变量 REPO=<name> 覆盖。
if [ -z "${REPO:-}" ]; then
  _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../<repo>/test/sysbench
  REPO="$(basename "$(dirname "$(dirname "$_script_dir")")")"   # <repo>
fi
INSTALL_DIR="$HOME/database/$REPO/install"
socket="$INSTALL_DIR/mysql.sock"
port=4306

config_dir="$INSTALL_DIR/my.cnf"
cat $config_dir

echo
cat /proc/version

echo
cat /proc/cmdline

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

ps_server_process=`ps aux | grep mysqld | grep "$socket"`
echo "$ps_server_process"
echo

server_pid=`echo "$ps_server_process" | awk '{print $2}'`
server_Cpus_allowed_list=`cat /proc/$server_pid/status | grep Cpus_allowed_list`
echo "$server_pid's $server_Cpus_allowed_list"
echo

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
            cmd_init="$bin_dir/sysbench $lua_dir/$item.lua --auto-inc=$auto_inc --mysql-user=$user --mysql-password=$passwd --mysql-host=$ip --mysql-port=$port --mysql-db=test_db --tables=$tables --table_size=$table_size --threads=$thd --time=$run_time --report-interval=10 --mysql-socket=$socket --thread-init-timeout=$thread_init_timeout --warmup-time=$warmup_time"
            if [ -n "$sysbench_bind_nodes" ]; then
                #cmd="numactl -N ${sysbench_bind_nodes[0]} -m ${sysbench_bind_nodes[0]} $cmd_init"
		cmd="numactl -N ${sysbench_bind_nodes[0]} -m ${sysbench_bind_nodes[0]} $cmd_init"
		#cmd="numactl -C 0-126,256-382 -m ${sysbench_bind_nodes[0]} $cmd_init"
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
            $cmd_run
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

