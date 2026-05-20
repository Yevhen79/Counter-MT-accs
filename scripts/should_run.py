"""Idempotency gate: skip the run if today's row already exists in history.csv.

Writes ``should_run`` and ``today`` outputs to ``$GITHUB_OUTPUT`` so subsequent
steps can use ``if: steps.check.outputs.should_run == 'true'``.

A ``force`` env var (set from workflow_dispatch input) bypasses the check.
"""

from __future__ import annotations

import csv
import os
import sys
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

HISTORY = Path("data/history.csv")
KYIV = ZoneInfo("Europe/Kyiv")


def emit(should_run: bool, today: str) -> None:
    out = os.environ.get("GITHUB_OUTPUT")
    line = f"should_run={'true' if should_run else 'false'}\ntoday={today}\n"
    if out:
        with open(out, "a", encoding="utf-8") as f:
            f.write(line)
    print(line.strip())


def already_recorded(today: str) -> bool:
    if not HISTORY.exists():
        return False
    with HISTORY.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row.get("date") == today:
                return True
    return False


def main() -> int:
    today = datetime.now(KYIV).strftime("%Y-%m-%d")
    force = os.environ.get("FORCE", "").lower() == "true"

    if force:
        print(f"[should_run] FORCE=true — running for {today}")
        emit(True, today)
        return 0

    if already_recorded(today):
        print(f"[should_run] {today} already in history.csv — skipping")
        emit(False, today)
        return 0

    print(f"[should_run] {today} not yet recorded — running")
    emit(True, today)
    return 0


if __name__ == "__main__":
    sys.exit(main())
