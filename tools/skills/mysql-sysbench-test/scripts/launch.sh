#!/bin/bash

#sleep 240

# Description：
#       1、如果本脚本所在的路径存在my.cnf，则以该my.cnf作为mysql的配置文件，其他位置的配置文件将失效。建议采用这种方式运行MySQL，避免权限问题和相互干扰。
#       2、本脚本可以以普通用户身份启动mysql
#       3、将MySQL安装到个人home目录的某个位置，然后将本脚本和my.cnf拷贝到MySQL安装位置的上一级目录，然后执行脚本运行mysql
#          (1)初始化: 执行"./launch.sh <MySQL安装位置> y [node绑核配置，可选，设置后只在指定的node上调度和分配内存；不设置的话则全核运行]", 如执行"./launch.sh mysql-5.7.30/normal y 1-4", 初始化安装在mysql-5.7.30/normal的mysql程序，并绑定在node1-4上调度和分配内存。如果初始化成功，最后会在控制台打印"[Success] xxxxxx initialize successfully"
#          (2)启动mysql服务: 执行"./<MySQL安装位置>/mysqld start"，如执行"./mysql-5.7.30/normal/mysqld start"
#          (3)关闭mysql服务: 执行"./<MySQL安装位置>/mysqld stop"
#       4、可以通过修改"data_dir_base_path"变量的值来指定data的存储位置，修改"log_dir_base_path"变量的值来指定各种log、tmp的存储位置
#

data_dir_base_path="/home/db/mysql-lw"
log_dir_base_path="/home/db/mysql-lw"
data_dir_base_path="/mnt/nvme12/mysql-lw"
log_dir_base_path="/mnt/nvme12/mysql-lw"
#data_dir_base_path=""
#log_dir_base_path=""
ver_path=`readlink -f $1`

$ver_path/mysqld stop

