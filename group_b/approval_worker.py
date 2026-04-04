"""
group_b/approval_worker.py — ALMA Approval Worker

LISTENs on the 'alma_approval' pg_notify channel.
For each incoming approval_request:
  - In AUTOMATED mode (APPROVAL_TIMEOUT_SECONDS=0): auto-deny immediately.
  - In INTERACTIVE mode: print to stdout and wait for human input.
  - In TIMED mode: approve by default after timeout (configurable).

This worker runs as a separate process alongside the Group B agent.
"""

from __future__ import annotations

import json
import logging
import os
import select
import sys
import threading
import time

import psycopg2
import psycopg2.extras
from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [approval_worker] %(levelname)s %(message)s"
)
log = logging.getLogger(__name__)

DATABASE_URL     = os.environ["DATABASE_URL"]
APPROVAL_TIMEOUT = int(os.environ.get("APPROVAL_TIMEOUT_SECONDS", "0"))
APPROVAL_MODE    = os.environ.get("APPROVAL_MODE", "auto_deny")  # auto_deny | auto_approve | interactive


def get_conn(autocommit: bool = True):
    conn = psycopg2.connect(DATABASE_URL)
    conn.autocommit = autocommit
    return conn


def resolve_approval(approval_id: str, decision: str):
    conn = get_conn(autocommit=True)
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT alma.resolve_approval(%s, %s)", (approval_id, decision))
        log.info("Resolved approval_id=%s decision=%s", approval_id, decision)
    finally:
        conn.close()


def handle_approval_request(payload: dict):
    approval_id = payload.get("approval_id")
    task_id     = payload.get("task_id")
    sql_text    = payload.get("sql_text", "")

    log.warning(
        "APPROVAL REQUIRED | approval_id=%s | task_id=%s | SQL: %s",
        approval_id, task_id, sql_text
    )

    if APPROVAL_MODE == "auto_deny" or APPROVAL_TIMEOUT == 0:
        log.info("Auto-denying (APPROVAL_MODE=auto_deny or APPROVAL_TIMEOUT=0)")
        resolve_approval(approval_id, "timeout")
        return

    if APPROVAL_MODE == "auto_approve":
        if APPROVAL_TIMEOUT > 0:
            log.info("Waiting %ds before auto-approving...", APPROVAL_TIMEOUT)
            time.sleep(APPROVAL_TIMEOUT)
        log.info("Auto-approving approval_id=%s", approval_id)
        resolve_approval(approval_id, "approved")
        return

    if APPROVAL_MODE == "interactive":
        print(f"\n{'='*60}")
        print(f"APPROVAL REQUIRED")
        print(f"approval_id : {approval_id}")
        print(f"task_id     : {task_id}")
        print(f"SQL         : {sql_text}")
        print(f"{'='*60}")

        def _ask():
            while True:
                answer = input("Approve? [y/n] (timeout in 30s): ").strip().lower()
                if answer in ("y", "yes"):
                    resolve_approval(approval_id, "approved")
                    return
                elif answer in ("n", "no"):
                    resolve_approval(approval_id, "denied")
                    return
                print("Please enter y or n.")

        t = threading.Thread(target=_ask, daemon=True)
        t.start()
        t.join(timeout=30)
        if t.is_alive():
            log.warning("Interactive approval timed out, denying.")
            resolve_approval(approval_id, "timeout")


def run():
    log.info(
        "Approval worker starting | mode=%s timeout=%ds",
        APPROVAL_MODE, APPROVAL_TIMEOUT
    )

    conn = get_conn(autocommit=True)
    try:
        with conn.cursor() as cur:
            cur.execute("LISTEN alma_approval")
        log.info("Listening on channel 'alma_approval'...")

        while True:
            # Poll with 5s timeout so we don't busy-loop
            ready = select.select([conn], [], [], 5.0)[0]
            if ready:
                conn.poll()
                while conn.notifies:
                    notify = conn.notifies.pop(0)
                    try:
                        payload = json.loads(notify.payload)
                        if payload.get("event") == "new_request":
                            # Spawn a thread so we don't block the LISTEN loop
                            t = threading.Thread(
                                target=handle_approval_request,
                                args=(payload,),
                                daemon=True,
                            )
                            t.start()
                    except json.JSONDecodeError:
                        log.error("Invalid JSON payload: %s", notify.payload)
    except KeyboardInterrupt:
        log.info("Approval worker shutting down.")
    finally:
        conn.close()


if __name__ == "__main__":
    run()
