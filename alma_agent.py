#!/usr/bin/env python3
"""
alma_agent.py — ALMA Python client

All agent logic lives inside PostgreSQL (run_agent / run_multi_agent).
This script is the minimal Python entry point: connect → call → print.

Usage:
    # Single agent
    DB_USER=agent_sql DB_PASSWORD=secret python3 alma_agent.py \
        --agent agent_sql --task "show me all tables in this database"

    # Multi-agent (orchestrator)
    DB_USER=agent_orchestrator DB_PASSWORD=secret python3 alma_agent.py \
        --multi --agent agent_orchestrator --task "analyse sales for Q1 2024"

Environment variables:
    DB_HOST      PostgreSQL host (default: localhost)
    DB_PORT      PostgreSQL port (default: 5432)
    DB_NAME      Database name   (default: alma)
    DB_USER      Login role name (becomes the agent identity)
    DB_PASSWORD  Role password
"""

import argparse
import os
import sys
import psycopg2
import psycopg2.extras


def get_connection() -> psycopg2.extensions.connection:
    return psycopg2.connect(
        host     = os.environ.get("DB_HOST",     "localhost"),
        port     = int(os.environ.get("DB_PORT", "5432")),
        dbname   = os.environ.get("DB_NAME",     "alma"),
        user     = os.environ.get("DB_USER"),
        password = os.environ.get("DB_PASSWORD"),
    )


def run_agent(agent_role: str, task: str) -> str:
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT alma_public.run_agent(%s, %s)",
                (agent_role, task),
            )
            result = cur.fetchone()[0]
    return result


def run_multi_agent(orchestrator_role: str, goal: str) -> str:
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT alma_public.run_multi_agent(%s, %s)",
                (orchestrator_role, goal),
            )
            result = cur.fetchone()[0]
    return result


def list_agents(active_only: bool = True) -> list[dict]:
    with get_connection() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("SELECT * FROM alma_public.list_agents(%s)", (active_only,))
            return cur.fetchall()


def list_sessions(agent_role: str = None, limit: int = 20) -> list[dict]:
    with get_connection() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                "SELECT * FROM alma_public.list_sessions(%s, %s)",
                (agent_role, limit),
            )
            return cur.fetchall()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="ALMA Python client — calls run_agent() in PostgreSQL"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # run subcommand
    run_parser = subparsers.add_parser("run", help="Run a single agent")
    run_parser.add_argument("--agent",  required=True, help="Agent role name")
    run_parser.add_argument("--task",   required=True, help="Task prompt")

    # multi subcommand
    multi_parser = subparsers.add_parser("multi", help="Run multi-agent (orchestrator)")
    multi_parser.add_argument("--agent", required=True, help="Orchestrator role name")
    multi_parser.add_argument("--task",  required=True, help="Goal prompt")

    # agents subcommand
    agents_parser = subparsers.add_parser("agents", help="List registered agents")
    agents_parser.add_argument("--all", action="store_true", help="Include inactive agents")

    # sessions subcommand
    sessions_parser = subparsers.add_parser("sessions", help="List recent sessions")
    sessions_parser.add_argument("--agent", default=None, help="Filter by agent role")
    sessions_parser.add_argument("--limit", type=int, default=20)

    args = parser.parse_args()

    if not os.environ.get("DB_USER"):
        print("ERROR: DB_USER environment variable is required", file=sys.stderr)
        sys.exit(1)

    if args.command == "run":
        result = run_agent(args.agent, args.task)
        print(result)

    elif args.command == "multi":
        result = run_multi_agent(args.agent, args.task)
        print(result)

    elif args.command == "agents":
        agents = list_agents(active_only=not args.all)
        if not agents:
            print("No agents found.")
        else:
            print(f"{'role_name':<30} {'display_name':<30} {'role':<15} {'provider':<12} {'model'}")
            print("-" * 100)
            for a in agents:
                print(
                    f"{a['role_name']:<30} {a['display_name']:<30} "
                    f"{a['agent_role']:<15} {a['llm_provider'] or '':<12} {a['model_name']}"
                )

    elif args.command == "sessions":
        sessions = list_sessions(args.agent, args.limit)
        if not sessions:
            print("No sessions found.")
        else:
            print(f"{'session_id':<38} {'agent':<20} {'status':<12} {'steps':<7} {'started_at'}")
            print("-" * 100)
            for s in sessions:
                print(
                    f"{str(s['session_id']):<38} {s['agent_role']:<20} "
                    f"{s['status']:<12} {s['total_steps']:<7} {s['started_at']}"
                )


if __name__ == "__main__":
    main()
