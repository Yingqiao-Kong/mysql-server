---
name: mysql-sysbench-test
description: Stops any existing user-owned mysqld processes, starts MySQL via launch.sh, runs sysbench with load monitoring, parses TPS per concurrency, and compares against a baseline log. Use when the user asks to launch MySQL for performance testing, run sysbench, check TPS, compare to standard/baseline values, or verify an install build with localhost_run.sh.
---

# MySQL 启动与 Sysbench 性能测试

按下列步骤启动 MySQL、执行 sysbench，并对比 TPS 与标准值。

## 核心铁律：sysbench 命令必须由 localhost_run.sh 驱动

<HARD-GATE>
**严禁**在任何步骤中自行构造 sysbench 命令行（如直接调用 `sysbench ... run`、`sysbench ... prepare`、`sysbench ... cleanup`）。sysbench 的所有操作（prepare、run、cleanup）必须通过 `test/sysbench/localhost_run.sh` 脚本执行，该脚本中已配置完整的参数（`bin_dir`、`lua_dir`、`ip`、`port`、`user`、`passwd`、`socket`、`run_time`、`warmup_time`、`thread_init_timeout`、`tables`、`table_size`、`threads`、`test_items`、`sysbench_bind_nodes` 等）。

修改测试参数时，通过 `sed` 修改 `localhost_run.sh` 中的对应变量（详见步骤 0.4），然后通过以下两种方式之一运行：

1. **推荐**：`~/.claude/skills/mysql-sysbench-test/scripts/sysbench_with_monitor.sh`（带负载监控的包装脚本）
2. **手动**：`./localhost_run.sh 2>&1 | tee <LOG_FILE>`

违反此规则直接构造 sysbench 命令的行为属于错误操作，必须终止并纠正。
</HARD-GATE>

> **参考模板**：`launch.sh` 与 `localhost_run.sh` 的规范版本存于 `~/.claude/skills/mysql-sysbench-test/scripts/launch.sh` 与 `…/scripts/localhost_run.sh`。其中 `localhost_run.sh` 已将仓库相关路径（`socket`、`config_dir`）泛化为按脚本所在位置自动探测 `REPO`（mysql / polarDb / txsql，可用环境变量 `REPO=<name>` 覆盖），同一份可在任一仓库下直接使用。首次在某仓库下部署时，可将这两份模板拷贝到 `$HOME/database/<REPO>/install/launch.sh` 与 `$HOME/database/<REPO>/test/sysbench/localhost_run.sh` 作为初始文件。

## 步骤 0：启动前询问测试参数（必须）

<HARD-GATE>
在调用 `launch.sh`、修改 `localhost_run.sh` 或执行 sysbench **之前**，必须使用 `AskUserQuestion` 向用户确认测试参数（用户已在对话中明确给出的项可不再重复询问）。不得从上下文自行推断后直接开测；用户完成选择后方可继续。
</HARD-GATE>

使用 **两次** `AskUserQuestion` 调用完成参数确认：第一次询问核心测试场景（4 题），第二次询问存储配置（1 题）。未指定时采用默认值，须在 0.6 摘要中标注”默认值”。

### 0.1 第一次询问：核心测试场景参数

调用 `AskUserQuestion`，一次包含以下 4 个问题：

**问题 1 — NUMA 拓扑**（多选，所选拓扑按顺序依次执行）：

- `question`: “请选择 NUMA 拓扑方式（可多选，所选拓扑将按顺序依次执行）？”
- `header`: “NUMA拓扑”
- `multiSelect`: true
- `options`:
  - `{ label: “单路 (默认)”, description: “MySQL 绑 0-3, sysbench 绑 4-7” }`
  - `{ label: “双路”, description: “MySQL 与 sysbench 共用 0-7” }`
  - `{ label: “单node”, description: “MySQL node0, sysbench node1 — numactl -N 0 -m 0” }`
  - `{ label: “四路”, description: “4 socket，MySQL 与 sysbench 均不绑核” }`
  - `{ label: “其他”, description: “自定义 NUMA 绑核（选后请提供 MySQL 与 sysbench 绑核参数）” }`

**问题 2 — 并发 threads**（多选）：

