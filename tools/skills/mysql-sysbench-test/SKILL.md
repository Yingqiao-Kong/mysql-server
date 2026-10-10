---
name: mysql-sysbench-test
description: Stops any existing user-owned mysqld processes, starts MySQL via launch.sh, runs sysbench with load monitoring, parses TPS per concurrency, and compares against a baseline log. Use when the user asks to launch MySQL for performance testing, run sysbench, check TPS, compare to standard/baseline values, or verify an install build with localhost_run.sh.
---

# MySQL 启动与 Sysbench 性能测试

按下列步骤启动 MySQL、执行 sysbench，并对比 TPS 与标准值。

> **`$SKILL_DIR`**：本 skill 在仓库内目录的**绝对路径**，即 `<仓库根>/tools/skills/mysql-sysbench-test`
> （例：仓库在 `/home/you/db/mysql-server`，则 `$SKILL_DIR=/home/you/db/mysql-server/tools/skills/mysql-sysbench-test`）。
> 宿主从 `<仓库>/.claude/skills/mysql-sysbench-test` 加载本 skill 时，那条软链解析后就是同一个目录。
> **本 skill 用到的脚本与模板全部来自本仓库**（`$SKILL_DIR/scripts/`），不引用任何仓库外的安装副本；
> 下文所有 `$SKILL_DIR/scripts/…` 都可直接照抄执行。

## 核心铁律：sysbench 命令必须由驱动「正本」localhost_run.sh 驱动

<HARD-GATE>
**严禁**在任何步骤中自行构造 sysbench 命令行（如直接调用 `sysbench ... run`、`sysbench ... prepare`、`sysbench ... cleanup`）。sysbench 的所有操作（prepare、run、cleanup）必须通过驱动**正本** `$SKILL_DIR/scripts/localhost_run.sh` 执行，该脚本中已配置完整的参数（`bin_dir`、`lua_dir`、`REPO`、`ip`、`port`、`user`、`passwd`、`socket`、`run_time`、`warmup_time`、`thread_init_timeout`、`tables`、`table_size`、`threads`、`test_items`、`sysbench_bind_nodes` 等）。

修改测试参数时，用 `sed` 改**正本**里的对应变量（详见步骤 0.4），然后通过以下两种方式之一运行：

1. **推荐**：`$SKILL_DIR/scripts/sysbench_with_monitor.sh`（带负载监控的包装脚本）
2. **手动**：`$SKILL_DIR/scripts/localhost_run.sh 2>&1 | tee <LOG_FILE>`

两种方式都会**先把正本同步到部署副本**（见下），因此正本始终是唯一真相。违反此规则直接构造 sysbench 命令的行为属于错误操作，必须终止并纠正。
</HARD-GATE>

> **本仓库是唯一真相：正本 / 部署副本（重要）**
>
> * **正本**：本仓库内 `$SKILL_DIR/scripts/` 下的文件（`localhost_run.sh`、`iostat_run_monitor.sh`、
>   `sync_localhost_run.sh`、`hotspot_probe.sh`、`sysbench_with_monitor.sh` …）。它们随 skill 一起进
>   版本库，**代码与文档改动只改这里**。宿主加载本 skill 时经 `<仓库>/.claude/skills/mysql-sysbench-test`
>   软链读到的**就是这一份** —— 没有第二个实体，**不需要 `cp` 同步**。
> * **每轮测试参数**（步骤 0.4 的 `sed`）直接改正本里的变量。参数逐轮变化，改完想还原就
>   `git checkout -- $SKILL_DIR/scripts/localhost_run.sh`（它是 tracked 文件，脏了是正常的）。
> * **部署副本**：`$HOME/database/<REPO>/test/sysbench/`，是 `localhost_run.sh` **与其 iostat hook
>   `iostat_run_monitor.sh` 成对**的一份拷贝。它**不在任何 git 仓库里**，还有别的工具与手工命令会直接
>   改它、跑它（如 `install/successive_run_sysbench.sh`）。驱动按「与自身同目录」定位 hook，所以两份
>   必须一起同步；缺了 hook 只是不再输出 `w_await` 行（静默退化为空操作，不影响测试本身）。
> * **同步**：每次运行（`sysbench_with_monitor.sh` / `hotspot_probe.sh`）都会自动把正本同步过去；也可手工执行：
>
>   ```bash
>   $SKILL_DIR/scripts/sync_localhost_run.sh           # 正本 → 部署副本（幂等；覆盖前自动备份 .bak-<日期时间>）
>   $SKILL_DIR/scripts/sync_localhost_run.sh --check   # 只比较：一致 exit 0；不一致 exit 1 并打印 diff
>   ```
>
> * 因此**不要直接改 `test/sysbench/` 下那两份**：那儿的改动会在下一次同步时被正本覆盖（覆盖前有
>   `.bak-<日期时间>` 兜底）。
> * 正本用 `REPO`（默认 `mysql`，可用环境变量 `REPO=<name>` 覆盖为 polarDb / txsql）拼出 `$HOME/database/$REPO/install/{my.cnf,mysql.sock}`。
> * `launch.sh` 的规范版本存于 `$SKILL_DIR/scripts/launch.sh`；首次在某仓库下部署时把它拷到 `$HOME/database/<REPO>/install/launch.sh`。

## 步骤 0：启动前询问测试参数（必须）

<HARD-GATE>
在调用 `launch.sh`、修改 `localhost_run.sh` 或执行 sysbench **之前**，必须使用 `AskUserQuestion` 向用户确认测试参数（用户已在对话中明确给出的项可不再重复询问）。不得从上下文自行推断后直接开测；用户完成选择后方可继续。
</HARD-GATE>

参数确认用 **若干轮** `AskUserQuestion` 完成，**各轮紧挨着发**（轮次数量不设上限，见下「提问编排规则」）：

- **第一轮（4 题，全部是 sysbench 侧参数）**：NUMA 拓扑、并发 threads、表数量×记录数、测试项 —— 每个参数各占一题、逐项勾选，**不用「一整套预设」打包**。
- **第二轮（3 题，运行与存储）**：测试版本、通信方式、存储盘。
- **第三轮及以后**：**仅当已有轮次装不下继续新增的询问项时才开**（第二轮还空着一个位置，所以第一顺位是并进第二轮；编排细则与模板见 0.6）。

**「上一轮问完立马发下一轮」是硬要求**：上一轮的答案一返回，**立即**发起下一轮，中间不得插入任何其他动作（不读文件、不扫描、不写配置、不 launch）。因此**所有后续轮次所需的全部前置信息必须在第一轮之前就准备好** —— 例如测试版本的候选要**提前**用 `list_install_versions.sh` 扫出来缓存着（见 0.2），这样上一轮一回来就能直接发下一轮。**任何需要现场扫描/读文件才能组出选项的题目都不能排进后续轮次**（要么把扫描提前缓存，要么把这题并进一个已经备好选项的轮次）。

**为什么通信方式排在第二轮**：`AskUserQuestion` 单次调用**上限 4 题**（工具硬约束，没有开关），而 sysbench 侧一共 5 个维度（拓扑/并发/表规模/测试项/通信）。取舍是：最核心的 4 个占第一轮，**通信方式退到第二轮**（它语义上也属于「怎么跑这份测试」）。若更希望通信进第一轮，把「表数量×记录数」与它换位即可，其余不变。后续再冒出新的维度时，**不回头打散这两轮的分组**，而是按 0.6 顺次加轮。

**没有对应询问项**的参数采用默认值，须在 0.5 摘要中标注「默认值」。注意区别：这里说的是「本来就没设这一题」；**因为轮次排不下而把某一题省掉**是违规的 —— 那种情况要按下面的编排规则加轮，而不是默默取默认值。

**提问编排规则（以后新增参数照此办理）**：

