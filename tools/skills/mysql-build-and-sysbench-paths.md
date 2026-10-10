# MySQL Build 与 Sysbench 测试：路径梳理文档

本文档梳理 `mysql-build` 与 `mysql-sysbench-test` 两个 skill 中涉及的**数据库源码、安装产物、启动脚本、测试脚本**的存放位置及各自功能。所有路径均已与磁盘实际布局核对；文中以 `$HOME` 指代当前用户主目录，`<REPO>` 取 `mysql` / `txsql` / `polarDb` 之一。

---

## 1. 总体布局

两个 skill 共用一套以 `$HOME/database/<REPO>/` 为根的目录约定，`<REPO>` 取值三种：

| `<REPO>` | 对应数据库 | 编译流程 |
|----------|-----------|---------|
| `mysql` | MySQL 社区版 / in-house 分支 | cmake 预设 |
| `txsql` | TXSQL（腾讯内核分支） | cmake 预设 |
| `polarDb` | PolarDB-X Engine（polardbx-engine） | `build.sh` |

每个 REPO 目录下统一划分三个区：

```
$HOME/database/<REPO>/
├── ingredients/   # 数据库源码（及解压包、构建目录）
├── install/       # 编译安装产物 + 启动脚本 + 配置文件
└── test/
    └── sysbench/  # sysbench 测试脚本与历史日志
```

两个 skill 本体（全部脚本模板的源头）位于**本仓库**的 `tools/skills/` 下，随仓库一起进版本库：

```
<仓库根>/
└── tools/skills/
    ├── mysql-build/
    │   └── SKILL.md                        # MySQL 编译流程说明
    ├── mysql-sysbench-test/
    │   ├── SKILL.md                        # sysbench 测试流程说明
    │   └── scripts/
    │       ├── launch.sh                   # MySQL 启动脚本模板
    │       ├── localhost_run.sh            # sysbench 驱动脚本（正本）
    │       ├── iostat_run_monitor.sh       # run 阶段 iostat(w_await) 采集；驱动的 hook，必须与驱动同目录
    │       ├── stop_user_mysqld.sh         # 关闭已有 mysqld 进程
    │       ├── sysbench_with_monitor.sh    # 带负载监控的 sysbench 包装
    │       ├── hotspot_probe.sh            # 热点摸底（perf 采样 + 归属判定）
    │       ├── sync_localhost_run.sh       # 正本 → 部署副本（驱动 + hook 成对同步）
    │       ├── list_install_versions.sh    # 扫描 install/ 下已构建的版本
    │       └── parse_sysbench_tps.py       # TPS 解析与基准对比
    └── mysql-build-and-sysbench-paths.md   # 本文档
```

> 宿主加载 skill 时经 `<仓库>/.claude/skills/<name>` 软链指向上面这些目录，解析后就是同一份文件，
> **不存在第二个实体**。skill 用到的脚本与模板**全部来自本仓库**，不引用仓库外的安装副本。
>
> 部署时，`launch.sh` 与 `localhost_run.sh`（连同它的 hook `iostat_run_monitor.sh`）会被拷到各 REPO 的
> `install/` 与 `test/sysbench/` 下作为实际执行文件；仓库里的版本是「正本」，**改动只改这一份**。

---

## 2. 数据库源码存放位置

### 2.1 mysql —— `$HOME/database/mysql/ingredients/`

按版本/来源分目录，每个目录即一棵独立源码树，内含各自的 `build/` 构建目录：

| 路径 | 功能 |
|------|------|
| `ingredients/mysql-8.0.25/` | MySQL 8.0.25 源码树，内含 `build/`（cmake 构建目录） |
| `ingredients/mysql-8.0.41/` | MySQL 8.0.41 源码树，内含 `build/` |
| `ingredients/mysql-server/` | git 仓库形式的 mysql-server 源码，含 `build/`、`build-debug/` |
| `ingredients/build/` | 通用构建容器（下挂 `build_autobolt`、`build_hgcc` 等子构建目录） |
| `ingredients/*.tar.gz` | 源码与 boost 压缩包（如 `mysql-boost-8.0.25.tar.gz`、`mysql-boost-8.0.41.tar.gz`） |

cmake 时 boost 路径形如 `-DWITH_BOOST=<workspace>/boost/boost_<版本号>`。

### 2.2 txsql —— `$HOME/database/txsql/TXSQL/`