- `question`: “请选择并发组合（可多选，所选组合的线程数将合并去重升序排列）？”
- `header`: “并发threads”
- `multiSelect`: true
- `options`:
  - `{ label: “30+60+100 (默认)”, description: “threads=(30 60 100)” }`
  - `{ label: “50+200+400”, description: “threads=(50 200 400)” }`
  - `{ label: “8+16+32”, description: “threads=(8 16 32)” }`
  - `{ label: “100+200+400”, description: “threads=(100 200 400)” }`

**问题 3 — 表数量×记录数**（单选）：

- `question`: “请选择表数量与每表记录数？”
- `header`: “表×记录”
- `multiSelect`: false
- `options`:
  - `{ label: “32表×100万 (默认)”, description: “tables=32, table_size=1000000” }`
  - `{ label: “64表×100万”, description: “tables=64, table_size=1000000” }`
  - `{ label: “16表×1000万”, description: “tables=16, table_size=10000000” }`
  - `{ label: “10表×1000万”, description: “tables=10, table_size=10000000” }`

**问题 4 — 测试项**（多选）：

- `question`: “请选择 sysbench 测试项（可多选）？”
- `header`: “测试项”
- `multiSelect`: true
- `options`:
  - `{ label: “oltp_read_write”, description: “读写混合 — 最常用” }`
  - `{ label: “oltp_write_only”, description: “纯写” }`
  - `{ label: “oltp_read_only”, description: “纯读” }`
  - `{ label: “oltp_point_select”, description: “点查” }`

### 0.2 第二次询问：存储配置

调用 `AskUserQuestion`，包含 1 个问题：

**问题 5 — 存储盘**（单选）：

- `question`: “请选择测试数据存储方式？”
- `header`: “存储盘”
- `multiSelect`: false
- `options`:
  - `{ label: “默认 (launch.sh 配置)”, description: “使用 launch.sh 现有路径，不做额外修改” }`
  - `{ label: “ramfs 内存盘”, description: “挂载 ramfs 作为存储路径，速度最快” }`
  - `{ label: “自定义路径”, description: “指定其他磁盘路径（选后请提供绝对路径）” }`

### 0.3 选项映射表

用户完成选择后，按以下映射确定实际配置值：

**NUMA 拓扑映射**（多选时按选中顺序依次执行，步骤 1~3 各跑一遍）：

| 用户选择 | `MYSQL_NUMA`（launch.sh 第4参数） | `SYSBENCH_NUMA`（sysbench_bind_nodes） | 说明 |
|---------|-----------------------------------|---------------------------------------|------|
| 单路 (默认) | `0-3` | `(“4-7”)` | |
| 双路 | `0-7` | `(“0-7”)` | |
| 单node | `0` | `(“1”)` | `numactl -N 0 -m 0` |
| 四路 | 不绑核 | `()` | 4 socket，MySQL 与 sysbench 均不绑核 |
| 其他 | 用户自定义 | 用户自定义 | 通过 Other 输入自定义值 |

**并发 threads 映射**：

| 用户选择 | `threads` 值 |
|---------|-------------|
| 30+60+100 (默认) | `(30 60 100)` |
| 50+200+400 | `(50 200 400)` |
| 8+16+32 | `(8 16 32)` |
| 100+200+400 | `(100 200 400)` |

多选时合并所有选中组合的线程数，去重后按升序排列（如同时选”30+60+100”和”50+200+400” → `threads=(30 50 60 100 200 400)`）。用户也可通过 Other 输入自定义线程数（如”128 256”）。

**表数量×记录数映射**：

| 用户选择 | `tables` | `table_size` |
|---------|---------|-------------|
| 32表×100万 (默认) | 32 | 1000000 |
| 64表×100万 | 64 | 1000000 |
| 16表×1000万 | 16 | 10000000 |
| 10表×1000万 | 10 | 10000000 |

**测试项映射**：

| 用户选择 | 写入 `test_items` 的项 |
|---------|---------------------|
| oltp_read_write | `”oltp_read_write”` |
| oltp_write_only | `”oltp_write_only”` |
| oltp_read_only | `”oltp_read_only”` |
| oltp_point_select | `”oltp_point_select”` |

多选时将所有选中项写入 `test_items` 数组（如选 rw + ro → `test_items=(“oltp_read_write” “oltp_read_only”)`）。用户也可通过 Other 指定其他测试项：`oltp_insert`、`oltp_update_index`、`oltp_delete` 等。

**存储盘映射**：

