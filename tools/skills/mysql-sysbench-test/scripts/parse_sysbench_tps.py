#!/usr/bin/env python3
"""Parse sysbench log (localhost_run.sh stdout) and compare TPS to a baseline file."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Tuple

Key = Tuple[str, int]  # (lua_basename, threads)

CMD_RE = re.compile(
    r"sysbench.*/([\w_]+)\.lua\b.*--threads=(\d+)\b.*\brun\b",
    re.IGNORECASE,
)
TPS_RE = re.compile(
    r"transactions:\s+\d+\s+\(([\d.]+)\s+per\s+sec\.\)",
    re.IGNORECASE,
)


@dataclass
class RunResult:
    item: str
    threads: int
    tps: float


def parse_log(text: str) -> List[RunResult]:
    results: List[RunResult] = []
    pending: Key | None = None

    for line in text.splitlines():
        m_cmd = CMD_RE.search(line)
        if m_cmd:
            pending = (m_cmd.group(1), int(m_cmd.group(2)))
            continue

        if pending is None:
            continue

        m_tps = TPS_RE.search(line)
        if m_tps:
            results.append(
                RunResult(pending[0], pending[1], float(m_tps.group(1)))
            )
            pending = None

    return results


def to_map(runs: List[RunResult]) -> Dict[Key, float]:
    m: Dict[Key, float] = {}
    for r in runs:
        m[(r.item, r.threads)] = r.tps
    return m


def format_report(
    current: Dict[Key, float],
    baseline: Dict[Key, float],
    threshold_pct: float,
) -> str:
    keys = sorted(set(current) | set(baseline))
    lines = [
        "| 测试项 | 并发 | 当前 TPS | 标准 TPS | 差异 | 判定 |",
        "|--------|------|----------|----------|------|------|",
    ]

    for item, threads in keys:
        cur = current.get((item, threads))
        base = baseline.get((item, threads))
        if cur is None:
            lines.append(
                f"| {item} | {threads} | - | {base:.2f} | - | 缺少当前结果 |"
            )
            continue
        if base is None:
            lines.append(
                f"| {item} | {threads} | {cur:.2f} | - | - | 缺少标准值 |"
            )
            continue

        diff_pct = (cur - base) / base * 100.0 if base else 0.0
        if abs(diff_pct) <= threshold_pct:
            verdict = "通过"
        elif diff_pct > 0:
            verdict = f"高于标准 {diff_pct:+.2f}%"
        else:
            verdict = f"低于标准 {diff_pct:+.2f}%"

        lines.append(
            f"| {item} | {threads} | {cur:.2f} | {base:.2f} | {diff_pct:+.2f}% | {verdict} |"
        )

    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "current_log",
        type=Path,
        help="本次 localhost_run.sh 的输出日志（可用 tee 保存）",
    )
    ap.add_argument(
        "--baseline",
        type=Path,
        required=True,
        help="标准 TPS 日志（历史 base/perf 的 *-base.txt、*-perf.txt 等）",
    )
    ap.add_argument(
        "--threshold",
        type=float,
        default=3.0,
        help="判定通过的相对误差阈值（%%），默认 3",
    )
    args = ap.parse_args()

    cur_text = args.current_log.read_text(encoding="utf-8", errors="replace")
    base_text = args.baseline.read_text(encoding="utf-8", errors="replace")

    cur_runs = parse_log(cur_text)
    base_runs = parse_log(base_text)

    if not cur_runs:
        print("未从当前日志解析到 TPS，请确认日志包含 sysbench run 与 transactions 行。", file=sys.stderr)
        return 1

    print("## 当前运行 TPS\n")
    for r in cur_runs:
        print(f"- {r.item} @ threads={r.threads}: **{r.tps:.2f}** tps")

    print("\n## 与标准值对比\n")
    print(
        format_report(
            to_map(cur_runs),
            to_map(base_runs),
            args.threshold,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