- **轮次数量不设上限**：受约束的只有「每轮 ≤ 4 题、每题 ≤ 4 选项」（`AskUserQuestion` 的工具硬约束）。两轮装得下就用两轮；**装不下就顺次增加第三轮、第四轮……**，直到每个询问项都有位置。既**不允许**为凑轮次把两个不相干的参数硬塞进同一题，也**不允许**因为「轮次已满」就把参数默默按默认值处理。
- **sysbench 侧**参数（跑什么、跑多大、绑哪些核、怎么连 —— 如 `run_time`/`warmup_time`/`auto_inc`/`db_ps_mode`/`report_interval` 等）**优先放第一轮**：能独立成题的独立成题；第一轮 4 题满了，就**并进同类题的选项**或退到后续轮次；**优先「并进同类题」把轮次压紧，实在压不下才加新一轮**。
- **非 sysbench 侧**参数（测试版本、存储盘）放第二轮。
- 新增的询问项按**与已有题目的语义亲疏**落位：同类（同一维度、同类可选项）就并进该题 `options`，否则**追加到最后一个轮次之后**（文档上就是插在 0.2 与 0.3 之间，编号与写法见 0.6）；整体顺序保持「sysbench 侧 → 运行与存储 → 其他」。
- **加一轮就要同步改多处**：开新轮次时必须同步更新本节的轮次列举、0.1/0.2 的标题与过渡句、0.6 的模板、0.3 的映射表、0.4 的 `sed` 段、0.5 摘要表 —— 别让正文里还写着「只有两轮」。
- 每轮各自**不得超过 4 题**、每题选项**不得超过 4 个**（都是工具上限）。

**测试版本的例外**：若本次会话中前面已经用 `mysql-build` 构建过 MySQL 版本，则**不再询问测试版本**，直接采用该次构建产物的安装路径作为 `INSTALL_VER`；若用户已在对话中指明用哪个版本（或直接给了安装目录），同样不再询问。二者都要在 0.5 摘要的「安装版本」一项注明来源（如“mysql-build 本次构建”），而不是默默填上。

### 0.1 第一轮：sysbench 侧参数（4 题，逐项勾选）

一次 `AskUserQuestion` 调用里放下面 4 题，**每个参数各占一题**。选项值直接取 0.3 的映射表；选 Other 时按 0.3 的自由写法解析。**解析结果必须在 0.5 摘要里回显出来**（供核对与留痕），不得静默采用。

**问题 1 — NUMA 拓扑**（多选；勾中的拓扑按顺序依次执行，即多阶段）：

- `question`: “请选择 NUMA 拓扑（可多选，勾中的按顺序依次执行）？”
- `header`: “NUMA拓扑”
- `multiSelect`: true
- `options`:
  - `{ label: “单路 (默认)”, description: “MySQL 绑 0-3 / sysbench 绑 4-7” }`
  - `{ label: “双路”, description: “MySQL 与 sysbench 共用 0-7” }`
  - `{ label: “单node”, description: “MySQL node0、sysbench node1 —— numactl -N 0 -m 0” }`
  - `{ label: “四路”, description: “4 socket，MySQL 与 sysbench 均不绑核” }`

**问题 2 — 并发 threads**（多选；多组会合并去重、升序执行）：

- `question`: “请选择并发组合（可多选，勾中的合并去重后升序执行）？”
- `header`: “并发threads”
- `multiSelect`: true
- `options`:
  - `{ label: “64+128+256+512 (默认)”, description: “threads=(64 128 256 512)” }`
  - `{ label: “50+200+400”, description: “threads=(50 200 400)” }`
  - `{ label: “100+200+400”, description: “threads=(100 200 400)” }`
  - `{ label: “8+16+32”, description: “threads=(8 16 32)” }`

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
  - `{ label: “oltp_read_write”, description: “读写混合 —— 最常用” }`
  - `{ label: “oltp_write_only”, description: “纯写” }`
  - `{ label: “oltp_read_only”, description: “纯读” }`
  - `{ label: “oltp_point_select”, description: “点查” }`

**Other 的自由写法**：拓扑写 `四路不绑核`/自定义核段；并发可直接写裸数字（`128 256`）；表规模写 `10表×1000万`；测试项还可写 `oltp_insert`、`oltp_update_index`、`oltp_delete` 等。逐项映射见 0.3。

### 0.2 第二轮：测试版本 / 通信方式 / 存储盘（3 题，紧跟第一轮立即发出）

第一轮的答案一返回，**立刻**发出这一轮 —— 中间不得插入任何其他动作（不读文件、不扫描、不写配置、不 launch）。所以**问题 5 需要的扫描结果要在发出第一轮之前就先跑好并缓存**，否则第一轮回来后为了取选项还得先跑脚本，「立马」就断了。**这条对后面每一轮都同样成立**（第三轮及以后怎么加见 0.6）。

**问题 5 — 测试版本**（单选；选项**必须**来自扫描的实际输出，不得凭记忆或上下文写死）：

**在发出第一轮之前**先扫描本仓库下**已经构建好、拿来就能跑**的 MySQL 版本（判定标准：存在 `bin/mysqld`）：

```bash
REPO=<REPO>   # mysql / polarDb / txsql
$SKILL_DIR/scripts/list_install_versions.sh "$REPO" --limit 4
# 需要看全量（含更老的构建）时：list_install_versions.sh "$REPO" --paths
```

- 脚本输出**按构建时间（`bin/mysqld` 的 mtime）降序**，最新构建在最上面；默认 TSV：`<构建时间>\t<相对 install/ 的路径>\t<mysqld 版本串>`。
- `AskUserQuestion` 每题最多 4 个选项 ⇒ **只把最新的 4 个放进 options**（标 `(最新)`），更老的构建在 `question` 文本里附一段 `--md` 全量表，并提示用户可选 Other 手填相对路径。
- 选项写法：`label` 用末级目录名 + 版本号（如 `opt-realtime (8.0.25)`，可读性最好）；`description` 写全量信息 `相对路径 + 构建时间 + mysqld 版本串`，让用户能一眼确认是哪个构建。
- 用户选 Other 时接受相对 `install/` 的路径或绝对路径（`launch.sh` 内部 `readlink -f`，两者都认）。

```jsonc
// 示例（选项来自上面扫描的实际输出）
{
  "question": "请选择本次测试的 MySQL 版本（按构建时间倒序；如需更老的构建，请选 Other 并填相对 install/ 的路径）？",
  "header": "测试版本",
  "multiSelect": false,
  "options": [
    { "label": "opt-realtime (最新, 8.0.25)", "description": "inhouse/8.0.25/dev/opt-realtime ｜ 构建于 2026-10-08 20:55 ｜ mysqld 8.0.25" },
    { "label": "base-0928 (8.0.25)",          "description": "inhouse/8.0.25/base-0928 ｜ 构建于 2026-09-29 02:13 ｜ mysqld 8.0.25" },
    { "label": "group-commit-parallel-flush (8.0.32)", "description": "inhouse/8.0.32/dev/group-commit-parallel-flush ｜ 构建于 2026-07-23 21:32 ｜ mysqld 8.0.32" },
    { "label": "group-commit-lock (8.0.32)",  "description": "inhouse/8.0.32/dev/group-commit-lock ｜ 构建于 2026-07-22 21:36 ｜ mysqld 8.0.32" }
  ]
}
```

**扫描失败怎么办**：`list_install_versions.sh` 扫不到任何构建时 **exit 1**（`install/` 不存在、或一个含 `bin/mysqld` 的目录都没有）。这时**停下来**，不要硬凑一个版本去问：先用 `mysql-build` 把目标版本编译出来（产物落在 `install/<native|inhouse>/<版本号>/<base|dev/特性名>`），或核对 `REPO` 是否选错，然后重新扫描。

**跳过提问的两种情况**（见步骤 0 开头的例外）：本次会话前面已用 `mysql-build` 构建过 ⇒ 直接用那次构建的安装路径；用户已指明版本 ⇒ 用用户给的。两种情况都**跳过本题**（第二轮因此只剩 2 题，空出的位置按「提问编排规则」优先让给待新增的询问项），但要在 0.5 摘要里写明来源。

