"""
group_a/mcp_server.py — Group A: Claude + MCP Baseline

Exposes a single MCP-style tool: sql_execute(sql)
  - No transaction boundary
  - No SQL classification
  - No irreversibility check
  - Executes immediately with autocommit=True

This is the baseline that demonstrates unguarded LLM→SQL execution.
Results are logged to alma.execution_logs for comparison with Group B.
"""

from __future__ import annotations

import json
import logging
import os
import time
from contextlib import asynccontextmanager
from typing import Any

import psycopg2
import psycopg2.extras
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO, format="%(asctime)s [group_a] %(levelname)s %(message)s")
log = logging.getLogger(__name__)

DATABASE_URL = os.environ["DATABASE_URL"]


def get_conn(autocommit: bool = True):
    conn = psycopg2.connect(DATABASE_URL)
    conn.autocommit = autocommit
    return conn


# ── FastAPI app (acts as the MCP tool server) ────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("Group A MCP server starting. Checking DB connection...")
    conn = get_conn()
    conn.close()
    log.info("DB connection OK.")
    yield


app = FastAPI(title="Group A MCP Server", lifespan=lifespan)


class SqlExecuteRequest(BaseModel):
    sql: str
    task_id: str | None = None
    session_id: str | None = None


class SqlExecuteResponse(BaseModel):
    outcome: str           # success | error
    rows: list[Any] | None = None
    columns: list[str] | None = None
    error: str | None = None
    duration_ms: int | None = None
    rowcount: int | None = None


@app.post("/tools/sql_execute", response_model=SqlExecuteResponse)
def sql_execute(req: SqlExecuteRequest) -> SqlExecuteResponse:
    """
    MCP tool: sql_execute
    Executes the given SQL directly against the database.
    No transaction boundary. No irreversibility check.
    This is the Group A (unguarded) behavior.
    """
    log.info("sql_execute called | sql=%s", req.sql[:120])
    conn = get_conn(autocommit=True)
    start = time.time()

    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(req.sql)
            duration_ms = int((time.time() - start) * 1000)

            rows = None
            columns = None
            rowcount = cur.rowcount

            if cur.description:
                columns = [d.name for d in cur.description]
                rows = [dict(r) for r in cur.fetchall()]

            # Log to alma.execution_logs if context is provided
            if req.task_id and req.session_id:
                _log_outcome(
                    conn, req.task_id, req.session_id, "A",
                    req.sql, "success", None, duration_ms
                )

            log.info("sql_execute OK | duration_ms=%d rowcount=%d", duration_ms, rowcount)
            return SqlExecuteResponse(
                outcome="success",
                rows=rows,
                columns=columns,
                duration_ms=duration_ms,
                rowcount=rowcount,
            )

    except Exception as exc:
        duration_ms = int((time.time() - start) * 1000)
        log.error("sql_execute ERROR | %s", exc)

        if req.task_id and req.session_id:
            _log_outcome(
                conn, req.task_id, req.session_id, "A",
                req.sql, "error", str(exc), duration_ms
            )

        return SqlExecuteResponse(
            outcome="error",
            error=str(exc),
            duration_ms=duration_ms,
        )
    finally:
        conn.close()


def _log_outcome(
    conn,
    task_id: str,
    session_id: str,
    group_label: str,
    sql_text: str,
    outcome: str,
    error_message: str | None,
    duration_ms: int,
):
    """Write to alma.execution_logs using a separate connection (autocommit)."""
    log_conn = get_conn(autocommit=True)
    try:
        with log_conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO alma.execution_logs
                    (task_id, session_id, group_label, sql_text, outcome, error_message, duration_ms)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                """,
                (task_id, session_id, group_label, sql_text, outcome, error_message, duration_ms),
            )
    finally:
        log_conn.close()


@app.get("/health")
def health():
    return {"status": "ok", "group": "A"}


if __name__ == "__main__":
    uvicorn.run("mcp_server:app", host="0.0.0.0", port=8000, log_level="info")
