#!/bin/bash
# ============================================================================
# sync_localhost_run.sh —— 把 sysbench 驱动的「正本」同步到「部署副本」
#
#   正本    : <本脚本所在目录>/  —— 本仓库内的 tools/skills/mysql-sysbench-test/scripts/
#             （宿主从 <仓库>/.claude/skills/mysql-sysbench-test 加载本 skill 时，
#               那条软链解析后就是同一个目录）
#   部署副本: $HOME/database/<REPO>/test/sysbench/
#   同步对象: localhost_run.sh + iostat_run_monitor.sh（两者必须成对，见下）
#
# 为什么要同步：sysbench 只由「正本」驱动（skill 铁律），而仓库里的 test/sysbench/
# 不在任何 git 仓库内，还有别的工具（successive_run_test.sh）直接改它、跑它。
# 任何对驱动的修改都必须只改正本，然后由本脚本把改动推给部署副本，两份始终保持一致；
# 这样驱动的改动随 skill 一起进版本库，不会丢。
#
# 用法：
#   sync_localhost_run.sh                # 同步（正本 → 部署副本；内容相同则跳过）
#   sync_localhost_run.sh --check        # 只比较：一致 exit 0，不一致 exit 1（打印 diff 摘要）
#   sync_localhost_run.sh --quiet        # 供包装脚本自动调用：无变更/成功时不输出
#   sync_localhost_run.sh --path <file>  # 显式指定部署副本路径
#   sync_localhost_run.sh --print-target # 只打印解析出的部署副本路径（调试用）
#
# 行为：
#   * 覆盖前自动备份部署副本为 localhost_run.sh.bak-<日期时间>
#   * 复制后逐字节校验（cmp），并保证可执行位（755）
#   * 幂等：两份一致时不做任何写入、不产生备份
#
# 环境变量：REPO=<mysql|polarDb|txsql>  指定部署副本所属仓库（默认从当前目录推断，再退回 mysql）
# ============================================================================

set -u

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MASTER="$SCRIPTS_DIR/localhost_run.sh"

QUIET=0
MODE="sync"
TARGET=""

while [ $# -gt 0 ]; do
    case "$1" in
        --check)        MODE="check" ;;
        --quiet|-q)     QUIET=1 ;;
        --path)         shift; TARGET="${1:-}" ;;
        --print-target) MODE="print" ;;
        -h|--help)      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：$1（-h 看用法）" >&2; exit 2 ;;
    esac
    shift
done

say() { [ "$QUIET" -eq 1 ] || echo "$@"; }
warn() { echo "$@" >&2; }

# ---------- 解析 REPO 与部署副本路径 ----------
infer_repo() {
    local p="$PWD"
    case "$p" in
        "$HOME"/database/*)
            p="${p#"$HOME"/database/}"
            printf '%s' "${p%%/*}"
            ;;
        *) printf '%s' "" ;;
    esac
}

REPO_ENV="${REPO:-}"          # 用户显式指定的 REPO（显式指定时不再做任何猜测）

if [ -z "$TARGET" ]; then
    REPO="${REPO_ENV:-$(infer_repo)}"
    [ -n "$REPO" ] || REPO="mysql"
    TARGET="$HOME/database/$REPO/test/sysbench/localhost_run.sh"

    # 当前目录推不出仓库、且推断出来的路径不存在时，若 $HOME/database 下只有一个
    # 候选部署副本，就用它（允许从任意目录调用）。
    if [ ! -e "$TARGET" ] && [ -z "$REPO_ENV" ] && [ -z "$(infer_repo)" ]; then
        cands=()
        for f in "$HOME"/database/*/test/sysbench/localhost_run.sh; do
            [ -e "$f" ] && cands+=("$f")
        done
        if [ "${#cands[@]}" -eq 1 ]; then
            TARGET="${cands[0]}"
            warn "提示：未从当前目录推断出 REPO，改用唯一的候选部署副本 $TARGET"
        fi
    fi
fi

case "$MODE" in
    print) printf '%s\n' "$TARGET"; exit 0 ;;
esac

[ -f "$MASTER" ] || { warn "ERROR: 找不到正本 $MASTER"; exit 1; }
[ -d "$(dirname "$TARGET")" ] || { warn "ERROR: 部署副本目录不存在：$(dirname "$TARGET")（REPO 推断为 ${REPO:-?}，可用 REPO=<name> 或 --path 指定）"; exit 1; }
[ -f "$TARGET" ] || { warn "ERROR: 部署副本不存在：$TARGET（首次部署请先手工放置一份）"; exit 1; }

# ---------- 成对同步：驱动 + 它的 iostat hook ----------
# 驱动按「与自身同目录」定位 iostat_run_monitor.sh（见驱动里的 hook 块），所以两份必须
# 一起落到部署目录；只搬驱动的话，部署副本里的 run 阶段采集会静默退化成空操作（测试本身
# 不受影响，只是没有 w_await 行）。同理，两份都必须来自本仓库，不引用任何仓库外的安装副本。
DEPLOY_DIR="$(dirname "$TARGET")"
PAIR=(localhost_run.sh iostat_run_monitor.sh)

problems=0
for name in "${PAIR[@]}"; do
    master="$SCRIPTS_DIR/$name"
    target="$DEPLOY_DIR/$name"

    [ -f "$master" ] || { warn "ERROR: 找不到正本 $master"; problems=1; continue; }

    if cmp -s "$master" "$target"; then
        [ "$MODE" = "check" ] || say "已一致，无需同步：$name"
        continue
    fi

    if [ "$MODE" = "check" ]; then
        warn "不一致：正本 $master  !=  部署副本 $target"
        warn "---- diff -u（正本 - / 部署副本 +，最多 60 行）----"
        diff -u "$master" "$target" | head -60 >&2
        problems=1
        continue
    fi

    # ---------- 同步（先备份；首次放置则无备份可做） ----------
    if [ -e "$target" ]; then
        bak="$target.bak-$(date +%Y%m%d-%H%M%S)"
        cp -p "$target" "$bak" || { warn "ERROR: 备份 $target 失败，已中止"; problems=1; continue; }
    else
        bak="（原文件不存在，本次为首次放置）"
    fi

    cp -p "$master" "$target" || { warn "ERROR: 写入 $target 失败（备份在 $bak）"; problems=1; continue; }
    chmod 755 "$target"

    if cmp -s "$master" "$target"; then
        say "已同步：$master  →  $target"
        say "  备份：$bak"
    else
        warn "ERROR: 复制后校验失败（$target 与正本不一致）！备份在 $bak"
        problems=1
    fi
done

if [ "$MODE" = "check" ]; then
    [ "$problems" -eq 0 ] && say "一致：正本 == 部署副本（$DEPLOY_DIR）"
    [ "$problems" -eq 0 ] || warn "修复：$(basename "${BASH_SOURCE[0]}")   # 或改正本后重跑本脚本"
else
    if [ "$problems" -eq 0 ]; then
        say "  校验：逐字节一致（cmp），可执行位 755"
        say "  说明：部署副本目录不在 git 仓库内，本文件是它的版本兜底；"
        say "        今后请只改正本 $SCRIPTS_DIR/ 下的文件，不要直接改 $DEPLOY_DIR/ 下的。"
    fi
fi
exit "$problems"
