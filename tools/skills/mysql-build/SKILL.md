---
name: mysql-build
description: Build MySQL with the in-house cmake preset (mysql/txsql) or polarDb build.sh (polardbx-engine); on compile errors fix source and retry; on success install to the configured prefix. Use when the user asks to compile MySQL, run cmake, build polarDb/polardbx-engine, or produce an install under $HOME/database/mysql/install/<native|inhouse>/<version>/..., $HOME/database/txsql/install/, or $HOME/database/polarDb/install/.
---

# MySQL Build

## Instructions

Use this skill when compiling MySQL in this repository.

### 仓库识别与编译路径分流

**先判断当前仓库类型**，再选择对应编译流程。判定按下列优先级依次尝试，**命中任一 polarDb 条件即走 `build.sh` 流程**：

| 优先级 | 判定方式 | polarDb 条件 |
|--------|---------|--------------|
| 1 | **Workspace / git 根路径** | 路径中包含目录段 `polarDb` 或 `polardbx-engine`（如 `.../polarDb/ingredients/polardbx-engine`） |
| 2 | **git remote** | `git remote get-url origin` 输出含 `polardbx-engine` |
| 3 | **源码特征文件** | 仓库根目录 `include/mysql_version.h.in` 中存在 `POLARDBX_PRODUCT_VERSION` 宏定义 |

若以上均未命中 → 使用 **cmake 预设流程**（mysql、txsql 等）。

**判定命令**（在仓库根目录执行）：

```bash
is_polarDb=0
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
case "$repo_root" in
  */polarDb/*|*/polardbx-engine|*/polarDb|*/polardbx-engine/*) is_polarDb=1 ;;
esac
if [ "$is_polarDb" -eq 0 ]; then
  url="$(git remote get-url origin 2>/dev/null || true)"
  echo "$url" | grep -q 'polardbx-engine' && is_polarDb=1
fi
if [ "$is_polarDb" -eq 0 ] && \
   [ -f include/mysql_version.h.in ] && \
   grep -q 'POLARDBX_PRODUCT_VERSION' include/mysql_version.h.in; then
  is_polarDb=1
fi
[ "$is_polarDb" -eq 1 ] && echo polarDb || echo cmake
```

> **不要**用「存在 `build.sh` + `sql/mysqld.cc`」判定 polarDb——MySQL 系仓库普遍具备，易误判。

---

## mysql 安装路径（变体与版本标识）

> **仅适用于 mysql 仓库**（txsql、polarDb 不受此节影响，继续沿用原有路径结构）。

mysql 编译产物的安装路径在原有 `install/<base|dev/特性>` 之上，新增 **变体（variant）** 和 **版本号（version）** 两级目录：

```
$HOME/database/mysql/install/<variant>/<version>/<base|dev/特性名>
```

### 变体标识（native / inhouse）

| 场景 | variant | 含义 |
|------|---------|------|
| **base**（工作区相对上游无代码改动） | `native` | 原生社区版本，无自研改动 |
| **dev**（有新增/修改代码） | `inhouse` | 自研版本，含 in-house 特性改动 |

> 变体与 `base`/`dev` 直接对应：base → `native`，dev → `inhouse`。无需额外判定。

### 版本号提取

从仓库根目录的 `MYSQL_VERSION` 文件提取主、次、补丁版本号，组合为 `<MAJOR>.<MINOR>.<PATCH>` 格式（若 `MYSQL_VERSION_EXTRA` 非空则追加）。

**提取命令**（仓库根目录执行）：

```bash
ver_file="MYSQL_VERSION"
if [ -f "$ver_file" ]; then
  major=$(awk -F= '/^MYSQL_VERSION_MAJOR=/ {print $2}' "$ver_file")
  minor=$(awk -F= '/^MYSQL_VERSION_MINOR=/ {print $2}' "$ver_file")
  patch=$(awk -F= '/^MYSQL_VERSION_PATCH=/ {print $2}' "$ver_file")
  extra=$(awk -F= '/^MYSQL_VERSION_EXTRA=/ {print $2}' "$ver_file")
  version="${major}.${minor}.${patch}${extra}"
else
  echo "错误：未找到 MYSQL_VERSION 文件，无法确定版本号" >&2
  exit 1
fi
echo "$version"
```