| 用户选择 | 处理方式 |
|---------|---------|
| 默认 (launch.sh 配置) | 不修改 launch.sh 存储路径 |
| ramfs 内存盘 | 挂载 ramfs 并修改 launch.sh（见步骤 1.0） |
| 自定义路径 | 用户通过 Other 给出绝对路径（如 `/mnt/nvme12/mysql-lw`），修改 launch.sh |

### 0.4 用户确认后写入配置

根据用户选择，在继续步骤 1 之前更新 `test/sysbench/localhost_run.sh`：

```bash
cd $HOME/database/<REPO>/test/sysbench

# 示例：选择 单路+双路 + 30+60+100 + oltp_read_write + 32表×100万
# 第一阶段（单路）：
sed -i 's,^test_items=.*,test_items=(“oltp_read_write”),g' localhost_run.sh
sed -i 's,^threads=.*,threads=(30 60 100),g' localhost_run.sh
sed -i 's,^sysbench_bind_nodes=.*,sysbench_bind_nodes=(“4-7”),g' localhost_run.sh
sed -i 's,^tables=.*,tables=32,g' localhost_run.sh
sed -i 's,^table_size=.*,table_size=1000000,g' localhost_run.sh
# launch.sh: ./launch.sh <ver> y 0-3
# 第二阶段（双路）：改 sysbench_bind_nodes 为 ("0-7")，launch.sh 改为 y 0-7
# 若只选单路或双路，仅执行对应阶段；选更多拓扑则依次追加

# 示例：单路 + threads 200 + oltp_read_write + 32表×100万
sed -i 's,^test_items=.*,test_items=(“oltp_read_write”),g' localhost_run.sh
sed -i 's,^threads=.*,threads=(200),g' localhost_run.sh
sed -i 's,^sysbench_bind_nodes=.*,sysbench_bind_nodes=(“4-7”),g' localhost_run.sh
sed -i 's,^tables=.*,tables=32,g' localhost_run.sh
sed -i 's,^table_size=.*,table_size=1000000,g' localhost_run.sh

# 示例：双路 + 预设组合 50+200+400 + rw+wo+ro 多选 + 10表×1000万
sed -i 's,^test_items=.*,test_items=(“oltp_read_write” “oltp_write_only” “oltp_read_only”),g' localhost_run.sh
sed -i 's,^threads=.*,threads=(50 200 400),g' localhost_run.sh
sed -i 's,^sysbench_bind_nodes=.*,sysbench_bind_nodes=(“0-7”),g' localhost_run.sh
sed -i 's,^tables=.*,tables=10,g' localhost_run.sh
sed -i 's,^table_size=.*,table_size=10000000,g' localhost_run.sh
```

### 0.5 确认后输出待测场景摘要（必须）

用户确认参数后、进入步骤 1 **之前**，必须先向用户输出**待测场景摘要**，格式如下（按实际填写，勿省略 IO 设备信息）：

```markdown
## 待测场景确认

| 项 | 值 |
|----|-----|
| REPO | <REPO> |
| 安装版本 | <INSTALL_VER> |
| NUMA 拓扑 | <多选结果，如 单路（默认）、双路、单node、四路；多选时按序依次执行> |
| MySQL 绑核 | <单路 0-3；双路 0-7；单node 0；四路 不绑核；多选时列出各阶段> |
| Sysbench 绑核 | <单路 4-7；双路 0-7；单node 1；四路 不绑核；多选时列出各阶段> |
| 并发 threads | <如 30 60 100（默认）或 50 200 400> |
| 表数量 | <如 32（默认）或 10> |
| 每表记录数 | <如 1000000（默认）或 5000000> |
| 测试项 | <如 oltp_read_write, oltp_write_only, oltp_read_only> |
| 存储路径 STORAGE_PATH | <绝对路径或”launch.sh 默认”> |
| IO 设备类型 | <见下方探测结果> |
| IO 设备详情 | <设备名、文件系统、是否 ramfs/nvme/hdd 等> |
| 对比基准 BASELINE_LOG | <路径或”无”> |

**IO 设备探测**（确认摘要前执行，将结果填入上表）：

```bash
REPO=<REPO>
LAUNCH_SH="$HOME/database/${REPO}/install/launch.sh"