data_dirs=(data)
log_dirs=(binlog relaylog slow_query_log redo undo tmp)
for ((i=0; i < ${#data_dirs[@]}; i++));
do
    if [ -n "$data_dir_base_path" ]; then
        dir=$data_dir_base_path/${data_dirs[$i]}
        rm $data_dir_base_path/${data_dirs[$i]} -r
    else
        dir=$ver_path/${data_dirs[$i]}
        rm $ver_path/${data_dirs[$i]} -r
    fi

    if (($? == 0)); then
        echo "'$dir' is removed."
    fi
done

for ((i=0; i < ${#log_dirs[@]}; i++));
do
    if [ -n "$log_dir_base_path" ]; then
        dir=$log_dir_base_path/${log_dirs[$i]}
        rm $log_dir_base_path/${log_dirs[$i]} -r
    else
        dir=$ver_path/${log_dirs[$i]}
        rm $ver_path/${log_dirs[$i]} -r
    fi

    if (($? == 0)); then
        echo "'$dir' is removed."
    fi
done

if [ $2 == d ]; then
    exit
fi

# $1 is mysqld's file path; $2 is opt; $3 is setting of core binding.
bind_set=false
if [ $# -eq 3 ]; then
  bind_node=$3
  bind_set=true
fi

config_file=`pwd`/my.cnf
default_file=""
if [ -z ${config_file+x} ]; then
  echo "$config_file is not existed. Use /etc/my.cnf? [y/n]"
  read answer
  if ($answer == y); then
    config_file=/etc/my.cnf
  else
    exit 0
  fi
else
  default_file=" --defaults-file=$config_file"
fi

# copy mysqld.server
cp $ver_path/support-files/mysql.server $ver_path/mysqld -f

# Set numactl in mysqld.server
if ($bind_set); then
  boot_cmd="      numactl -N $bind_node -m $bind_node \$bindir\/mysqld_safe$default_file --datadir=\"\$datadir\" --pid-file=\"\$mysqld_pid_file_path\" \$other_args >\/dev\/null \&"
else
  boot_cmd="      \$bindir\/mysqld_safe$default_file --datadir=\"\$datadir\" --pid-file=\"\$mysqld_pid_file_path\" \$other_args >\/dev\/null \&"
fi
echo "$boot_cmd"
sed -i "s#^      \$bindir/mysqld_safe --datadir=.*\&#$boot_cmd#g" $ver_path/mysqld

# Set my_print_default in mysqld.server
if [ -n "$default_file" ]; then
  print_defaults="parse_server_arguments \`\$print_defaults$default_file \$extra_args mysqld server mysql_server mysql.server\`"
  sed -i "s#^parse_server_arguments \`\$print_defaults.*\`#$print_defaults#g" $ver_path/mysqld
fi

# ---------------------------->>> modify my.cnf begin <<<-------------------------------#
data_base_dir=$ver_path
log_base_dir=$ver_path
if [ -n "$data_dir_base_path" ]; then
  data_base_dir=$data_dir_base_path
fi
if [ -n "$log_dir_base_path" ]; then
  log_base_dir=$log_dir_base_path
fi

# datadir
mkdir ${data_base_dir}/data
sed -i "s,^datadir.*=.*,datadir = ${data_base_dir}/data,g" $config_file

# basedir
sed -i "s,^basedir.*=.*,basedir = $ver_path,g" $config_file

# pid-file
sed -i "s,^pid-file.*=.*,pid-file = $ver_path/mysqld.pid,g" $config_file

# log.err
sed -i "s,^log-error.*=.*,log-error = $ver_path/log.err,g" $config_file

# log-bin
if [ -d $log_base_dir/binlog ]; then
  rm $log_base_dir/binlog -rf
fi
mkdir -p $log_base_dir/binlog
sed -i "s,^log-bin.*=.*,log-bin = $log_base_dir/binlog/mysql-bin,g" $config_file
sed -i "s,^log_bin_index.*=.*,log_bin_index = $log_base_dir/binlog/mysql-bin.index,g" $config_file

# sock
sock_path=`pwd`/mysql.sock
sed -i "s,^socket.*=.*,socket = $sock_path,g" $config_file

# relay-log
if [ -d $log_base_dir/relaylog ]; then
  rm $log_base_dir/relaylog -rf
fi
mkdir -p $log_base_dir/relaylog
sed -i "s,^relay-log.*=.*,relay-log = $log_base_dir/relaylog/relay-bin,g" $config_file
sed -i "s,^relay_log_index.*=.*,relay_log_index = $log_base_dir/relaylog/relay-bin.index,g" $config_file
sed -i "s,^relay-log-info-file.*=.*,relay-log-info-file = $log_base_dir/relaylog/relay-log.info,g" $config_file

# slow-query-log
if [ -d $log_base_dir/slow_query_log ]; then
  rm $log_base_dir/slow_query_log -rf
fi
mkdir -p $log_base_dir/slow_query_log
sed -i "s,^slow_query_log_file.*=.*,slow_query_log_file=$log_base_dir/slow_query_log/mysql_slow_query.log,g" $config_file

# innodb_undo_directory
if [ -d $log_base_dir/undo ]; then
  rm $log_base_dir/undo -rf
fi
mkdir -p $log_base_dir/undo
sed -i "s,^innodb_undo_directory.*=.*,innodb_undo_directory = $log_base_dir/undo,g" $config_file

# innodb_log_group_home_dir
if [ -d $log_base_dir/redo ]; then
  rm $log_base_dir/redo -rf
fi
mkdir -p $log_base_dir/redo
sed -i "s,^innodb_log_group_home_dir.*=.*,innodb_log_group_home_dir = $log_base_dir/redo,g" $config_file

# innodb_data_home_dir
sed -i "s,^innodb_data_home_dir.*=.*,innodb_data_home_dir = $data_base_dir/data,g" $config_file

# tmp
if [ -d $log_base_dir/tmp ]; then
  rm $log_base_dir/tmp -rf
fi
mkdir -p $log_base_dir/tmp
sed -i "s,^tmpdir.*=.*,tmpdir = $log_base_dir/tmp,g" $config_file

# ---------------------------->>> modify my.cnf end <<<-------------------------------#

if [ $2 == q ]; then
    exit
fi

# bin
bin_path="$ver_path/bin"
export PATH=$bin_path:$PATH

ps -df | grep mysql

if [ -e $ver_path/log.err ]; then
    rm $ver_path/log.err -f
fi

if ($bind_set); then
  init_cmd="numactl -N $bind_node -m $bind_node $ver_path/bin/mysqld$default_file --initialize --user=mysql --datadir=$data_base_dir/data --basedir=$ver_path"
  numactl -N $bind_node -m $bind_node $ver_path/bin/mysqld$default_file --initialize --user=mysql --datadir=$data_base_dir/data --basedir=$ver_path
else
  init_cmd="$ver_path/bin/mysqld$default_file --initialize --user=mysql --datadir=$data_base_dir/data --basedir=$ver_path"
  $ver_path/bin/mysqld$default_file --initialize --user=mysql --datadir=$data_base_dir/data --basedir=$ver_path
fi

if [ $? == 0 ]; then
    echo "[Success] $init_cmd initialize successfully."

    tmp_passwd=`cat $ver_path/log.err | grep "A temporary password is generated for root@localhost"`
    tmp_passwd=`echo "$tmp_passwd" | awk -F "root@localhost: " '{print $2}'`

    $ver_path/mysqld start

    if [ $? == 0 ]; then
        echo "-------------------------------------------------------------------------------------------------------------"
        echo "mysqld service is started. Some useful commands shown below:"
        echo "$ver_path/bin/mysql -u root --socket=$sock_path -p"
        echo "Temporary password: $tmp_passwd"
        echo
        echo "ALTER USER 'root'@'localhost' IDENTIFIED BY '123456';"
        echo "create database test_db;"
        echo "create user sysbench@192.168.1.2 identified with 'mysql_native_password' by '123456';"
	echo "create user sysbench@192.168.1.2 identified with 'caching_sha2_password' by '123456';"
        echo "GRANT ALL PRIVILEGES ON test_db.* TO 'sysbench'@'192.168.1.2';"
        echo "flush privileges;"

	echo
	echo
        echo "Commands for preparing benchmarkSql testing:"
        echo "create user 'benchmarksql'@'%' identified with mysql_native_password by '1';"
        echo "create database benchmarksql character set utf8mb4;"
        echo "grant all on benchmarksql.* to 'benchmarksql'@'%';"

        echo "-------------------------------------------------------------------------------------------------------------"

        sleep 10
        $ver_path/bin/mysql --connect-expired-password -u root --socket=$sock_path --password="$tmp_passwd" -e"ALTER USER 'root'@'localhost' IDENTIFIED BY '123456';"
	$ver_path/bin/mysql --connect-expired-password -u root --socket=$sock_path --password=123456 -e"create user 'benchmarksql'@'%' identified with mysql_native_password by '1';create database benchmarksql character set utf8mb4;grant all on benchmarksql.* to 'benchmarksql'@'%';"
	$ver_path/bin/mysql --connect-expired-password -u root --socket=$sock_path --password=123456 -e"create database test_db;create user sysbench@'%' identified with 'mysql_native_password' by '123456';GRANT ALL PRIVILEGES ON test_db.* TO 'sysbench'@'%';flush privileges;"
    fi
else
    echo "[Fail] $init_cmd initialize failed!!"
fi

#../test/sysbench/localhost_run.sh