**问题 6 — 通信方式**（单选）：

- `question`: “MySQL 与 sysbench 之间采用何种通信方式？”
- `header`: “通信方式”
- `multiSelect`: false
- `options`:
  - `{ label: “unix socket (默认)”, description: “走 --mysql-socket，本机测试开销最小、最贴近服务端内部路径” }`
  - `{ label: “tcp/ip”, description: “走 --mysql-host/--mysql-port（127.0.0.1:4306），可跨机、便于配合抓包” }`

> 为什么排在第二轮（不跟另外 4 个 sysbench 维度同批）：见步骤 0 开头的说明。想让通信进第一轮，就把「表数量×记录数」与它换位。

**问题 7 — 存储盘**（单选）：

- `question`: “请选择测试数据存储方式？”
- `header`: “存储盘”
- `multiSelect`: false
- `options`:
  - `{ label: “默认 (launch.sh 配置)”, description: “使用 launch.sh 现有路径，不做额外修改” }`
  - `{ label: “ramfs 内存盘”, description: “挂载 ramfs 作为存储路径，速度最快” }`
  - `{ label: “自定义路径”, description: “指定其他磁盘路径（选后请提供绝对路径）” }`

### 0.3 选项映射表

用户完成选择后，按以下映射确定实际配置值。

**第一轮四题 → 四个维度**：问题 1（NUMA 拓扑）→ `MYSQL_NUMA` + `sysbench_bind_nodes`；问题 2（并发）→ `threads`；问题 3（表×记录）→ `tables` + `table_size`；问题 4（测试项）→ `test_items`。对应四张映射表见下 —— 它们既是**各题选项的来源**，也是**解析 Other 的依据**。

**多阶段**：问题 1 勾了多个拓扑（如「单路」+「双路」）时，按**勾选顺序**依次执行各阶段；每阶段开始前重新 sed 正本、同步部署副本，并用该阶段的 `MYSQL_NUMA` 重新 `launch.sh`。

**通信方式两行**（由问题 6 决定；`socket` 与 `ip` **必须配套**，写进正本 `localhost_run.sh`）：

| 通信 | `socket` | `ip` | 实际生效 |
|------|----------|------|---------|
| unix socket | `"$INSTALL_DIR/mysql.sock"`（`INSTALL_DIR=$HOME/database/$REPO/install`） | `"localhost"` | 走 `--mysql-socket` |
| tcp/ip | `""`（置空） | `"127.0.0.1"` | 走 `--mysql-host/--mysql-port` |

> 原理（2026-10-10 读 sysbench 源码 + 探针在 sysbench 实际加载的 8.0.44 客户端库上实测；sysbench 自己不设 protocol，把 host/port/socket 交给 `mysql_real_connect`）——**分两层看，别混**：
>
> - **sysbench 层（决定性的一层）**：`src/drivers/mysql/drv_mysql.c:483-516` 里，只要 `--mysql-socket` **非空**，sysbench 就**丢弃 `--mysql-host`**、把 host 硬编码成 `"localhost"`；于是 libmysqlclient 必然走 unix socket。**所以「给了 socket 就一定是 socket 通信」，即使同时写了 `--mysql-host=127.0.0.1`/`--mysql-port` 也不影响**（那两行被无视）。传空串与不传等价（`sb_options.c:139` ⇒ 列表为空）。
> - **libmysqlclient 层**（只在 socket 为空时才轮到它做决定）：host 为空 / 未给 / 恰为 `"localhost"` 才用 socket；host 是 IP 时走 TCP，且 TCP 连不上也不回退 socket（实测）。**反过来说：socket 置空而 ip 仍是 `"localhost"` 时，客户端会去连编译进库的默认 socket `/var/lib/mysql/mysql.sock`，不会自动转 TCP（实测报 2002）**。
> - 因此约定：**socket 非空 ⇒ ip 写 `localhost`**（此时 ip 实际不参与决策，写对只是为了日志自解释）；**socket 置空 ⇒ ip 必须 `127.0.0.1`**（否则连的是默认 socket，而不是你以为的 TCP）。

**各维度参考值**（既是第一轮各题选项的来源，也是解析它们 Other 的依据）：

**NUMA 拓扑参考值**（写多个拓扑 ⇒ 按书写顺序依次执行多阶段）：

| 写法 | `MYSQL_NUMA`（launch.sh 第4参数） | `sysbench_bind_nodes` | 说明 |
|---------|-----------------------------------|---------------------------------------|------|
| 单路 (默认) | `0-3` | `("4-7")` | |
| 双路 | `0-7` | `("0-7")` | |
| 单node | `0` | `("1")` | `numactl -N 0 -m 0` |
| 四路 | 不绑核 | `()` | 4 socket，MySQL 与 sysbench 均不绑核 |

**并发 threads 参考值**：

| 写法 | `threads` 值 |
|---------|-------------|
| 64+128+256+512 (默认) | `(64 128 256 512)` |
| 50+200+400 | `(50 200 400)` |
| 8+16+32 | `(8 16 32)` |
| 100+200+400 | `(100 200 400)` |

Other 里写了多组时，合并所有组的线程数，去重后按升序排列（如”64+128+256+512”与”50+200+400”同写 → `threads=(50 64 128 200 256 400 512)`）；也可直接写裸数字（如”128 256”）。

**表数量×记录数参考值**：

| 写法 | `tables` | `table_size` |
|---------|---------|-------------|
| 32表×100万 (默认) | 32 | 1000000 |
| 64表×100万 | 64 | 1000000 |
| 16表×1000万 | 16 | 10000000 |
| 10表×1000万 | 10 | 10000000 |

**测试项参考值**：

| 写法 | 写入 `test_items` 的项 |
|---------|---------------------|
| rw / oltp_read_write | `"oltp_read_write"` |
| wo / oltp_write_only | `"oltp_write_only"` |
| ro / oltp_read_only | `"oltp_read_only"` |
| ps / oltp_point_select | `"oltp_point_select"` |

Other 里写了多项就全部写进 `test_items` 数组（如 rw + ro → `test_items=("oltp_read_write" "oltp_read_only")`）；还可用 `oltp_insert`、`oltp_update_index`、`oltp_delete` 等。

**测试版本映射**（→ `INSTALL_VER`，即 `launch.sh` 的第 1 个参数）：

| 用户选择 | `INSTALL_VER` |
|---------|---------------|
| 列表中的某个构建 | 该选项 `description` 里的相对路径，原样照抄（如 `inhouse/8.0.32/dev/group-commit-lock`） |
| Other 填的相对路径 | 原样使用（如 `base-0928`、`dev/crc32-simd` 这类更浅的布局也是合法值） |
| Other 填的绝对路径 | 原样使用（`launch.sh` 内部 `readlink -f`，绝对路径同样吃下） |
| （跳过提问）mysql-build 本次构建 | 该次构建产物的安装路径，相对 `install/`（如 `inhouse/8.0.32/dev/func-cost-profile`） |

> **易错点**：`INSTALL_VER` 是**安装目录**，不是版本号。写 `8.0.32` 会让 `launch.sh` 在 `install/8.0.32` 找不到东西（真实目录是 `install/inhouse/8.0.32/...`）。拿不准就先 `list_install_versions.sh <REPO> --paths` 复核一遍。

**存储盘映射**：

| 用户选择 | 处理方式 |
|---------|---------|
| 默认 (launch.sh 配置) | 不修改 launch.sh 存储路径 |
| ramfs 内存盘 | 挂载 ramfs 并修改 launch.sh（见步骤 1.0） |
| 自定义路径 | 用户通过 Other 给出绝对路径（如 `/mnt/nvme12/mysql-lw`），修改 launch.sh |

### 0.4 用户确认后写入配置