源码根为 `txsql/TXSQL/`（完整源码树 + 优化补丁），workspace 探测 `REPO=txsql` 的依据：

| 路径 | 功能 |
|------|------|
| `txsql/TXSQL/` | TXSQL 源码根（`CMakeLists.txt`、`sql/`、`storage/`、`*.patch` 优化补丁） |
| `txsql/TXSQL/build/` | cmake 构建目录（`cmake ..` 执行处） |
| `txsql/TXSQL/boost/boost_1_77_0/` | 内置 boost 源码（`-DWITH_BOOST` 指向此） |
| `txsql/TXSQL/build.sh`、`build_compile_optimize.sh` | 编译辅助脚本 |
| `txsql/ingredients/TXSQL/`、`txsql/ingredients/TXSQL-8.0.30-1/` | 备份/打包用源码副本与解压包 |
| `txsql/TXSQL.tar.gz` | 源码打包归档 |

### 2.3 polarDb —— `$HOME/database/polarDb/ingredients/polardbx-engine/`

源码根为 `polardbx-engine/`，`build.sh` 所在目录，编译必须 `cd` 到此执行：

| 路径 | 功能 |
|------|------|
| `polarDb/ingredients/polardbx-engine/` | polardbx-engine 源码根（`sql/`、`storage/`、`include/` 等） |
| `polardbx-engine/build.sh` | polarDb 编译入口（内部已含 `cmake` + `make -j$(nproc) install`） |
| `polardbx-engine/build/`、`build-release/` | 构建目录 |

> 编译并行度差异：mysql/txsql 用固定 `make -j64`；polarDb 走 `build.sh` 内置的 `make -j$(nproc)`，勿强行改并行度。

---

## 3. 数据库安装位置

统一前缀：`$HOME/database/<REPO>/install/`，由 cmake 的 `CMAKE_INSTALL_PREFIX` 或 polarDb 的 `build.sh -d <DEST_DIR>` 决定。按 variant + version + 特性三级组织（历史扁平 base/dev/opt 目录仍保留但不再新增）。

### 3.0 变体 + 版本号两级目录（mysql / txsql / polarDb 通用）

三个仓库统一在原有 `base`/`dev` 之上新增 **变体（variant）** 和 **版本号（version）** 两级：

```
$HOME/database/<REPO>/install/<variant>/<version>/<base|dev/特性名>
```

**变体标识（variant）**：

| variant | 对应场景 | 含义 |
|---------|---------|------|
| `native` | base（工作区相对上游无代码改动） | 原生社区版本，无自研改动 |
| `inhouse` | dev（有新增/修改代码） | 自研版本，含 in-house 特性改动 |

**版本号（version）**：从仓库根目录的版本文件提取 `MAJOR.MINOR.PATCH[EXTRA]`：
- **mysql / txsql**：`MYSQL_VERSION` 文件（字段为 `MYSQL_VERSION_MAJOR`、`MYSQL_VERSION_MINOR`、`MYSQL_VERSION_PATCH`、`MYSQL_VERSION_EXTRA`），如 `8.0.32`、`8.0.30`
- **polarDb**：`include/mysql_version.h.in` 中的 `POLARDBX_PRODUCT_VERSION` 宏定义，或仓库内对应的版本标识文件

**路径示例**：

| REPO | 场景 | 路径 |
|------|------|------|
| mysql | base（无改动，8.0.32） | `install/native/8.0.32/base` |
| mysql | dev（opt-crc32 特性，8.0.32） | `install/inhouse/8.0.32/dev/opt-crc32` |
| txsql | base（无改动，8.0.30） | `install/native/8.0.30/base` |
| txsql | dev（trx-lf-worker 特性，8.0.30） | `install/inhouse/8.0.30/dev/trx-lf-worker` |
| polarDb | base（无改动） | `install/native/<version>/base` |
| polarDb | dev（某特性） | `install/inhouse/<version>/dev/<特性名>` |

### 3.1 历史安装目录

`install/` 顶层另有 `base/`、`dev/`、`opt/`、`8.0.30/`、`versions/`、`in-house-8.0.25/` 等历史目录（早期扁平命名），属旧习惯，不参与 skill 规则。新编译统一走 `native/` / `inhouse/` 变体路径。

单个安装目录内部结构（以任一仓库的 `install/native/<version>/base/` 为例，历史 `install/base/` 结构相同）：