# 1) 确定生效的 STORAGE_PATH：用户指定 / ramfs 挂载路径；否则从 launch.sh 取 ver_path= 前最后一组 data_dir_base_path
STORAGE_PATH="<已确定路径，或从 launch.sh 解析>"

# 2) 探测 IO 类型
df -hT "$STORAGE_PATH" 2>/dev/null
findmnt -T "$STORAGE_PATH" -o SOURCE,FSTYPE,TARGET 2>/dev/null
lsblk -o NAME,TYPE,SIZE,MODEL,TRAN,MOUNTPOINT 2>/dev/null | head -20
```

**IO 类型判定参考**：

| 条件 | 报告为 |
|------|--------|
| `findmnt` 的 FSTYPE 为 `ramfs`，或路径在 `/mnt/ramfs`、`/opt/ramfs`、`/tmp/ramfs-*` | 内存盘 ramfs |
| 块设备 TRAN 为 `nvme` 或设备名含 `nvme` | NVMe SSD |
| TRAN 为 `sata`/`sas` 或 Rotational=1 | HDD / SATA SSD |
| 路径在 `/dev/shm` 等 | tmpfs / 内存文件系统 |
| 无法探测 | 写明路径 + `df` 输出，标注“未能识别设备类型” |

多选 NUMA 拓扑时，摘要中列出**各阶段**各自 NUMA/绑核；IO 设备所有阶段共用同一 `STORAGE_PATH`（探测一次即可）。

摘要输出并获用户认可后，再进入步骤 1。

若用户同时指定了对比基准，所选参数须与 `BASELINE_LOG` 中的 `test_items`、`threads`、`tables`、`table_size`、NUMA 拓扑一致；不一致时先提示用户，确认是否仍继续。

## 前置：确定路径与参数

在步骤 0 之外，向用户确认（或从上下文推断）：

| 参数 | 说明 | 示例 |
|------|------|------|
| `REPO` | 当前 workspace 对应目录名 | workspace 在 `.../txsql/TXSQL` → `txsql`；在 `.../mysql/...` → `mysql` |
| `INSTALL_VER` | 待验证版本的**安装目录**（相对 `install/`） | `base`、`opt/trx-lf-worker` |
| `MYSQL_NUMA` | MySQL 绑核（`launch.sh` 第 4 参数） | 单路 `0-3`；双路 `0-7`；单node `0`；四路 不绑核；多选时按序依次执行 |
| `BASELINE_LOG` | 标准 TPS 日志文件路径 | `test/sysbench/base-.../1skt-base.txt` |
| `SYSBENCH_NUMA` | sysbench 绑核（写入 `localhost_run.sh`） | 单路 `("4-7")`；双路 `("0-7")`；单node `("1")`；四路 `()` 不绑核；多选时按序依次执行 |
| `THREADS` | 并发列表 | 默认 `(30 60 100)`；或 `(50 200 400)` 等 |
| `TABLES` | sysbench 表数量 | 默认 `32`；或 `10`、`64`、`16` 等 |
| `TABLE_SIZE` | 每张表记录数 | 默认 `1000000`；或 `5000000`、`10000000` 等 |
| `TEST_ITEMS` | 测试项列表（由步骤 0 选择写入 `localhost_run.sh`） | `("oltp_read_write")` |
| `STORAGE_PATH` | MySQL data/log 根路径（用户指定磁盘或 ramfs 时） | `/mnt/nvme12/mysql-lw`、`/mnt/ramfs` |

根路径：

- 安装与启动：`$HOME/database/<REPO>/install`
- Sysbench：`$HOME/database/<REPO>/test/sysbench`

**警告**：`launch.sh ... y` 会删除并重新初始化数据目录，属于破坏性操作；执行前确认无生产数据。

## 步骤 1：启动 MySQL

### 1.0 配置 launch.sh 存储路径（用户指定磁盘或 ramfs 时）

`install/launch.sh` 中 `data_dir_base_path`、`log_dir_base_path` 可能被多次赋值；**bash 以最后一次赋值为准**。文件中靠前的赋值（含注释行）是**历史备份**，**不得删除**。

用户指定路径时，在 `ver_path=` **之前**追加两行，使其成为生效的最后一组赋值：

```bash
REPO=<REPO>
LAUNCH_SH="$HOME/database/${REPO}/install/launch.sh"
STORAGE_PATH="<用户提供的绝对路径>"

