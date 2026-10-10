#!/bin/bash
# list_install_versions.sh —— 扫描 $HOME/database/<REPO>/install 下**已构建可用**的 MySQL 版本，
# 供 mysql-sysbench-test 步骤 0 的「测试版本」询问使用。
#
# 「可用」= 目录里存在 bin/mysqld（即 launch.sh 能吃下的安装目录）。
# 只列 install/ 下的构建产物；源码树（ingredients/…）里没编译的不算，
# 需要时先用 mysql-build 构建。
#
# 输出：按**构建时间**（该目录 bin/mysqld 的 mtime）降序
#   默认      <构建时间> \t <相对 install/ 的路径> \t <mysqld 版本串>
#   --paths   只输出相对路径（每行一个），便于脚本消费
#   --md      输出 Markdown 表（便于写进 AskUserQuestion 的 question 文本）
#
# 用法：
#   list_install_versions.sh [REPO] [--limit N] [--paths|--md] [-h]
#   REPO 也可用环境变量指定；都不给时从当前目录推断（$HOME/database/<REPO>/…），兜底 mysql。
#
# 退出码：0 = 有结果；1 = 一个都没扫到（并打印排查提示）

set -u

LIMIT=0
MODE=tsv
REPO_ARG=""

usage() {
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --limit)   LIMIT="${2:-0}"; shift 2 ;;
        --paths)   MODE=paths; shift ;;
        --md)      MODE=md; shift ;;
        -*)        echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
        *)         REPO_ARG="$1"; shift ;;
    esac
done

infer_repo() {
    case "$PWD" in
        "$HOME"/database/*) local p="${PWD#"$HOME"/database/}"; printf '%s' "${p%%/*}" ;;
        *)                  printf '%s' "" ;;
    esac
}

REPO="${REPO_ARG:-${REPO:-$(infer_repo)}}"
REPO="${REPO:-mysql}"
INSTALL_ROOT="$HOME/database/$REPO/install"

if [ ! -d "$INSTALL_ROOT" ]; then
    echo "扫描失败：目录不存在 $INSTALL_ROOT" >&2
    echo "  · REPO 是否正确？（当前 REPO=$REPO；可用 \$REPO 或第 1 个参数覆盖）" >&2
    exit 1
fi

rows=""
while IFS= read -r mysqld; do
    [ -n "$mysqld" ] || continue
    dir="$(dirname "$(dirname "$mysqld")")"          # .../bin/mysqld → 安装目录
    rel="${dir#"$INSTALL_ROOT"/}"
    mtime="$(stat -c %Y "$mysqld" 2>/dev/null || echo 0)"
    ver="$("$mysqld" --version 2>/dev/null | head -n 1 |
           sed -n 's/.*[Vv]er[[:space:]]*\([0-9][^[:space:]]*\).*/\1/p')"
    [ -n "$ver" ] || ver="-"
    rows="${rows}${mtime}"$'\t'"${rel}"$'\t'"${ver}"$'\n'
# maxdepth 6：要覆盖 install/<variant>/<版本号>/dev/<特性名>/bin/mysqld 这种最深布局
done < <(find "$INSTALL_ROOT" -maxdepth 6 -type f -name mysqld -path '*/bin/mysqld' 2>/dev/null)

if [ -z "${rows//[$'\n']/}" ]; then
    echo "扫描失败：$INSTALL_ROOT 下没有含 bin/mysqld 的构建" >&2
    echo "  · 未构建过？先用 mysql-build 编译（装到 $INSTALL_ROOT/<native|inhouse>/<版本号>/<base|dev/特性名>）" >&2
    echo "  · 或 REPO 选错了（当前 REPO=$REPO）" >&2
    exit 1
fi

sorted="$(printf '%s' "$rows" | sort -t$'\t' -k1,1nr)"
[ "$LIMIT" -gt 0 ] 2>/dev/null && sorted="$(printf '%s' "$sorted" | head -n "$LIMIT")"

case "$MODE" in
    paths)
        printf '%s' "$sorted" | cut -f2
        ;;
    md)
        echo "| # | 构建时间 | 安装路径（相对 install/） | 版本 |"
        echo "|---|----------|---------------------------|------|"
        n=0
        while IFS=$'\t' read -r mtime rel ver; do
            [ -n "$rel" ] || continue
            n=$((n + 1))
            printf '| %d | %s | `%s` | %s |\n' "$n" "$(date -d "@$mtime" '+%Y-%m-%d %H:%M')" "$rel" "$ver"
        done <<< "$sorted"
        ;;
    *)
        # 注意用 here-string 而非 `printf | while`：命令替换会吃掉行尾换行，
        # 管道里的最后一行没有 \n，read 在 EOF 处返回非 0，循环体会跳过它（丢末行）。
        while IFS=$'\t' read -r mtime rel ver; do
            [ -n "$rel" ] || continue
            printf '%s\t%s\t%s\n' "$(date -d "@$mtime" '+%Y-%m-%d %H:%M')" "$rel" "$ver"
        done <<< "$sorted"
        ;;
esac