```
install/native/<version>/base/   # 或旧式 install/base/
├── bin/            # mysql、mysqld、mysqladmin 等可执行文件
├── mysqld          # launch.sh 由 support-files/mysql.server 拷贝生成的启停包装脚本
├── support-files/  # mysql.server 等模板
├── lib/、include/、share/、man/、docs/
├── mysql-test/、run/、var/
├── log.err         # launch.sh 写入的错误日志（含初始化临时密码）
└── mysqld.pid      # mysqld 进程 PID 文件（运行时生成）
```

---

## 4. 启动脚本存放位置

### 4.1 skill 自带脚本（正本，仓库内唯一真相）

| 路径 | 功能 |
|------|------|
| `tools/skills/mysql-sysbench-test/scripts/launch.sh` | MySQL 启动脚本正本（首次部署时拷到 `$HOME/database/<REPO>/install/launch.sh`）：清理并初始化数据目录 → 改写 my.cnf → 按需绑核 → `mysqld --initialize` + 后台启动 → 设置 root 密码 `123456` 与 sysbench/benchmarksql 账号 |
| `tools/skills/mysql-sysbench-test/scripts/stop_user_mysqld.sh` | launch 前必跑：关闭当前账户下所有 mysqld/mysqld_safe 进程，避免 socket/端口/数据目录冲突 |
| `tools/skills/mysql-sysbench-test/scripts/sysbench_with_monitor.sh` | 带负载监控的 sysbench 包装（测试前等待 + 运行中监控 + 中断重试） |

### 4.2 部署到仓库后的实际位置

| 路径 | 功能 |
|------|------|
| `$HOME/database/<REPO>/install/launch.sh` | 实际执行的启动脚本：`./launch.sh <ver> y <MYSQL_NUMA>` 初始化并后台拉起 mysqld |
| `$HOME/database/<REPO>/install/my.cnf` | launch.sh 改写的 MySQL 配置文件（`datadir`/`basedir`/`socket`/`log-bin` 等在此生效；sysbench 的 `config_dir` 指向它） |
| `$HOME/database/<REPO>/install/<ver>/mysqld` | launch.sh 生成的启停包装：`<ver>/mysqld start\|stop` |
| `$HOME/database/<REPO>/install/<ver>/log.err` | 启动/初始化错误日志（launch 失败的排查入口） |
| `$HOME/database/<REPO>/install/<ver>/mysqld.pid` | mysqld 进程 PID 文件 |
| `$HOME/database/<REPO>/install/mysql.sock` | 本地 socket（sysbench 通过它连库；`stop_user_mysqld.sh` 遍历 `$HOME/database/*/install/mysql.sock` 优雅关闭） |
| `$HOME/database/<REPO>/install/successive_run_sysbench.sh` | 一键多场景脚本（改配置 → launch → sysbench → 写日志目录）；mysql / txsql 下存在，polarDb 下缺失 |
| `$HOME/database/<REPO>/install/collect_topdown.sh`、`mount_ramfs.sh` | 顶层性能采集、ramfs 挂载辅助脚本（mysql 下存在） |

### 4.3 数据 / 日志存储路径（STORAGE_PATH）

`launch.sh` 顶部的 `data_dir_base_path` / `log_dir_base_path` 决定数据与日志落盘位置（bash 以**最后一次赋值**为准）：

- 默认生效值：launch.sh 中 `data_dir_base_path` / `log_dir_base_path` 的**最后一次非空赋值**（指向某块数据盘 / NVMe 盘上的目录，具体值由 launch.sh 配置决定）
- 其下分目录：`data/`、`binlog/`、`relaylog/`、`slow_query_log/`、`redo/`、`undo/`、`tmp/`
- 用户可指定自定义磁盘路径或 ramfs（`/mnt/ramfs` → `/opt/ramfs` → `/tmp/ramfs-<user>` 依次尝试），由 skill 在 `ver_path=` 行**之前**插入赋值覆盖默认值
- 不指定存储盘时跳过此步，沿用 launch.sh 默认路径
- 文件中靠前的赋值（含注释行）为历史备份，**不得删除**

---

## 5. 测试脚本存放位置

### 5.1 skill 自带脚本（正本，仓库内唯一真相）

