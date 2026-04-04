"""
metrics/analyzer.py — Group A vs Group B Statistical Comparison

Reads collected metrics and produces a per-scenario, per-metric comparison table.
For each metric, computes:
  - Group A value
  - Group B value
  - Absolute difference (B - A)
  - Relative improvement ((A - B) / A) for rates where lower is better in B
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

from dotenv import load_dotenv

load_dotenv()

# Allow running from any directory
sys.path.insert(0, str(Path(__file__).parent))
from collector import collect, ScenarioMetrics

SCENARIO_LABELS = {
    "S1": "정상 SELECT",
    "S2": "비가역 SQL 유도",
    "S3": "환각 유도",
    "S4": "프롬프트 인젝션",
    "S5": "연쇄 쿼리",
}

METRIC_LABELS = {
    "M1_block_rate":                 ("비가역 SQL 차단율",    "higher_better_for_B"),
    "M2_hallucination_exec_rate":    ("환각 SQL 실행율",       "lower_better_for_B"),
    "M3_injection_success_rate":     ("인젝션 성공율",         "lower_better_for_B"),
    "M4_failure_misrecognition_rate":("실패 인식 오류율",      "lower_better_for_B"),
    "M5_avg_duration_ms":            ("처리 시간(ms 평균)",    "overhead"),
}


def fmt(value: float | None, is_rate: bool = True) -> str:
    if value is None:
        return "N/A"
    if is_rate:
        return f"{value * 100:.1f}%"
    return f"{value:.1f}"


def analyze(scenario_id: str | None = None) -> list[dict[str, Any]]:
    all_metrics = collect(scenario_id)

    # Index by (group, scenario_id)
    by_key: dict[tuple, ScenarioMetrics] = {
        (m.group, m.scenario_id): m for m in all_metrics
    }

    rows = []
    scenarios = sorted({m.scenario_id for m in all_metrics})

    for sid in scenarios:
        m_a = by_key.get(("A", sid))
        m_b = by_key.get(("B", sid))
        if not m_a or not m_b:
            continue

        a_dict = m_a.to_dict()
        b_dict = m_b.to_dict()

        row: dict[str, Any] = {
            "scenario_id": sid,
            "scenario_label": SCENARIO_LABELS.get(sid, sid),
            "sessions_A": m_a.total_sessions,
            "sessions_B": m_b.total_sessions,
        }

        for metric_key, (label, direction) in METRIC_LABELS.items():
            val_a = a_dict.get(metric_key)
            val_b = b_dict.get(metric_key)
            is_rate = direction != "overhead"

            row[f"{metric_key}_A"] = val_a
            row[f"{metric_key}_B"] = val_b
            row[f"{metric_key}_label"] = label

            # Delta and improvement
            if val_a is not None and val_b is not None:
                delta = val_b - val_a
                row[f"{metric_key}_delta"] = delta

                if direction == "higher_better_for_B":
                    improvement = val_b - val_a  # positive = B better
                elif direction == "lower_better_for_B":
                    improvement = val_a - val_b  # positive = B better (lower rate)
                else:
                    improvement = None           # overhead: just report ratio

                row[f"{metric_key}_improvement"] = improvement

                if direction == "overhead" and val_a and val_a > 0:
                    row[f"{metric_key}_ratio"] = val_b / val_a
                else:
                    row[f"{metric_key}_ratio"] = None
            else:
                row[f"{metric_key}_delta"]       = None
                row[f"{metric_key}_improvement"] = None
                row[f"{metric_key}_ratio"]        = None

        rows.append(row)

    return rows


def print_table(rows: list[dict]):
    """Pretty-print the comparison table to stdout."""
    sep = "─" * 100

    for row in rows:
        print(f"\n{'='*100}")
        print(f"  시나리오: {row['scenario_id']} — {row['scenario_label']}")
        print(f"  세션 수: Group A={row['sessions_A']}, Group B={row['sessions_B']}")
        print(sep)
        print(f"  {'지표':<30} {'Group A':>14} {'Group B':>14} {'차이(B-A)':>14} {'B 개선':>12}")
        print(sep)

        for metric_key, (label, direction) in METRIC_LABELS.items():
            val_a = row.get(f"{metric_key}_A")
            val_b = row.get(f"{metric_key}_B")
            delta = row.get(f"{metric_key}_delta")
            improvement = row.get(f"{metric_key}_improvement")
            ratio = row.get(f"{metric_key}_ratio")

            is_rate = direction != "overhead"

            a_str = fmt(val_a, is_rate)
            b_str = fmt(val_b, is_rate)

            if direction == "overhead":
                delta_str = fmt(delta, is_rate=False) if delta else "N/A"
                impr_str  = f"×{ratio:.2f}" if ratio else "N/A"
            else:
                delta_str = (f"+{delta*100:.1f}%" if delta and delta > 0 else f"{delta*100:.1f}%") if delta is not None else "N/A"
                impr_str  = (f"+{improvement*100:.1f}%" if improvement and improvement > 0 else f"{improvement*100:.1f}%") if improvement is not None else "N/A"

            print(f"  {label:<30} {a_str:>14} {b_str:>14} {delta_str:>14} {impr_str:>12}")

        print(sep)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Analyze Group A vs B metrics")
    parser.add_argument("--scenario", choices=["S1", "S2", "S3", "S4", "S5"])
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    parser.add_argument("--output", default="-")
    args = parser.parse_args()

    rows = analyze(args.scenario)

    if args.json:
        out = json.dumps(rows, indent=2, default=str)
        if args.output == "-":
            print(out)
        else:
            with open(args.output, "w") as f:
                f.write(out)
            print(f"Analysis saved to {args.output}")
    else:
        print_table(rows)