### 路径示例

| 仓库 | 场景 | variant | version | 最终 INSTALL_PREFIX |
|------|------|---------|---------|---------------------|
| mysql | base（无改动） | `native` | 8.0.32 | `$HOME/database/mysql/install/native/8.0.32/base` |
| mysql | dev（opt-crc32 特性） | `inhouse` | 8.0.32 | `$HOME/database/mysql/install/inhouse/8.0.32/dev/opt-crc32` |
| txsql | base（无改动） | — | — | `$HOME/database/txsql/install/base`（不变） |
| txsql | dev（某特性） | — | — | `$HOME/database/txsql/install/dev/<特性名>`（不变） |
| polarDb | base | — | — | `$HOME/database/polarDb/install/base`（不变） |
| polarDb | dev | — | — | `$HOME/database/polarDb/install/dev/<特性名>`（不变） |

### cmake 执行步骤中 mysql 路径的拼接

在「mysql / txsql 编译流程」执行步骤中，确定 `<variant>` 和 `<version>` 的时机：

1. 先按「目录名规则」确定是 `base` 还是 `dev/<特性名>`。
2. 由此确定 variant：`base` → `native`，`dev` → `inhouse`。
3. 执行上述版本号提取命令拿到 `version`。
4. 最终 `CMAKE_INSTALL_PREFIX` 拼为 `$HOME/database/mysql/install/<variant>/<version>/<base|dev/特性名>`。

---

## polarDb（polardbx-engine）编译流程

### 基本要求

1. **必须在 polardbx-engine 仓库根目录**（`build.sh` 所在目录）执行 `./build.sh`。
2. **默认 `release`**：除非用户提示词中**明确要求 debug**（如「编译 debug」「Debug 版本」），否则始终使用 `-t release`。
3. **安装目录**：
   - **base 版本**（无本地特性改动，或用户明确要求编 base）：`~/database/polarDb/install/base`
   - **特性版本**（有新增/修改代码，或用户指定特性名）：`~/database/polarDb/install/dev/<特性相关的版本名称>`
4. `build.sh` 内部已执行 `cmake` + `make -j$(nproc) install`，**不要**再单独跑 cmake / make install。

### 安装目录与特性命名

与 cmake 流程共用「目录名规则」（见下文），但路径前缀固定为 polarDb：

| 场景 | `DEST_DIR` |
|------|------------|
| base | `$HOME/database/polarDb/install/base` |
| 特性/dev | `$HOME/database/polarDb/install/dev/<特性相关的版本名称>` |

示例（opt-crc32 特性 release 编译）：

```bash
cd $HOME/database/polarDb/ingredients/polardbx-engine   # 仓库根目录
./build.sh -t release -d $HOME/database/polarDb/install/dev/opt-crc32
```

示例（base release 编译）：

```bash
cd $HOME/database/polarDb/ingredients/polardbx-engine
./build.sh -t release -d $HOME/database/polarDb/install/base
```

仅当用户**明确要求 debug** 时：

```bash
./build.sh -t debug -d $HOME/database/polarDb/install/dev/<特性相关的版本名称>
```

增量重编（不 `make clean`，用户要求或仅小改动时）：

```bash
./build.sh -t release -d <DEST_DIR> -r
```

### polarDb 执行步骤

