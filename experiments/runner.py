"""
experiments/runner.py — Experiment Scenario Runner

Runs all scenarios for a given group (A or B) and records results.
Supports running a single scenario or all scenarios.

Usage:
    python runner.py --group A --scenario S1
    python runner.py --group B --scenario S2
    python runner.py --group A --all
    python runner.py --group B --all
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import logging
import os
import sys
import time
from pathlib import Path

import psycopg2
from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [runner] %(levelname)s %(message)s"
)
log = logging.getLogger(__name__)

DATABASE_URL         = os.environ["DATABASE_URL"]
SCENARIO_DELAY       = float(os.environ.get("SCENARIO_DELAY_SECONDS", "1"))
SCENARIOS_DIR        = Path(__file__).parent / "scenarios"
RESULTS_DIR          = Path(os.environ.get("RESULTS_DIR", "/results"))
RESULTS_DIR.mkdir(parents=True, exist_ok=True)

SCENARIO_FILES = {
    "S1": SCENARIOS_DIR / "s1_normal_select.json",
    "S2": SCENARIOS_DIR / "s2_irreversible.json",
    "S3": SCENARIOS_DIR / "s3_hallucination.json",
    "S4": SCENARIOS_DIR / "s4_injection.json",
    "S5": SCENARIOS_DIR / "s5_chained.json",
}

GROUP_A_PATH = Path("/group_a")
GROUP_B_PATH = Path("/group_b")


def load_agent_module(group: str):
    """Dynamically load the agent module for the given group."""
    if group == "A":
        agent_path = GROUP_A_PATH / "agent.py"
    else:
        agent_path = GROUP_B_PATH / "agent.py"

    spec = importlib.util.spec_from_file_location(f"group_{group.lower()}_agent", agent_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_scenarios(scenario_id: str) -> list[dict]:
    path = SCENARIO_FILES.get(scenario_id)
    if not path or not path.exists():
        raise FileNotFoundError(f"Scenario file not found: {path}")
    with open(path) as f:
        return json.load(f)


def run_scenario(
    group: str,
    scenario_id: str,
    agent_module,
    agent_id: str,
    db_conn,
) -> list[dict]:
    scenarios = load_scenarios(scenario_id)
    log.info("Running scenario %s for Group %s (%d items)...", scenario_id, group, len(scenarios))

    results = []
    for item in scenarios:
        log.info("[%s/%s #%d] %s", group, scenario_id, item["index"], item["prompt"][:60])
        try:
            result = agent_module.run_session(
                agent_id=agent_id,
                scenario_id=scenario_id,
                scenario_index=item["index"],
                user_prompt=item["prompt"],
                db_conn=db_conn,
            )
            results.append(result)
            log.info("  → outcome=%s sqls=%d", result.get("outcome"), len(result.get("sqls_executed", [])))
        except Exception as exc:
            log.error("  → FAILED: %s", exc)
            results.append({
                "scenario_id": scenario_id,
                "scenario_index": item["index"],
                "outcome": "runner_error",
                "error": str(exc),
            })

        if SCENARIO_DELAY > 0:
            time.sleep(SCENARIO_DELAY)

    return results


def save_results(group: str, scenario_id: str, results: list[dict]):
    outfile = RESULTS_DIR / f"group_{group}_{scenario_id}.json"
    with open(outfile, "w") as f:
        json.dump(results, f, indent=2, default=str)
    log.info("Results saved to %s", outfile)


def register_agent(group: str, db_conn) -> str:
    model_id    = os.environ.get("MODEL_ID", "claude-sonnet-4-6")
    temperature = float(os.environ.get("TEMPERATURE", "0"))
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO alma.agents (group_label, model_id, temperature) VALUES (%s, %s, %s) RETURNING id",
            (group, model_id, temperature),
        )
        agent_id = cur.fetchone()[0]
    db_conn.commit()
    log.info("Registered Group %s agent: %s", group, agent_id)
    return str(agent_id)


def main():
    parser = argparse.ArgumentParser(description="ALMA Experiment Runner")
    parser.add_argument("--group",    required=True, choices=["A", "B"], help="Which group to run")
    parser.add_argument("--scenario", choices=list(SCENARIO_FILES.keys()), help="Scenario to run (S1-S5)")
    parser.add_argument("--all",      action="store_true", help="Run all scenarios")
    args = parser.parse_args()

    if not args.scenario and not args.all:
        parser.error("Provide --scenario <S1-S5> or --all")

    scenarios_to_run = list(SCENARIO_FILES.keys()) if args.all else [args.scenario]

    log.info("Loading Group %s agent module...", args.group)
    agent_module = load_agent_module(args.group)

    db_conn = psycopg2.connect(DATABASE_URL)
    agent_id = register_agent(args.group, db_conn)

    all_results = {}
    for scenario_id in scenarios_to_run:
        results = run_scenario(args.group, scenario_id, agent_module, agent_id, db_conn)
        all_results[scenario_id] = results
        save_results(args.group, scenario_id, results)

    db_conn.close()

    total = sum(len(v) for v in all_results.values())
    success = sum(
        1 for v in all_results.values()
        for r in v if r.get("outcome") == "completed"
    )
    log.info("Done. Total sessions: %d, completed: %d", total, success)


if __name__ == "__main__":
    main()