| 路径 | 功能 |
|------|------|
| `tools/skills/mysql-sysbench-test/scripts/localhost_run.sh` | sysbench 驱动脚本正本（含全部参数：`bin_dir`/`lua_dir`/`socket`/`threads`/`tables`/`table_size`/`test_items`/`sysbench_bind_nodes` 等）；按脚本所在位置自动探测 `REPO`，同一份可在任一仓库下使用 |
| `tools/skills/mysql-sysbench-test/scripts/iostat_run_monitor.sh` | run 阶段 iostat（`w_await`）采集器 + 驱动的 hook；由 `--install` 把自己写进驱动、由 `--probe`/`--sample` 手工查盘 —— **必须与驱动同目录** |
| `tools/skills/mysql-sysbench-test/scripts/hotspot_probe.sh` | 热点摸底：`perf` 采样 + 自旋/锁归属判定（单函数自占比 >30% 触发暂停） |
| `tools/skills/mysql-sysbench-test/scripts/sync_localhost_run.sh` | 把正本（驱动 + hook 成对）同步到 `$HOME/database/<REPO>/test/sysbench/`；`--check` 只比较 |
| `tools/skills/mysql-sysbench-test/scripts/sysbench_with_monitor.sh` | 包装 `localhost_run.sh`：测试前 30s 间隔扫描负载等待、运行中每 10s 监控、超门限即中止并重试；输出 `perf-monitored-<日期时间>.log` |
| `tools/skills/mysql-sysbench-test/scripts/parse_sysbench_tps.py` | 解析 sysbench 日志中各并发的 TPS，与 baseline 文件对比，输出 Markdown 表（默认 ±3% 判定通过，`--threshold` 可调） |

### 5.2 sysbench 工具本体（外部依赖）

| 路径 | 功能 |
|------|------|
| `$HOME/tools/sysbench-master/install/bin/sysbench` | sysbench 可执行文件（`localhost_run.sh` 的 `bin_dir` 指向） |
| `$HOME/tools/sysbench-master/install/share/sysbench/` | lua 测试脚本目录（`oltp_read_write.lua` 等，`lua_dir` 指向） |

### 5.3 部署到仓库后的实际位置

| 路径 | 功能 |
|------|------|
| `$HOME/database/<REPO>/test/sysbench/localhost_run.sh` | 部署副本：实际执行的 sysbench 测试脚本。参数在**正本**里 `sed` 改，再由 `sync_localhost_run.sh` 推过来；**不要直接改这里** |
| `$HOME/database/<REPO>/test/sysbench/iostat_run_monitor.sh` | 部署副本的 iostat hook（与驱动**成对**同步；驱动按「与自身同目录」定位它，缺了只丢 `w_await` 行，不影响测试） |
| `$HOME/database/<REPO>/test/sysbench/perf-monitored-*.log` | 监控脚本生成的本次测试日志（解析脚本输入） |
| `$HOME/database/<REPO>/test/sysbench/perf-*.log`、`*-perf.txt` | 手动或历史测试日志（可作 baseline 对照） |
| `$HOME/database/<REPO>/test/sysbench/base-*/binlog_order_commits-OFF/1skt-base.txt`、`2skt-base.txt` | 单路 / 双路基准 TPS 日志 |
| `$HOME/database/<REPO>/test/sysbench/opt/...` | opt 构建的历史结果，亦可作对照 |
| `txsql/test/sysbench/bench_*.sh`、`iterate_*.sh` | txsql 仓库自带的历史批跑脚本（非 skill 强制） |

> **核心铁律**：sysbench 的 prepare / run / cleanup 一律通过 `localhost_run.sh` 执行，严禁自行构造 `sysbench ... run` 命令行。改参数用 `sed` 改**正本**（`tools/skills/mysql-sysbench-test/scripts/localhost_run.sh`）中对应变量，再 `sync_localhost_run.sh` 同步到部署副本。

---

## 6. 路径总览表