sed -i "s|^ver_path=|data_dir_base_path=\"${STORAGE_PATH}\"\nlog_dir_base_path=\"${STORAGE_PATH}\"\nver_path=|" "$LAUNCH_SH"
```

用户选择 **ramfs** 时，先创建挂载点，再将得到的 `STORAGE_PATH` 写入 `launch.sh`：

```bash
TTY_USER=$(logname 2>/dev/null || whoami)

mount_ramfs() {
  local mp="$1"
  sudo mkdir -p "$mp" || return 1
  sudo mount -t ramfs ramfs "$mp" 2>/dev/null || return 1
  sudo chown -R "${TTY_USER}:${TTY_USER}" "$mp" || return 1
  echo "$mp"
}

if STORAGE_PATH=$(mount_ramfs /mnt/ramfs); then
  :
elif STORAGE_PATH=$(mount_ramfs /opt/ramfs); then
  :
elif STORAGE_PATH=$(mount_ramfs "/tmp/ramfs-${TTY_USER}"); then
  :
else
  echo "ramfs 挂载失败：/mnt/ramfs、/opt/ramfs、/tmp/ramfs-${TTY_USER} 均不可用" >&2
  exit 1
fi

sed -i "s|^ver_path=|data_dir_base_path=\"${STORAGE_PATH}\"\nlog_dir_base_path=\"${STORAGE_PATH}\"\nver_path=|" "$LAUNCH_SH"
```

说明：

- `TTY_USER` 为登录当前 TTY 的用户名（优先 `logname`，失败则 `whoami`）。
- ramfs 优先 `/mnt/ramfs`；若 `mkdir`/`mount`/`chown` 失败，依次尝试 `/opt/ramfs`、`/tmp/ramfs-<用户>`。
- 若目标目录已挂载且可写，可复用；`mount` 报错时再试下一候选路径。
- 用户未指定存储盘且选择 `default` 时，跳过本节，直接执行 1.1。
- 修改完成后向用户复述最终 `STORAGE_PATH`，再执行 `./launch.sh`。

### 1.0.5 关闭本账户已有 MySQL 进程（必须）

<HARD-GATE>
在执行 `./launch.sh` **之前**，必须先确认当前 Linux 账户下是否已有 mysqld / mysqld_safe 进程；若有，须先全部关闭，再启动指定版本。不得跳过此步骤直接 launch。
</HARD-GATE>

使用本 skill 附带脚本（推荐）：

```bash
~/.claude/skills/mysql-sysbench-test/scripts/stop_user_mysqld.sh <REPO>
```

`REPO` 为当前测试仓库名（如 `txsql`、`mysql`、`polarDb`），用于优先尝试该仓库 `install/mysql.sock` 的优雅关闭；脚本会扫描**当前账户下所有** mysqld 相关进程（不限于单个 REPO）。

关闭顺序：

1. `mysqladmin shutdown`（遍历 `$HOME/database/*/install/mysql.sock`）
2. 从运行中进程解析 `--basedir`，执行 `<basedir>/mysqld stop`
3. 等待最多 30 秒进程退出
4. 仍有残留则 `pkill` 强制终止（仅作用于当前账户 `-u $(whoami)`）

手动检查（脚本失败时辅助排查）：

```bash
CURRENT_USER=$(whoami)
pgrep -u "$CURRENT_USER" -af 'mysqld_safe|bin/mysqld '
```

脚本输出「无运行中的 MySQL 进程」或「MySQL 进程已正常退出 / 已通过强制终止关闭」后，方可进入 1.1。若关闭失败（脚本 exit 1），不得继续 launch，先排查残留进程与端口占用。

### 1.1 执行 launch.sh

使用步骤 0 用户选择的 NUMA 拓扑：

```bash
cd $HOME/database/<REPO>/install
./launch.sh <待验证的版本安装路径> y <步骤0选定的 MYSQL_NUMA>
```

示例（txsql、opt 构建、选中单路+双路 — 第一阶段单路）：

```bash
cd $HOME/database/txsql/install
./launch.sh opt/trx-lf-worker y 0-3
```

示例（双路）：

```bash
./launch.sh opt/trx-lf-worker y 0-7
```

**调用要点**：`launch.sh` 是同步脚本，它返回（exit）即代表初始化与 mysqld 后台启动已经完成。**不要再用任何额外的 `sleep`、`wait` 或后台轮询去等待**，脚本退出后立即进入步骤 2。直接用前台 `Bash` 工具调用即可，**`timeout` 参数设为 `60000`（1 分钟）**，无须 `run_in_background`，也无须读 `mysqld.pid`。如果 1 分钟仍未返回，说明 launch 出错（多半是 my.cnf 配置项不识别或端口占用），到 `install/<ver>/log.err` 排查，不要继续盲等。

成功标志：控制台出现 `[Success] ... initialize successfully`，且 mysqld 已 start。

若需与历史基准对齐 NUMA 拓扑，可参考 `install/successive_run_sysbench.sh`：

- 单路：`launch.sh <ver> y 0-3`，sysbench `("4-7")`
- 双路：`launch.sh <ver> y 0-7`，sysbench `("0-7")`
- 单node：`launch.sh <ver> y 0`，sysbench `("1")`
- 四路：`launch.sh <ver> y`（不传第4参数，不绑核），sysbench `()` 不绑核
- 多选时按选中顺序依次执行各阶段

## 步骤 2：运行 Sysbench（带负载监控）

### 2.1 负载监控机制

为避免其他高负载进程影响测试结果的准确性，测试过程全程进行负载监控：

1. **测试前检查**：启动 sysbench 前以 **30 秒** 间隔扫描系统负载，若存在高于门限的负载则持续等待，直到扫描到无高负载时才开始测试
2. **运行中监控**：测试运行期间每 **10 秒** 检测一次系统负载，若发现超出门限的其它负载，**立即停止当前测试**，并回到测试开始前的状态重新执行测试脚本
3. **判定标准**（满足任一即判定为高负载干扰）：
   - **CPU 占用聚集**：所有 CPU 使用率 > 50% 的非 MySQL、非 sysbench 进程的 `pcpu` 之和除以 100，结果 > 3
   - **同名进程聚集**：系统中存在超过 5 个 CPU 利用率 > 50% 且名称相同的非 MySQL、非 sysbench 进程（表示有大量相同类型的高负载后台任务在执行）

### 2.2 运行前检查配置

步骤 0 应已写入 `threads`、`test_items`、`sysbench_bind_nodes`。启动前再核对：

- `socket` 指向 `$HOME/database/<REPO>/install/mysql.sock`
- `config_dir` 指向对应 `my.cnf`
- `threads`、`test_items`、`sysbench_bind_nodes` 与步骤 0 用户选择一致
- 若要做基准对比，`run_time`、`warmup_time` 等与 `BASELINE_LOG` 一致（否则对比无意义）

### 2.3 使用监控脚本执行测试（推荐）

使用带负载监控的包装脚本执行测试，该脚本会自动完成：
- 测试前以 30 秒间隔扫描负载，高于门限则等待，直到无高负载才开始测试
- 测试运行中每 10 秒负载监控
- 检测到超出门限的其它负载时立即停止测试
- 等待负载降低后回到测试开始前的状态，重新执行测试脚本

```bash
cd $HOME/database/<REPO>/test/sysbench
~/.claude/skills/mysql-sysbench-test/scripts/sysbench_with_monitor.sh
```

日志文件自动命名为 `perf-monitored-<日期时间>.log`。

### 2.4 手动执行测试（不推荐）

如不使用监控脚本，可手动执行，但需自行确保测试期间无其他高负载干扰：

```bash
cd $HOME/database/<REPO>/test/sysbench
LOG="perf-$(date +%Y-%m-%d-%H-%M).log"
./localhost_run.sh 2>&1 | tee "$LOG"
```

测试耗时较长（默认 `run_time=80`，多并发 × 多测试项），勿提前中断。

## 步骤 3：查看 TPS 并与标准值对比

### 3.1 从日志提取各并发 TPS

每条 sysbench `run` 结束后，在 `SQL statistics` 中有：

```text
transactions: 2078555 (17317.22 per sec.)
```

括号内为 **TPS**（transactions/s）。按 `测试项.lua` + `--threads=N` 与基准对齐。

### 3.2 自动对比（推荐）

使用本 skill 附带脚本：

```bash
python3 ~/.claude/skills/mysql-sysbench-test/scripts/parse_sysbench_tps.py \
  "$HOME/database/<REPO>/test/sysbench/<LOG>" \
  --baseline "$HOME/database/<REPO>/test/sysbench/<BASELINE_LOG>" \
  --threshold 3
```

向用户汇报脚本输出的 Markdown 表：**当前 TPS、标准 TPS、差异百分比、判定**（默认 ±3% 为通过，可用 `--threshold` 调整）。

### 3.3 标准值文件选取

`test/sysbench/` 下历史日志可作为标准，例如：

- `base-*/binlog_order_commits-OFF/1skt-base.txt`（单路基准）
- `base-*/binlog_order_commits-OFF/2skt-base.txt`（双路基准）
- `opt/*/**-perf.txt`（某次 opt 构建结果，也可作对照）

**必须与本次测试使用相同的**：`test_items`、`threads`、`tables`、`table_size`、`run_time`、`warmup_time`、NUMA 拓扑、`my.cnf` 关键项（如 `binlog_order_commits`）。不一致时先说明再对比。

### 3.4 汇报格式

向用户总结：

1. 安装版本、`MYSQL_NUMA`、`STORAGE_PATH`（若指定）、日志路径
2. 各 `test_item` × `threads` 的当前 TPS 列表
3. 与标准值的对比表及整体结论（通过项数 / 回退项 / 提升项）
4. 若明显低于标准，提示检查：mysqld 是否绑核正确、磁盘、是否误用旧 socket、launch 是否成功
5. 若测试被负载监控中断过，需说明中断次数和原因

## 与 `successive_run_sysbench.sh` 的关系

`install/successive_run_sysbench.sh` 已封装「改配置 → launch → localhost_run → 写日志目录」。需要一键多场景时可直接改编该脚本；本 skill 的三步流程与之等价，且步骤 3 的解析脚本适用于其生成的 `*-perf.txt`。

## 故障排查

| 现象 | 处理 |
|------|------|
| 端口/socket 被占用 | 先执行 `stop_user_mysqld.sh <REPO>`；`pgrep -u $(whoami) -af mysqld` 确认无残留 |
| launch 失败 | 查看 `install/<ver>/log.err`；核对 `STORAGE_PATH` 可写、ramfs 是否挂载成功 |
| ramfs 挂载失败 | 检查 sudo 权限；依次尝试 `/mnt/ramfs`、`/opt/ramfs`、`/tmp/ramfs-<用户>` |
| sysbench 连不上 | 核对 `socket`、`passwd`、root 密码是否为 `123456`（launch 默认设置） |
| 解析不到 TPS | 确认日志含 `...lua ... run` 与 `transactions: ... per sec.` |
| 对比全缺标准 | 检查 baseline 路径与测试参数是否与基准一致 |
| 测试被监控中止 | 查看告警中的高负载进程列表，等待其结束后重试 |

## 完整示例（txsql + opt 构建 + 选中单路+双路）

```bash
REPO=txsql
VER=opt/trx-lf-worker
BASELINE_1SKT=$HOME/database/txsql/test/sysbench/base-2026-05-06-16-55/binlog_order_commits-OFF/1skt-base.txt
BASELINE_2SKT=$HOME/database/txsql/test/sysbench/base-2026-05-06-16-55/binlog_order_commits-OFF/2skt-base.txt

# 第一阶段：单路
~/.claude/skills/mysql-sysbench-test/scripts/stop_user_mysqld.sh $REPO
cd $HOME/database/$REPO/install
./launch.sh $VER y 0-3
cd $HOME/database/$REPO/test/sysbench
# 确保 sysbench_bind_nodes=("4-7")
~/.claude/skills/mysql-sysbench-test/scripts/sysbench_with_monitor.sh
python3 ~/.claude/skills/mysql-sysbench-test/scripts/parse_sysbench_tps.py \
  perf-monitored-*.log --baseline "$BASELINE_1SKT" --threshold 3

# 第二阶段：双路
~/.claude/skills/mysql-sysbench-test/scripts/stop_user_mysqld.sh $REPO
cd $HOME/database/$REPO/install
./launch.sh $VER y 0-7
cd $HOME/database/$REPO/test/sysbench
# 确保 sysbench_bind_nodes=("0-7")
~/.claude/skills/mysql-sysbench-test/scripts/sysbench_with_monitor.sh
python3 ~/.claude/skills/mysql-sysbench-test/scripts/parse_sysbench_tps.py \
  perf-monitored-*.log --baseline "$BASELINE_2SKT" --threshold 3
```