按各轮询问的结果（Other 则按 0.3 各表解析出的值），在继续步骤 1 之前用 `sed` 更新驱动**正本**，再同步到部署副本：

```bash
cd $SKILL_DIR/scripts     # 正本所在目录（本仓库内、唯一真相；下面的 sed 改的就是这一份）
REPO=<REPO>                                        # mysql / polarDb / txsql

# 1) 通信方式（每轮必写；socket 与 ip 必须配套，别让两行自相矛盾）
#    由问题 6 决定，A / B 二选一执行（不要同时执行）：
#    A. unix socket：
sed -i -E "s|^socket=.*|socket=\"\$HOME/database/$REPO/install/mysql.sock\"  # 非空 ⇒ sysbench 一定走 socket（并丢弃 ip）；置空才走 TCP/IP|" localhost_run.sh
sed -i -E 's|^ip=.*|ip="localhost"                    # 仅 socket 为空时才生效；那时必须写 IP，写 localhost 会去连默认 socket|' localhost_run.sh
#    B. tcp/ip：
sed -i -E 's|^socket=.*|socket=""  # 置空 ⇒ 才轮到 ip/port 决定通道（--mysql-host/--mysql-port）|' localhost_run.sh
sed -i -E 's|^ip=.*|ip="127.0.0.1"                     # 必须写 IP：写 localhost 会去连默认 socket(/var/lib/mysql/mysql.sock)|' localhost_run.sh

# 2) sysbench 侧参数：按第一轮 4 题的答案逐条 sed（多阶段时每阶段都要重写一遍）
#    写法要点：只替换「值」，行尾注释（含它与值之间的空格）原样接回 —— 不要用 `s,^var=.*,…`
#    那种整行替换，它会把 `threads=(…)  # 默认并发压力；…` 的行尾说明一并吃掉。
#    模式 `^var=([^#]*[^# ])?( *#.*)?$`：组 1 强制以非空格收尾，剩下的空格连同注释留给组 2，
#    由替换串末尾的 \2 接回，对齐也不丢；行首带 # 的备选行（`#threads=(10 40 70 100)`）不匹配 ^var=，不受影响。
#    局限：它只能**保留**已有注释，不能凭空补回 —— 若某行注释已被老写法吃过，先
#    `git checkout -- localhost_run.sh` 拿回带注释的正本，再按下面改参数。
sed -i -E 's|^test_items=([^#]*[^# ])?( *#.*)?$|test_items=("oltp_read_write" "oltp_write_only" "oltp_read_only")\2|g' localhost_run.sh
sed -i -E 's|^threads=([^#]*[^# ])?( *#.*)?$|threads=(64 128 256 512)\2|g' localhost_run.sh
sed -i -E 's|^sysbench_bind_nodes=([^#]*[^# ])?( *#.*)?$|sysbench_bind_nodes=("4-7")\2|g' localhost_run.sh
sed -i -E 's|^tables=([^#]*[^# ])?( *#.*)?$|tables=32\2|g' localhost_run.sh
sed -i -E 's|^table_size=([^#]*[^# ])?( *#.*)?$|table_size=1000000\2|g' localhost_run.sh
# launch.sh: ./launch.sh <INSTALL_VER> y <该阶段的 MYSQL_NUMA>

# 上面 5 条 sed 的取值来源（Other 则按 0.3 的四张表解析）：
#   问题 1 NUMA 拓扑 → sysbench_bind_nodes：单路 ("4-7") / 双路 ("0-7") / 单node ("1") / 四路 ()（不绑核）
#                      同一题决定 launch.sh 第 4 参数 MYSQL_NUMA：0-3 / 0-7 / 0 / 不传
#                      勾了多个 ⇒ 多阶段：每阶段重做这 5 条 sed 并重新 launch.sh
#   问题 2 并发      → threads=(64 128 256 512)（多选时合并去重、升序）
#   问题 3 表×记录   → tables=32  table_size=1000000
#   问题 4 测试项    → test_items=("oltp_read_write" "oltp_write_only" "oltp_read_only")
#   问题 6 通信      → 上面 1) 的 A / B
#   没被问到的项（run_time / warmup_time / auto_inc / db_ps_mode / report_interval …）保持正本默认值

# 写完后同步到部署副本（正本 → test/sysbench；幂等，覆盖前自动备份）
$SKILL_DIR/scripts/sync_localhost_run.sh
$SKILL_DIR/scripts/sync_localhost_run.sh --check   # 期望 exit 0
```

### 0.5 参数确认后输出待测场景摘要（必须；仅作展示，不再二次询问）

用户确认参数后、进入步骤 1 **之前**，必须先向用户输出**待测场景摘要**，格式如下（按实际填写，勿省略 IO 设备信息）：

```markdown
## 待测场景确认

| 项 | 值 |
|----|-----|
| REPO | <REPO> |
| 安装版本 | <INSTALL_VER>（问题 5 所选 / Other 所填；跳过提问时注明来源，如“mysql-build 本次构建”） |
| 阶段数 | <问题 1 只勾 1 个拓扑 = 1；勾了 2 个 = 2，并说明执行顺序> |
| NUMA 拓扑 | <如 单路（默认）/ 双路 / 单node / 四路；多阶段时列出各阶段> |
| MySQL 绑核 | <单路 0-3；双路 0-7；单node 0；四路 不绑核；多阶段时列出各阶段> |
| Sysbench 绑核 | <单路 4-7；双路 0-7；单node 1；四路 不绑核；多阶段时列出各阶段> |
| 并发 threads | <如 64 128 256 512（默认）或 50 200 400> |
| 表数量 | <如 32（默认）或 10> |
| 每表记录数 | <如 1000000（默认）或 5000000> |
| 测试项 | <如 oltp_read_write, oltp_write_only, oltp_read_only> |
| 通信方式 | <unix socket / tcp/ip（问题 6 所选）> |
| 存储路径 STORAGE_PATH | <绝对路径或”launch.sh 默认”> |
| IO 设备类型 | <见下方探测结果> |
| IO 设备详情 | <设备名、文件系统、是否 ramfs/nvme/hdd 等> |
| 对比基准 BASELINE_LOG | <路径或”无”> |
```

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

**摘要仅作展示与留痕，不是一道确认关**：参数已在步骤 0 的各轮 `AskUserQuestion` 里确认过，
所以摘要输出后**直接进入步骤 1**，不得再问「要不要继续跑」，也不得再用一次 `AskUserQuestion`
去讨认可。写完摘要即继续，别停在半路等人回话。

摘要中提到的 `test_items` 就是步骤 1.5 热点摸底的对象，摸底按 128 并发对它们逐个摸底。

若用户同时指定了对比基准，所选参数须与 `BASELINE_LOG` 中的 `test_items`、`threads`、`tables`、`table_size`、NUMA 拓扑一致；不一致时**先提示用户并等回话**（这是 0.5 唯一的例外：发现的是一致性冲突，不是重复讨要参数认可），用户确认后照其意见继续。

### 0.6 新增询问轮次的操作模板（第三轮及以后）

**什么时候才需要加轮**：先看第二轮 —— 它现在只有 3 题，**还空着一个位置**，所以新增的询问项**第一顺位是并进第二轮**（或并进第一轮里同类题的 `options`）。**只有已有轮次全都满了，才开第三轮**；此后每轮都按下面这套模板办。

1. **定题目与落位**：按「提问编排规则」判断该项归哪一类 —— 同类就并进已有题目的 `options`（这是首选，能不加轮就不加轮），实在并不下才单开一题。
2. **把新轮次插在 0.2 与 0.3 之间**，标题写成 `### 0.2.<k> 第 N 轮：<主题>（<题数> 题，紧跟上一轮立即发出）`（如第三轮 → `### 0.2.1 第三轮：…`，第四轮 → `### 0.2.2 第四轮：…`；编号连续，**不要**去动 0.3 / 0.4 / 0.5 的号）。题面格式与 0.1 / 0.2 完全一致：每题给出 `question` / `header` / `multiSelect` / `options`（≤ 4 个）。
3. **在 0.3 补一张对应的映射表**（选项 → 实际写入 `localhost_run.sh` 的值，多选/Other/多阶段都要写清怎么解析）—— 0.3 是解析选项与 Other 的**唯一**依据，缺了它这一步就没法落配置。
4. **选项所需的前置信息提前缓存**：该轮任何要靠扫描/读文件才能组出的 `options`，都必须在**发出第一轮之前**跑好并缓存（见步骤 0 开头的硬要求）；轮次与轮次之间同样**不许**插入扫描动作。纯靠枚举/固定候选的题目不受此限。
5. **回填后续步骤**：新轮次的答案要一起进 0.5 摘要表（每个新参数占一行，来源标「第 N 轮」或「默认值」），0.4 的 `sed` 段补上对应写入命令，需要 `launch.sh` 配合的还要在步骤 1 里补参数说明。
6. **只改仓库正本**：SKILL.md 与脚本都在本仓库 `$SKILL_DIR/` 下，宿主加载的就是这一份 —— **没有第二份实体、不需要 `cp`**（见文首「正本 / 部署副本」）。改动提交进版本库即可，下次运行自然生效。