1. 确认当前目录为 polardbx-engine 仓库根目录。
2. 按「目录名规则」确定 `<特性相关的版本名称>` 或 `base`。
3. **编译前环境检查**：按下文「编译前环境检查」一节，确认 libnuma / libaio / patchelf / libtirpc-devel / rpcgen 等依赖就绪（缺失则先自动安装）；`build.sh` 内部会调用 cmake，依赖同样必需。
4. **系统负载检查**（见下文），空闲后再编译。
5. 执行 `./build.sh -t release -d <DEST_DIR>`（或 debug / `-r` 按需）。
6. **编译失败时**：根据报错做最小修复后重跑 `build.sh`；环境问题则停止并报告。
7. **成功后**：二进制已在 `<DEST_DIR>`，用 `launch.sh` 验证时路径为 `install/base` 或 `install/dev/<特性名>`。

### polarDb 注意事项

- 不要改用 cmake 手动配置，除非 `build.sh` 不存在或用户明确要求。
- 不要擅自把 `-t release` 改成 `debug` / `release_with_debinfo`。
- `build.sh` 使用 `make -j$(nproc)`，与 mysql/txsql 的 `-j64` 不同，勿强行改并行度除非用户要求。
- **指定编译器**：`build.sh` 内部调用 cmake，若用户要求指定编译器，需先确认 `build.sh` 是否支持透传额外 cmake 参数（如 `-D...`）；支持则把 `-DCMAKE_C_COMPILER=<C 编译器绝对路径>` 与 `-DCMAKE_CXX_COMPILER=<C++ 编译器绝对路径>` 一并传给 `build.sh`（路径解析规则同「编译器指定」一节，C/C++ 同版本、用绝对路径）；不支持则停止并告知用户需改用手动 cmake 流程。

---

## mysql / txsql 编译流程（cmake 预设）

### Required build commands

Run cmake from the build directory with this exact pattern:

```bash
cmake .. \
  -DBUILD_CONFIG=mysql_release \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=1 \
  -DCMAKE_INSTALL_PREFIX=$HOME/database/<根据当前workspace是mysql还是txsql来决定，如果是mysql，此处的目录名就是mysql；如果是txsql，此处的目录名就是txsql>/install/<【mysql】：按「mysql 安装路径（变体与版本标识）」节，拼入 <native|inhouse>/<版本号>/<base|dev/特性>；【txsql】：<如果当前分支没有新增的代码修改，目录名就是base；如果有代码修改，那目录名就是dev/<当上一级的目录名是dev时，则按当前新增或修改特性来命名这一级的目录名>> \
  -DWITH_BOOST=/<当前workspace>/boost/boost_<版本号>
```

`CMAKE_BUILD_TYPE` 默认为 `RelWithDebInfo`；除非用户明确要求 Debug 等其他类型，否则始终使用此默认值。

若用户**明确要求使用指定版本/路径的编译器**（如「用 gcc-9」「使用 gcc 9.3.0」「编译器用 /opt/gcc-9.4.0/bin/gcc」），按下方「编译器指定」一节，在上述 cmake 命令末尾追加 `-DCMAKE_C_COMPILER=<C 编译器绝对路径>` 与 `-DCMAKE_CXX_COMPILER=<C++ 编译器绝对路径>`；用户未要求时**不要添加**，使用系统默认编译器。

Run make with fixed parallelism:

```bash
make -j64
```

After a successful build, install binaries with the same parallelism:

```bash
make install -j64
```

### cmake 执行步骤

1. Confirm or create a build directory (for example `build`).
2. 根据当前正在进行的新增或修改特性，生成 `<按当前新增或修改特性命名的目录名>`（见下文「目录名规则」）。
3. **编译前环境检查**：按下文「编译前环境检查」一节，确认 libnuma / libaio / patchelf / libtirpc-devel / rpcgen 等依赖就绪（缺失则先自动安装），通过后再继续。
4. **系统负载检查**：按下方逻辑，确认系统空闲后再继续。
5. Run the required `cmake` command above.
6. Run `make -j64`.
7. **编译失败时**：根据编译器/链接器报错定位源码，只做与修复该错误相关的最小改动，然后返回步骤 6 重试。
8. **编译成功后**：在构建目录执行 `make install -j64`。

---

## 编译器指定（指定版本编译器）