| 类别 | 路径 | REPO | 功能 |
|------|------|------|------|
| **源码** | `$HOME/database/mysql/ingredients/{mysql-8.0.*,mysql-server}/` | mysql | MySQL 各版本源码树 + 各自 `build/` |
| 源码 | `$HOME/database/mysql/ingredients/<源码树>/MYSQL_VERSION` | mysql | 版本号提取文件（`MAJOR.MINOR.PATCH[EXTRA]`，用于拼装 install 路径中的版本级目录） |
| 源码 | `$HOME/database/txsql/TXSQL/MYSQL_VERSION` | txsql | 版本号提取文件（同上） |
| 源码 | `$HOME/database/txsql/TXSQL/` | txsql | TXSQL 源码根 + `build/` + `boost/` + 补丁 |
| 源码 | `$HOME/database/polarDb/ingredients/polardbx-engine/` | polarDb | polardbx-engine 源码根 + `build.sh` |
| **安装** | `$HOME/database/<REPO>/install/native/<版本号>/base/` | 全部 | 基线版本安装产物（native 变体） |
| 安装 | `$HOME/database/<REPO>/install/inhouse/<版本号>/dev/<特性名>/` | 全部 | 特性/dev 版本安装产物（inhouse 变体） |
| **启动** | `$HOME/database/<REPO>/install/launch.sh` | 全部 | 初始化并启动 mysqld |
| 启动 | `$HOME/database/<REPO>/install/my.cnf` | 全部 | MySQL 配置文件 |
| 启动 | `$HOME/database/<REPO>/install/<ver>/mysqld` | 全部 | 启停包装脚本 |
| 启动 | `$HOME/database/<REPO>/install/<ver>/log.err` | 全部 | 启动/初始化日志 |
| 启动 | `$HOME/database/<REPO>/install/mysql.sock` | 全部 | 本地 socket |
| 启动 | `$HOME/database/<REPO>/install/successive_run_sysbench.sh` | mysql/txsql | 一键多场景脚本 |
| 存储 | launch.sh 中 `data_dir_base_path`/`log_dir_base_path` 配置的默认数据盘目录 | 全部 | data/log 落盘根（可被 ramfs/自定义盘覆盖） |
| **测试** | `$HOME/database/<REPO>/test/sysbench/localhost_run.sh` | 全部 | sysbench 驱动的部署副本（从 skill 正本同步而来，别直接改） |
| 测试 | `$HOME/database/<REPO>/test/sysbench/iostat_run_monitor.sh` | 全部 | 部署副本的 iostat hook（与驱动成对同步） |
| 测试 | `$HOME/database/<REPO>/test/sysbench/perf-monitored-*.log` | 全部 | 本次监控测试日志 |
| 测试 | `$HOME/database/<REPO>/test/sysbench/base-*/.../1skt-base.txt` | 全部 | 基准 TPS 日志 |
| 工具 | `$HOME/tools/sysbench-master/install/{bin,share/sysbench}` | 公共 | sysbench 可执行文件 + lua 脚本 |
| skill | `<仓库根>/tools/skills/mysql-build/SKILL.md` | — | 编译流程说明 |
| skill | `<仓库根>/tools/skills/mysql-sysbench-test/scripts/*` | — | 全部 skill 脚本的正本（唯一真相，改动只改这里） |

---

## 7. 典型流程串联

一次「编译 → 启动 → 测试 → 对比」各步骤用到的路径衔接：

1. **编译**（`mysql-build`）
   - 源码树 `$HOME/database/<REPO>/.../<源码根>/` 下进入 `build/` 跑 `cmake ..` + `make -j64`（polarDb 在源码根跑 `./build.sh -t release -d <DEST>`）
   - 产物安装到 `$HOME/database/<REPO>/install/<variant>/<version>/<base|dev/特性名>/`（variant 为 `native` 或 `inhouse`，version 从版本文件提取）

2. **启动**（`mysql-sysbench-test` 步骤 1）
   - 先 `stop_user_mysqld.sh <REPO>` 清掉已有 mysqld
   - `cd $HOME/database/<REPO>/install && ./launch.sh <ver> y <MYSQL_NUMA>`
   - launch 改写 `install/my.cnf`，初始化 `STORAGE_PATH/data`，后台拉起 `install/<ver>/bin/mysqld`，socket 落在 `install/mysql.sock`

3. **测试**（步骤 2）
   - `sed` 改**正本** `tools/skills/mysql-sysbench-test/scripts/localhost_run.sh` 的 `threads`/`test_items`/`sysbench_bind_nodes`/`tables`/`table_size`，再 `sync_localhost_run.sh` 推到部署副本 `$HOME/database/<REPO>/test/sysbench/`
   - `cd $HOME/database/<REPO>/test/sysbench && sysbench_with_monitor.sh` → 产出 `perf-monitored-*.log`（用 `$HOME/tools/sysbench-master/install/bin/sysbench` + lua）

4. **对比**（步骤 3）
   - `parse_sysbench_tps.py <perf-monitored-*.log> --baseline <base-*/1skt-base.txt> --threshold 3`
   - 输出各测试项 × 并发的当前 TPS / 标准 TPS / 差异 / 判定