> **加轮的边界**：轮次多不等于题目碎。**先合并、后加轮** —— 能并进同类题选项的一律并进去，只有「语义上与已有题目都不搭、又确实需要问用户」的项才占新的一轮。

## 前置：确定路径与参数

在步骤 0 之外，向用户确认（或从上下文推断）：

| 参数 | 说明 | 示例 |
|------|------|------|
| `REPO` | 当前 workspace 对应目录名 | workspace 在 `.../txsql/TXSQL` → `txsql`；在 `.../mysql/...` → `mysql` |
| `INSTALL_VER` | 待验证版本的**安装目录**（相对 `install/`）。由步骤 0 问题 5 选定（选项来自 `list_install_versions.sh <REPO>` 的扫描结果），或用 mysql-build 本次构建的产物 | `inhouse/8.0.32/dev/group-commit-lock`、`base` |
| `MYSQL_NUMA` | MySQL 绑核（`launch.sh` 第 4 参数），来自步骤 0 问题 1 | 单路 `0-3`；双路 `0-7`；单node `0`；四路 不绑核；多阶段按序依次执行 |
| `BASELINE_LOG` | 标准 TPS 日志文件路径 | `test/sysbench/base-.../1skt-base.txt` |
| `SYSBENCH_NUMA` | sysbench 绑核（写入 `localhost_run.sh`），来自步骤 0 问题 1 | 单路 `("4-7")`；双路 `("0-7")`；单node `("1")`；四路 `()` 不绑核；多阶段按序依次执行 |
| `THREADS` | 并发列表 | 默认 `(64 128 256 512)`；或 `(50 200 400)` 等 |
| `TABLES` | sysbench 表数量 | 默认 `32`；或 `10`、`64`、`16` 等 |
| `TABLE_SIZE` | 每张表记录数 | 默认 `1000000`；或 `5000000`、`10000000` 等 |
| `TEST_ITEMS` | 测试项列表（由步骤 0 问题 4 写入正本 `localhost_run.sh`） | `("oltp_read_write")` |
| `COMM_MODE` | MySQL 与 sysbench 的通信方式（由步骤 0 问题 6 写入正本） | unix socket（走 `--mysql-socket`）；tcp/ip（`--mysql-host=127.0.0.1`） |
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
$SKILL_DIR/scripts/stop_user_mysqld.sh <REPO>
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
./launch.sh <INSTALL_VER> y <步骤0选定的 MYSQL_NUMA>
```

`<INSTALL_VER>` 就是步骤 0 问题 5 选定的**安装目录**（相对 `install/`）或其绝对路径 —— 别写成版本号。

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

- 单路：`launch.sh <INSTALL_VER> y 0-3`，sysbench `("4-7")`
- 双路：`launch.sh <INSTALL_VER> y 0-7`，sysbench `("0-7")`
- 单node：`launch.sh <INSTALL_VER> y 0`，sysbench `("1")`
- 四路：`launch.sh <INSTALL_VER> y`（不传第4参数，不绑核），sysbench `()` 不绑核
- 多阶段（问题 1 勾了多个拓扑，如「单路」+「双路」）按此顺序依次执行各阶段

## 步骤 1.5：性能测试前的热点摸底（必须）

在跑正式性能测试**之前**，必须先用高并发把本次要测的每个测试项各压一小段，同时用 `perf`
采样 mysqld 的**全部线程**，确认这个场景在高并发下不存在异常热点——非常明显的锁竞争、
或者某个函数占比畸高。为什么必须先做：**结果本身病态时，正式测试再准也没意义**；
高并发下的排队/自旋会把 TPS 压到与配置无关的水平，直接测出来的数字解释不了任何问题。
摸底只花几分钟。

<HARD-GATE>
进入步骤 2 之前必须完成热点摸底（调用本 skill 自带的 `hotspot_probe.sh`）。

- 摸底退出码 **2（PAUSE）** ——存在单个函数**自身占比 > 30%** ——**必须暂停测试**：
  不得启动 `sysbench_with_monitor.sh` / `localhost_run.sh`，先把热点（函数名、占比、
  所属测试项、时间窗）报告给用户，等用户给出处置意见后再继续。
- 摸底退出码 **1（WARN）** ——须把日志中说明的热点在正式测试日志/最终汇报里写清楚，
  然后才可以继续。
- 退出码 **0（OK）** ——正常进入步骤 2。
</HARD-GATE>

### 1.5.1 执行摸底

```bash
cd $HOME/database/<REPO>/test/sysbench    # 只影响报告目录（--out 默认 ./hotspot-probe-<时间戳>）
$SKILL_DIR/scripts/hotspot_probe.sh --threads 128 --warmup 30 --time 30
```

脚本做这几件事：

1. 读驱动**正本** `localhost_run.sh` 里**生效的** `test_items`（多行候选时取最后一行），把它们全部作为摸底对象
2. 把正本复制成工作副本 `--out/localhost_run.sh.probe`，用 `sed` 只改**这份副本**：`rounds=1`、`threads=(128)`、
   `run_time/ warmup_time` 缩短；**`tables`、`table_size`、`sysbench_bind_nodes`、`socket` 等一律不动**，
   保证摸底数据集与正式测试一致。**正本与部署副本 `test/sysbench/` 全程只读**
3. 起 `perf record -p <mysqld_pid>`（覆盖 mysqld 全部线程；mysqld 带 `cap_sys_nice=ep`，
   是 non-dumpable 进程，**必须免密 sudo**）
4. 跑这份工作副本（sysbench 依旧只由 `localhost_run.sh` 驱动），并给每行输出打上单调时钟戳。
   摸底期间 hook 的 iostat 采集被显式关掉（`IOSTAT_RUN_MONITOR=0`），摸底日志里不会出现
   `run期间iostat - ...` 行；**正式测试（步骤 2）才有**
5. 用 `perf report --time` 把采样按"测试项 run 窗口"切开，逐项统计自身（self）占前 15 的函数，
   以及自旋 / 等待 / 锁 三类阻塞函数的合计占比。
   **窗口只取 run 阶段、不含 warmup**：起点由第一条 `[ Ns ]` 中间报告行反推（`该行时间戳 - N`），
   终点取 `execution time` 后 1s，所以窗口宽度 ≈ run 时长 + 1s。预热段的爬坡（线程刚起、
   buffer pool/AHI 还在建）不进热点画像。推算方式记在 `windows.tsv` 第 6 列，退回锚点时会告警。
6. 退出时（含 Ctrl-C）清理工作副本；正本与部署副本从未被改写，因此**不存在「改坏驱动」的风险**（`--keep-lr` 则保留副本供排查）

常用参数：

| 参数 | 默认 | 说明 |
|------|------|------|
| `--threads` | `128` | 摸底并发数。高并发才容易暴露锁竞争；128 是默认摸底档 |
| `--time` | `30` | 每个测试项的 `run` 时长（秒），也是归因窗口的宽度 |
| `--warmup` | `30` | 每个测试项的预热时长（秒）。预热段不计入归因窗口 |
| `--freq` | `499` | perf 采样频率（Hz，按线程计） |
| `--callgraph` | `none` | 设成 `dwarf` 会额外抓调用图，但显著变慢、`perf.data` 会涨到数 GB |
| `--items` | 取正本 `localhost_run.sh` | 只摸底其中几项，例如 `--items "oltp_read_write"` |
| `--out` | `./hotspot-probe-<时间戳>` | 输出目录 |

### 1.5.2 判定阈值

| 现象 | 判定 | 处置 |
|------|------|------|
| 某函数**自身占比 > 30%** | **PAUSE**（退出码 2） | **暂停测试**，先向用户报告 |
| 某函数自身占比 15% ~ 30% | WARN（退出码 1） | 在日志中说明清楚后继续 |
| 自旋 + 等待 + 锁 合计 > 40% | WARN（退出码 1） | 在日志中说明清楚后继续 |
| 窗口内样本 < 5000 / 无法按测试项切分 | WARN（退出码 1） | 说明清楚该测试项的摸底结论不可靠 |

注意：阻塞类**合计**占比偏高只告警、不暂停——本机在 512 并发下 `ut_delay` + `os_event::wait`
合计 60%+ 属正常现象（自旋/睡眠本来就该占大头）。**只有单个函数自身占比超过 30% 才暂停。**

### 1.5.3 输出与判读

输出都在 `--out` 目录（默认 `test/sysbench/hotspot-probe-<时间戳>/`）：

| 文件 | 内容 |
|------|------|
| `hotspot-probe-<时间戳>.log` | 人读报告：汇总表、每项 Top15 函数（含类别与态）、判读与下一步命令 |
| `hotspot-summary.tsv` | 机器可读汇总（`item / verdict / samples / top1_sym / top1_pct / spin_pct / wait_pct / lock_pct / block_pct / kernel_pct / tps / p95`） |
| `sysbench-ts.log` | 带单调时钟戳的原始输出（时间窗来源，便于核对切分是否正确） |
| `windows.tsv` | 切出来的时间窗：`item / start / end / tps / p95 / 起点来源`。第 6 列是 `run` 说明起点由中间报告行反推（正常）；出现其它值说明退回了兜底推算，该窗口可能含预热段 |
| `sysbench-raw.log` | 不带时间戳的原始输出（可直接喂给 `parse_sysbench_tps.py`） |
| `perf.data` | perf 采样数据 |
| `perf-report-<item>.txt` | 每个测试项的 perf report 明细（可直接翻函数 + 占比） |

判读要点：

- **看 Top1**：`ut_delay` 独占热点通常意味着自旋预算过大（
  `innodb_sync_spin_loops × (delay-1)/2 × innodb_spin_wait_pause_multiplier` 这个乘积太大）；
  `rw_lock_*` / `lock_rec_*` / `trx_sys*` 靠前说明锁串行化；`log_*` / 刷脏函数靠前说明写路径是瓶颈。
- **看 TPS**：汇总表里的 TPS 是摸底档（128 并发、短时长）的值，只用来判断"热点是否伴随吞吐塌陷"，
  **不要**当性能结论。
- **看内核态占比**：内核态占比异常高（如 `entry_SYSCALL_64`、`vfs_write` 靠前）说明系统调用/IO 路径重。
  注意其中一部分是 **perf 自己**（`perf_event_*`、`x86_pmu_*`、采样中断里的 `_raw_spin_lock`），
  通常合计几个百分点；若明显偏高（>10%），说明 `--freq` 对当前并发偏高，可降到 199 再摸一次。
- **热点集中在一个函数上时要定位到指令**：报告末尾给了配方 —— 先用
  `perf script -F ip,sym | awk '{print $1}' | sort | uniq -c | sort -rn | head` 拿最热的 IP，
  再 `addr2line -e <mysqld 二进制> -f -C -i 0x<IP>` 落到源码行。经验上"某个函数独占 20%+"往往是
  **函数里的一条 load 指令**在指针追逐/等缓存行（`cycles` 采样会把停顿记在 load 的下一条指令上），
  而不是这个函数"算得多"。这一步决定了该 hotspot 是配置问题还是代码问题，写日志时要说清。
- 需要继续深挖时，报告末尾会给出可直接复制的命令，例如
  `sudo perf report -i perf.data --stdio --time <start>,<end> --sort overhead,pid`。
  **排序键必须用 `overhead`**：`--sort symbol` 是按函数名字典序排的，表格第一行只是名字最靠前的函数，
  不是最热的那个（脚本内部的 Top1 提取已经改用 `--sort overhead`）。

### 1.5.4 注意事项

- **必须免密 sudo**：`perf` 采样 non-dumpable 的 mysqld 需要 root。没有免密 sudo 时脚本直接报错退出（退出码 3），
  不要改用 `perf record -- sysbench ...`（那样采到的是 sysbench 客户端，不是 mysqld）。
- **摸底只造一次数据**：脚本把 `force_clean_and_regenerate_data_at_item_test_start` 置 0，
  第一项 `prepare` 之后其余 `oltp_*` 项复用同一份数据。摸底结束后这份数据仍留在 `test_db`，
  正式测试会按自己的流程重新 cleanup + prepare，互不影响。
- **驱动不会被改坏**：摸底跑的是 `--out/localhost_run.sh.probe` 工作副本，正本与部署副本全程只读；
  脚本退出（含 Ctrl-C、报错）时清理副本，`--keep-lr` 则保留副本，`--out/localhost_run.sh.orig` 是本次所用正本的快照。
- **摸底用的并发/时长只影响摸底本身**，不会留在正本里影响正式测试。
- mysqld 未运行、找不到 `perf`、没有免密 sudo → 退出码 3，先解决环境问题。

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

- 通信方式与问题 6 的选择一致（两行必须配套）：unix socket ⇒ `socket` 指向 `$HOME/database/<REPO>/install/mysql.sock` 且 `ip="localhost"`；
  tcp/ip ⇒ `socket=""`（**这一项才是决定性的**）且 `ip="127.0.0.1"`。
  判别口令：`socket` 非空 ⇒ 必走 socket（`ip` 不参与决策）；`socket` 空 + `ip` 是 IP ⇒ 必走 TCP
- `REPO` 与当前仓库一致（正本用 `REPO` 拼 `config_dir`/`socket`；默认 `mysql`，可 `export REPO=<name>` 覆盖）
- **待测版本确实存在**：步骤 0 问题 5 选定的 `INSTALL_VER` 在 `install/` 下真有 `bin/mysqld`
  （`list_install_versions.sh "$REPO" --paths | grep -Fx "$INSTALL_VER"`；写错版本号/路径时这里就能拦住，不用等 launch 失败）
- `config_dir` 指向对应 `my.cnf`
- `threads`、`test_items`、`sysbench_bind_nodes` 与步骤 0 用户选择一致
- 若要做基准对比，`run_time`、`warmup_time` 等与 `BASELINE_LOG` 一致（否则对比无意义）
- **正本 == 部署副本**（步骤 0.4 已同步）：`sync_localhost_run.sh --check` 期望 exit 0
- 驱动正本已装 2.5 的 iostat hook：
  `grep -c 'mysql-sysbench-test: iostat-run-monitor' $SKILL_DIR/scripts/localhost_run.sh` 期望为 **4**（少了就按 2.5 补装）

### 2.3 使用监控脚本执行测试（推荐）

使用带负载监控的包装脚本执行测试，该脚本会自动完成：
- 测试前以 30 秒间隔扫描负载，高于门限则等待，直到无高负载才开始测试
- 测试运行中每 10 秒负载监控
- 检测到超出门限的其它负载时立即停止测试
- 等待负载降低后回到测试开始前的状态，重新执行测试脚本

```bash
cd $HOME/database/<REPO>/test/sysbench    # 只决定日志落在哪；驱动本身用绝对路径
$SKILL_DIR/scripts/sysbench_with_monitor.sh
```

日志文件自动命名为 `perf-monitored-<日期时间>.log`（写在当前目录）。
本脚本启动前会自动 `sync_localhost_run.sh`（正本 → 部署副本），所以**只要改正本，部署副本不会漏掉**。

### 2.4 手动执行测试（不推荐）

如不使用监控脚本，可手动执行，但需自行确保测试期间无其他高负载干扰：

```bash
cd $HOME/database/<REPO>/test/sysbench
LOG="perf-$(date +%Y-%m-%d-%H-%M).log"
$SKILL_DIR/scripts/sync_localhost_run.sh --quiet   # 先同步，再跑
$SKILL_DIR/scripts/localhost_run.sh 2>&1 | tee "$LOG"
```

测试耗时较长（正本默认 `run_time=100`、`warmup_time=20`，多并发 × 多测试项），勿提前中断。

### 2.5 run 阶段 iostat（w_await）采集

正式测试期间，对**写相关**的测试项自动采集数据/日志盘的 `w_await`（写平均等待时间），
用来判断 TPS 变化是不是磁盘写延迟造成的。规则固定，不需要每次问用户：

| 项 | 规则 |
|----|------|
| 采集对象 | 仅 `oltp_read_write`（混合读写）、`oltp_write_only`（纯写）、`oltp_insert`、`oltp_delete`、`oltp_update_index`、`oltp_update_non_index` 六项；`oltp_read_only`、`oltp_point_select` 不采集 |
| 采集窗口 | **只覆盖 sysbench `run` 命令的生命周期（含其 `--warmup-time`）**；prepare / cleanup 阶段的 IO 一律不计入 |
| 采集的盘 | 由 `my.cnf` 的 `datadir`、`log-bin`、`relay-log`、`innodb_log_group_home_dir`、`innodb_undo_directory`、`innodb_temp_tablespaces_dir`、`slow_query_log_file` 反查到的**整盘**（如 `nvme1n1`），去重后只把这些设备交给 iostat。不含 `tmpdir` 与 `log-error`（错误日志在安装目录/系统盘，与本次 IO 负载无关）；ramfs/tmpfs 上的路径没有块设备，会被跳过 |
| 采样 | `iostat -x`，**固定 10 秒**间隔（`-y` 丢掉"开机以来"的第一份统计，只留区间统计） |
| 输出 | 附在**该并发 run 阶段输出的后面**，每个「测试项 × 并发」一行 |

日志行格式（单盘，即需求给定格式）：

```text
run期间iostat - w_await为：12.34,9.87,10.02
```

- 每个数值 = 该盘**一个 10 秒区间**的 `w_await`（毫秒），按时间先后用逗号分隔
- 数值个数 ≈ `floor((run_time + warmup_time + 收尾时间) / 10)`：`run_time=100`、`warmup_time=30` 时通常是 **13** 个
- 多块盘时逐盘标注：`run期间iostat - w_await为：nvme1n1(12.34,...) nvme2n1(3.21,...)`
- 采集失败**不中断测试**，只打印一行 `run期间iostat - 未采集：<原因>（原始输出：<路径>）`

开始采集前会先打印一行监控盘信息（每次 driver 运行只打一次）：

```text
run期间iostat - 监控盘：nvme1n1（-x，间隔 10s；仅 run 阶段）
```

**依赖驱动正本里的 hook**（步骤 2.2 必须核对；hook 缺失时上面这些行不会出现）：

```bash
LR=$SKILL_DIR/scripts/localhost_run.sh
grep -c 'mysql-sysbench-test: iostat-run-monitor' "$LR"   # 期望 4
```

缺失时用脚本幂等补装（自动备份 `<正本>.bak-<日期时间>`；已装则跳过），再同步给部署副本：

```bash
cd $SKILL_DIR/scripts
./iostat_run_monitor.sh --install                    # 默认目标就是同目录的正本
bash -n localhost_run.sh                             # 装完必须能通过语法检查
./sync_localhost_run.sh                              # 正本 → test/sysbench
```

`--uninstall` 可移除 hook（同样会先备份）。采集逻辑全在
`scripts/iostat_run_monitor.sh`，driver 里只有 `source` + 两处
`iostat_run_begin` / `iostat_run_end` 调用；脚本缺失时 driver 退化为空操作，测试照常跑。

开关与调节（一般不需要动）：

| 环境变量 | 默认 | 说明 |
|----------|------|------|
| `IOSTAT_RUN_MONITOR=0` | `1` | 关闭采集（热点摸底 `hotspot_probe.sh` 内部就是这么关的） |
| `IOSTAT_RUN_INTERVAL` | `10` | 采样间隔秒数 |
| `IOSTAT_RUN_RAW_DIR` | `/tmp/iostat-run-monitor` | 原始 iostat 输出与 `detect.log`（逐条记录每个路径反查到哪块盘） |
| `IOSTAT_RUN_KEEP_RAW` | `1` | 置 `0` 则采集成功后删除原始输出 |
| `MYSQL_SYSBENCH_MYCNF` | 由 `config_dir` 或常见位置推断 | 覆盖 my.cnf 路径 |

自查设备识别（不进测试流程）：

```bash
$SKILL_DIR/scripts/iostat_run_monitor.sh --probe      # 只列盘，不采样
$SKILL_DIR/scripts/iostat_run_monitor.sh --sample 30  # 立刻采 30 秒看数值
```

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
python3 $SKILL_DIR/scripts/parse_sysbench_tps.py \
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
4. 写相关测试项（2.5 的六个采集项）每个并发的 `run期间iostat - w_await为：` 序列：
   TPS 掉而 `w_await` 明显变大/逐区间递增 → 点名磁盘侧写延迟；两者都不动 → 指向 CPU/锁；
   `w_await` 为 0.0x 且平稳 → 磁盘不是瓶颈
5. 若明显低于标准，提示检查：mysqld 是否绑核正确、磁盘、是否误用旧 socket、launch 是否成功
6. 若测试被负载监控中断过，需说明中断次数和原因

## 与 `successive_run_sysbench.sh` 的关系

`install/successive_run_sysbench.sh` 已封装「改配置 → launch → localhost_run → 写日志目录」。需要一键多场景时可直接改编该脚本；本 skill 的三步流程与之等价，且步骤 3 的解析脚本适用于其生成的 `*-perf.txt`。

## 故障排查

| 现象 | 处理 |
|------|------|
| 端口/socket 被占用 | 先执行 `stop_user_mysqld.sh <REPO>`；`pgrep -u $(whoami) -af mysqld` 确认无残留 |
| 想加一个 sysbench 相关的新参数（如 `run_time`、`auto_inc`）| 按步骤 0 的「提问编排规则」**优先放进第一轮**；第一轮满了就并进同类题的 `options`，或退到后续轮次；**已有轮次全满了就再开一轮**（模板见 0.6）。**轮次数量不设上限**，受约束的只有每轮 ≤ 4 题、每题 ≤ 4 选项 |
| 问完一轮忘了紧接着发下一轮 | 违规：各轮必须**紧挨着**（上一轮答案一返回立即发下一轮，中间不插任何动作）。这也是为什么各轮所需的扫描必须在**第一轮之前**先跑好并缓存 —— 否则后面的轮次组不出选项 |
| 同一题里既勾了选项、又在 Other 里补了别的 | **以 Other 里的显式描述为准**（缺项才按勾选/默认补），并把最终解析结果在 0.5 摘要里回显出来（摘要仅作展示，不再要求二次确认） |
| 步骤 0 扫描不到任何可用版本 | `list_install_versions.sh <REPO>` 打印的就是原因：`install/` 不存在或下面没有含 `bin/mysqld` 的构建。先 `mysql-build` 编译目标版本（产物落 `install/<native\|inhouse>/<版本号>/<base\|dev/特性名>`），或核对 `REPO` 是否选错，然后重新扫描。**别凭记忆硬填一个版本去问用户** |
| `INSTALL_VER` 写成了版本号（如 `8.0.32`） | 它要的是**安装目录**：`install/8.0.32` 不存在，真实目录是 `install/inhouse/8.0.32/...`。用 `list_install_versions.sh <REPO> --paths` 复核后改正 |
| 想测的版本不在扫描结果里 | 它可能还没构建（源码树里不等于装好了），或它的 `bin/mysqld` 被删过。`ls $HOME/database/<REPO>/install/<相对路径>/bin/mysqld` 直接确认；真没构建就先跑 `mysql-build` |
| launch 失败 | 查看 `install/<INSTALL_VER>/log.err`；核对 `STORAGE_PATH` 可写、ramfs 是否挂载成功 |
| ramfs 挂载失败 | 检查 sudo 权限；依次尝试 `/mnt/ramfs`、`/opt/ramfs`、`/tmp/ramfs-<用户>` |
| sysbench 连不上 | 核对 `socket`、`passwd`、root 密码是否为 `123456`（launch 默认设置） |
| 解析不到 TPS | 确认日志含 `...lua ... run` 与 `transactions: ... per sec.` |
| 对比全缺标准 | 检查 baseline 路径与测试参数是否与基准一致 |
| 测试被监控中止 | 查看告警中的高负载进程列表，等待其结束后重试 |
| `sync_localhost_run.sh --check` 报不一致 | 正本改过但没同步，或有人直接改了 `test/sysbench/` 那份。看 diff：以**正本**为准就执行 `sync_localhost_run.sh`（覆盖前自动备份）；确实是部署副本上的新改动，就把它搬进正本再同步 |
| 想走 TCP 却仍在走 socket | `socket` 没置空。sysbench **只要 `--mysql-socket` 非空就走 socket**，`ip` 写 `127.0.0.1` 也拦不住（host 被它改写成 `localhost`）⇒ 置空 `socket` 并确认 `ip="127.0.0.1"` |
| 置空了 `socket` 却连不上（报 2002） | `ip` 还是 `localhost`，libmysqlclient 去连编译默认 socket `/var/lib/mysql/mysql.sock`。改成 `ip="127.0.0.1"` |
| 想走 socket 却连不上 | sysbench 不会回退 TCP，`socket` 路径必须真实存在；按步骤 0.3 的映射改正本，再 `sync_localhost_run.sh` |
| 日志少了 `FIFO` 调度类那行 | 正本里那行带 `[ -x "$INSTALL_DIR/show_sched_class.sh" ]` 守卫；`ls $HOME/database/<REPO>/install/show_sched_class.sh` 确认脚本存在 |
| 热点摸底报「没有免密 sudo」 | perf 采样 mysqld 需要 root，先配好免密 sudo；不要退化成 `perf record -- sysbench ...` |
| 热点摸底报「找不到 mysqld」 | mysqld 未启动或 socket 不匹配，先回到步骤 1 |
| 热点摸底退出码 2（PAUSE） | 存在单函数自身占比 > 30% 的热点，**暂停测试**，先报告用户 |
| 热点摸底报「perf.data 无可读样本」 | perf 没采到任何样本：看 `--out/perf-record.out`（常见是 mysqld 在摸底期间重启/退出、或 perf record 被信号打断）；重跑一次摸底 |
| 热点摸底报「某测试项：日志里没有对应的时间窗」 | sysbench 日志里没出现该项的 `run` 行，多半是该项根本没跑起来，翻 `sysbench-raw.log` 确认 |
| 日志里没有 `run期间iostat - w_await为：` 行 | 先看是不是那六个采集项之一（`oltp_read_only`/`oltp_point_select` 本来就不采集）；再 `grep -c 'mysql-sysbench-test: iostat-run-monitor' $SKILL_DIR/scripts/localhost_run.sh`（期望 4），少了就 `iostat_run_monitor.sh --install` 然后 `sync_localhost_run.sh` |
| `run期间iostat - 未采集：找不到 iostat 命令` | 装 sysstat（`iostat -V` 验证）；测试本身不受影响，只是缺 w_await |
| `run期间iostat - 未采集：…反查不到数据/日志所在块设备` | 看 `/tmp/iostat-run-monitor/detect.log` 里每条路径的 skip 原因；数据/日志放在 ramfs/tmpfs 上时没有块设备，属正常 |
| `w_await` 数值个数不对 | 个数 ≈ `floor((run_time+warmup_time+收尾)/10)`；`run_time` 连 10 秒都不到时没有完整区间，会打印「未采集」 |
| 怀疑设备识别错（采错盘） | `iostat_run_monitor.sh --probe` 看每个路径反查到哪块盘；`--sample 30` 立刻采一轮核对数值 |

## 完整示例（txsql + opt 构建 + 选中单路+双路）

```bash
REPO=txsql
# 参数来自步骤 0 的各轮询问（本例只有两轮）：
#   第一轮（sysbench 侧）：问题 1 NUMA 拓扑（本例勾了「单路」+「双路」⇒ 两个阶段）
#                          问题 2 并发 / 问题 3 表×记录 / 问题 4 测试项
#   第二轮（运行与存储）：问题 5 测试版本 / 问题 6 通信方式 / 问题 7 存储盘
# 版本来自步骤 0 问题 5 的扫描（脚本按构建时间倒序，取用户选中的那一行）
$SKILL_DIR/scripts/list_install_versions.sh $REPO --limit 4
VER=opt/trx-lf-worker        # 示例值：实际填扫描结果里的相对路径
BASELINE_1SKT=$HOME/database/txsql/test/sysbench/base-2026-05-06-16-55/binlog_order_commits-OFF/1skt-base.txt
BASELINE_2SKT=$HOME/database/txsql/test/sysbench/base-2026-05-06-16-55/binlog_order_commits-OFF/2skt-base.txt