仅当用户**明确要求使用指定版本或指定路径的编译器**时才启用；用户未要求时使用系统默认编译器，**不要**添加下列变量。

在 cmake 命令中通过缓存变量（宏定义）指定编译器路径：

- `-DCMAKE_C_COMPILER=<C 编译器可执行文件绝对路径>`
- `-DCMAKE_CXX_COMPILER=<C++ 编译器可执行文件绝对路径>`

### 编译器路径解析规则

1. **用户已给出完整路径**：直接采用。若只给出 C 编译器路径，C++ 编译器取同目录下对应版本（把路径末尾的 `gcc` 替换为 `g++`，`cc` 替换为 `c++`）。
2. **用户只给出版本号/版本名**（如 `gcc-9`、`gcc 9`、`9.3.0`）：
   - 依次尝试 `command -v gcc-<主版本>` / `command -v g++-<主版本>`（例：`gcc-9`、`g++-9`）；
   - 未命中再尝试 `command -v gcc-<完整版本>` / `command -v g++-<完整版本>`（例：`gcc-9.3.0`、`g++-9.3.0`）；
   - 仍找不到则**停止并向用户报告**，不要回退到系统默认编译器擅自编译。
3. **同时指定 C 与 C++ 两个编译器**，且二者须为同一版本套件，避免前后端版本不一致引发链接/ABI 问题。
4. **一律使用绝对路径**：解析后用 `readlink -f` / `command -v` 取绝对路径再填入；填入前用 `test -x` 确认可执行文件存在。
5. **增量重编注意**：更换编译器属于配置变更，必须删除旧 `build` 目录（或至少清除 `CMakeCache.txt`）后重新 `cmake`，否则旧缓存中的编译器路径不会更新。

### 解析示例

```bash
# 用户说「用 gcc-9」：解析 C/C++ 编译器绝对路径
CC="$(command -v gcc-9)" && CXX="$(command -v g++-9)"
CC="$(readlink -f "$CC")"; CXX="$(readlink -f "$CXX")"
test -x "$CC" && test -x "$CXX" || { echo "未找到 gcc-9/g++-9"; exit 1; }
echo "CC=$CC"; echo "CXX=$CXX"
```

### cmake 命令示例（带指定编译器）

```bash
cmake .. \
  -DBUILD_CONFIG=mysql_release \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=1 \
  -DCMAKE_INSTALL_PREFIX=$HOME/database/<根据当前workspace是mysql还是txsql来决定>/install/<【mysql】：<native|inhouse>/<版本号>/<按目录名规则>；【txsql】：<按目录名规则>> \
  -DWITH_BOOST=/<当前workspace>/boost/boost_<版本号> \
  -DCMAKE_C_COMPILER=/usr/bin/gcc-9 \
  -DCMAKE_CXX_COMPILER=/usr/bin/g++-9
```

---

## 编译前环境检查（两种流程共用）

cmake 编译前必须先确认下列构建依赖已安装；**缺失则先自动安装再继续编译**，无法安装则停止并向用户报告，不要带着缺失依赖进入 cmake（否则会在配置/链接阶段报一堆找不到头文件/符号的错误）。

待检查项（库以 `-devel`/开发包为准——构建需要头文件与 `.so` 符号链接，仅有运行时库不够；工具以可执行文件为准）：

| 依赖 | 包名（openEuler/RHEL） | 检测方式 |
|------|------------------------|----------|
| libnuma 库 | `numactl-devel` | `rpm -q` |
| libaio 库 | `libaio-devel` | `rpm -q` |
| patchelf | `patchelf` | `command -v` |
| libtirpc-devel | `libtirpc-devel` | `rpm -q` |
| rpcgen | `rpcgen` | `command -v` |

> polarDb 的 `build.sh` 内部也会调用 cmake，上述依赖同样必需，故两种流程共用本检查。

检查与安装脚本（退出码 0 = 就绪可编译，1 = 有依赖缺失且无法自动安装，**不得继续 cmake**）：