# 第一阶段：单路
$SKILL_DIR/scripts/stop_user_mysqld.sh $REPO
cd $HOME/database/$REPO/install
./launch.sh $VER y 0-3
cd $HOME/database/$REPO/test/sysbench
# 确保 sysbench_bind_nodes=("4-7")、通信方式两行配套（unix socket ⇒ socket 非空 + ip=localhost）
# 用 sed 改正本后同步：sync_localhost_run.sh
# 先做热点摸底（退出码 2 必须停下来报告用户，不得继续）
$SKILL_DIR/scripts/hotspot_probe.sh --threads 128
$SKILL_DIR/scripts/sysbench_with_monitor.sh
python3 $SKILL_DIR/scripts/parse_sysbench_tps.py \
  perf-monitored-*.log --baseline "$BASELINE_1SKT" --threshold 3

# 第二阶段：双路
$SKILL_DIR/scripts/stop_user_mysqld.sh $REPO
cd $HOME/database/$REPO/install
./launch.sh $VER y 0-7
cd $HOME/database/$REPO/test/sysbench
# 确保 sysbench_bind_nodes=("0-7")、通信方式两行配套（unix socket ⇒ socket 非空 + ip=localhost）
# 用 sed 改正本后同步：sync_localhost_run.sh
# 先做热点摸底（退出码 2 必须停下来报告用户，不得继续）
$SKILL_DIR/scripts/hotspot_probe.sh --threads 128
$SKILL_DIR/scripts/sysbench_with_monitor.sh
python3 $SKILL_DIR/scripts/parse_sysbench_tps.py \
  perf-monitored-*.log --baseline "$BASELINE_2SKT" --threshold 3
```