```bash
# 依赖项: "描述|检测方式|目标"  检测方式 rpm=rpm -q, cmd=command -v
deps=(
  "libnuma库|rpm|numactl-devel"
  "libaio库|rpm|libaio-devel"
  "patchelf|cmd|patchelf"
  "libtirpc-devel|rpm|libtirpc-devel"
  "rpcgen|cmd|rpcgen"
)

check_one() {
  case "$1" in
    rpm) rpm -q "$2" >/dev/null 2>&1 ;;
    cmd) command -v "$2" >/dev/null 2>&1 ;;
  esac
}

detect_pm() {
  for pm in dnf yum; do command -v "$pm" >/dev/null 2>&1 && { printf '%s' "$pm"; return 0; }; done
  return 1
}

echo "=== 编译前环境检查 ==="
missing=()
for d in "${deps[@]}"; do
  desc="${d%%|*}"; rest="${d#*|}"; method="${rest%%|*}"; target="${rest#*|}"
  if check_one "$method" "$target"; then echo "[就绪] $desc"; else echo "[缺失] $desc"; missing+=("$d"); fi
done

[ "${#missing[@]}" -eq 0 ] && { echo "依赖就绪，可继续编译。"; exit 0; }

PM="$(detect_pm || true)"
if [ -z "$PM" ]; then
  echo "错误：未找到 dnf/yum，无法自动安装缺失依赖，请手动安装后重试。" >&2
  exit 1
fi

install_pkgs=()
for d in "${missing[@]}"; do rest="${d#*|}"; install_pkgs+=("${rest##*|}"); done
echo "将通过 $PM 安装缺失依赖: ${install_pkgs[*]}"

cmd=( "$PM" install -y "${install_pkgs[@]}" )
if [ "$(id -u)" -eq 0 ]; then "${cmd[@]}"
elif sudo -n true 2>/dev/null; then sudo "${cmd[@]}"
else
  echo "错误：安装依赖需要 root 权限且当前无法免密 sudo。请手动执行: sudo ${cmd[*]}" >&2
  exit 1
fi

echo "=== 安装后复检 ==="
failed=()
for d in "${missing[@]}"; do
  desc="${d%%|*}"; rest="${d#*|}"; method="${rest%%|*}"; target="${rest#*|}"
  if check_one "$method" "$target"; then echo "[就绪] $desc"; else echo "[仍缺失] $desc"; failed+=("$desc"); fi
done
[ "${#failed[@]}" -gt 0 ] && { echo "错误：以下依赖安装后仍未就绪: ${failed[*]}" >&2; exit 1; }
echo "依赖安装完成，可继续编译。"
```

要点：
- 安装依赖需要 **root 或免密 sudo**；不具备时停止并提示用户手动执行给出的命令，**不要跳过检查直接 cmake**。
- 复检仍失败（如包源不可用 / 网络不通 / 无对应包）也停止报告，不进入编译。
- 该检查在「系统负载检查」之前执行——依赖未就绪时先解决依赖，再等系统空闲。

---

## 系统负载检查（两种流程共用）

在执行编译之前，必须先检查系统是否存在高负载应用。

**判定标准**（满足任一即判定为系统繁忙）：
1. **单进程高负载**：某个进程的负载 CPU 个数超过 10（即 `top` 中该进程 `%CPU > 1000`）。
2. **同名进程聚集**：系统中存在超过 5 个 CPU 利用率 > 50% 且名称相同的进程。

**检查与等待逻辑**：
1. 执行负载检查，判断当前系统是否空闲。
2. **系统空闲**：立即开始执行编译。
3. **系统繁忙**：以 10 秒为间隔循环检查，当连续 2 次检查均判定系统空闲后，再开始执行编译。

**负载检查命令**（退出码 0 = 繁忙，退出码 1 = 空闲）：

```bash
busy=0
top -b -n2 -d1 -o %CPU 2>/dev/null | awk '
  /^ *PID/ { iter++; next }
  iter == 2 && /^ *[0-9]/ && $9+0 > 1000 { found=1 }
  END { exit !found }
' && busy=1
ps -eo pcpu,comm --no-headers | awk '
  $1+0 > 50 { name_count[$2]++ }
  END { found=0; for (n in name_count) if (name_count[n] > 5) found=1; exit !found }
' && busy=1
exit $busy
```

**等待循环脚本**：

```bash
idle_count=0
while [ "$idle_count" -lt 2 ]; do
  busy=0
  top -b -n2 -d1 -o %CPU 2>/dev/null | awk '
    /^ *PID/ { iter++; next }
    iter == 2 && /^ *[0-9]/ && $9+0 > 1000 { busy=1 }
    END { exit !busy }
  ' && busy=1
  ps -eo pcpu,comm --no-headers | awk '
    $1+0 > 50 { name_count[$2]++ }
    END { found=0; for (n in name_count) if (name_count[n] > 5) found=1; exit !found }
  ' && busy=1
  if [ "$busy" -eq 0 ]; then
    idle_count=$((idle_count + 1))
    echo "系统空闲检测 ${idle_count}/2 通过"
  else
    idle_count=0
    echo "检测到高负载进程，等待 10 秒..."
  fi
  [ "$idle_count" -lt 2 ] && sleep 10
done
echo "系统空闲，开始执行编译"
```

---

## 目录名规则（特性命名）

用于填充 `<特性相关的版本名称>` / `<按当前新增或修改特性命名的目录名>`：

1. **以特性为导向**：根据用户描述的新增功能、改动点或议题主题，提炼简短英文或小写 hyphen 标识（如 `opt-crc32`、`binlog-sync-improve`）。
2. **与其它信息对齐**：用户已给出特性代号、分支名与特性语义一致、或 MR/PR 标题即特性名时，可直接采用。
3. **路径安全规范化**：`/` → `-`，空格 → `-`；仅保留字母、数字、`.`、`_`、`-`。
4. **无法确定特性时**：回退当前分支名（`git rev-parse --abbrev-ref HEAD`）规范化结果；仍不可用则用 `manual-build`。
5. **base 判定**：工作区相对上游/base 分支无代码改动，或用户明确说「编 base」「安装到 base」→ 使用 `install/base`，不走 `dev/`。

---

## Notes

- **polarDb**：走 `build.sh`，默认 `-t release`，安装到 `~/database/polarDb/install/base` 或 `~/database/polarDb/install/dev/<特性名>`。
- **mysql**：走 cmake 预设，默认 `RelWithDebInfo`，`make -j64` + `make install -j64`。安装路径含变体+版本号两级标识：`~/database/mysql/install/<variant>/<version>/<base|dev/特性>`，详见「mysql 安装路径（变体与版本标识）」节。
- **txsql**：走 cmake 预设，默认 `RelWithDebInfo`，`make -j64` + `make install -j64`，安装到 `~/database/txsql/install/base` 或 `~/database/txsql/install/dev/<特性名>`。
- **编译前环境检查**：两种流程在 cmake 前（polarDb 即 `build.sh` 内部 cmake 前）均需确认 libnuma / libaio / patchelf / libtirpc-devel / rpcgen 已安装，缺失则先自动安装；无法安装则停止报告，详见「编译前环境检查」一节。
- **指定编译器**：仅当用户明确要求时，在 cmake 命令追加 `-DCMAKE_C_COMPILER` / `-DCMAKE_CXX_COMPILER`（绝对路径，C/C++ 同版本），并清除旧 `CMakeCache.txt` 后重新 cmake；详见「编译器指定」一节。
- 修复编译错误时：改动范围尽量小，不借机做无关重构。
- 回报时需包含：仓库类型（polarDb / cmake）、build 目录或 `build.sh`、最终安装前缀、是否成功。
- **mysql 回报补充**：若为 mysql 仓库，回报时注明变体（`native` / `inhouse`）与提取到的版本号。
