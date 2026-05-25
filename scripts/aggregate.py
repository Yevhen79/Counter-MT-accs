"""Combine per-platform result JSONs into one row in data/history.csv and
also mirror the CSV under docs/ so GitHub Pages can serve it.

If a count is missing for any account, ``ERR`` is written into the cell so
the row is still appended and the dashboard shows the gap.
"""

from __future__ import annotations

import csv
import json
import shutil
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

import yaml

try:
    from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
    try:
        KYIV: object = ZoneInfo("Europe/Kyiv")
    except ZoneInfoNotFoundError:
        print("[aggregate] tzdata not present; falling back to fixed UTC+3", file=sys.stderr)
        KYIV = timezone(timedelta(hours=3))
except ImportError:
    KYIV = timezone(timedelta(hours=3))

ARTIFACT_FILES = [
    Path("artifacts/mt5_results.json"),
    Path("artifacts/mt4_results.json"),
]
HISTORY = Path("data/history.csv")
DOCS_COPY = Path("docs/history.csv")
DEBUG_DIR = Path("data/last-run")


def collect_results() -> dict[str, dict]:
    results: dict[str, dict] = {}
    for p in ARTIFACT_FILES:
        if not p.exists():
            print(f"[aggregate] missing {p} — treating as no data")
            continue
        try:
            data = json.loads(p.read_text(encoding="utf-8") or "[]")
        except json.JSONDecodeError as e:
            print(f"[aggregate] {p} JSON parse error: {e}")
            continue
        if not isinstance(data, list):
            data = [data]
        for r in data:
            if isinstance(r, dict) and "label" in r:
                results[r["label"]] = r
    return results


def main() -> int:
    with open("config.yaml", encoding="utf-8") as f:
        config = yaml.safe_load(f)
    labels = [a["label"] for a in config["accounts"]]

    today = datetime.now(KYIV).strftime("%Y-%m-%d")
    results = collect_results()

    # Both platforms now report "full" = symbols with SYMBOL_TRADE_MODE_FULL
    # (CLOSEONLY and DISABLED excluded), so the metric is consistent across
    # MT4 and MT5.
    row: dict[str, str] = {"date": today}
    for lbl in labels:
        r = results.get(lbl, {})
        if "full" in r:
            row[lbl] = str(r["full"])
        else:
            row[lbl] = "ERR"

    print(f"[aggregate] row for {today}: {row}")

    HISTORY.parent.mkdir(parents=True, exist_ok=True)
    DOCS_COPY.parent.mkdir(parents=True, exist_ok=True)

    fieldnames = ["date"] + labels

    rows: list[dict] = []
    if HISTORY.exists():
        with HISTORY.open(newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            for existing in reader:
                if existing.get("date") == today:
                    continue  # we'll overwrite today's row
                rows.append(existing)
    rows.append(row)

    for path in (HISTORY, DOCS_COPY):
        with path.open("w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            for r in rows:
                writer.writerow({k: r.get(k, "") for k in fieldnames})
        print(f"[aggregate] wrote {path}")

    # Detailed per-account breakdown of the latest run for the dashboard
    # table (Account | Total | FULL | CLOSEONLY | DISABLED). Numbers for
    # every account, no dashes.
    def num(r: dict, key: str):
        v = r.get(key)
        return v if isinstance(v, int) else (int(v) if str(v).isdigit() else None)

    breakdown = []
    for acc in config["accounts"]:
        lbl = acc["label"]
        r = results.get(lbl, {})
        breakdown.append({
            "label": lbl,
            "platform": acc["platform"],
            "account": str(r.get("account", acc.get("login", ""))),
            "total": num(r, "total"),
            "full": num(r, "full"),
            "closeonly": num(r, "closeonly"),
            "disabled": num(r, "disabled"),
            "error": r.get("error"),
        })
    latest = {"date": today, "accounts": breakdown}
    for path in (Path("data/latest.json"), Path("docs/latest.json")):
        path.write_text(json.dumps(latest, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"[aggregate] wrote {path}")

    # Mirror per-platform raw results AND captured stdout logs next to
    # history.csv so they get committed too. Lets us read per-account error
    # messages plus full script output via the GitHub API, no auth-gated
    # Actions log download required.
    DEBUG_DIR.mkdir(parents=True, exist_ok=True)
    debug_sources = [
        *ARTIFACT_FILES,
        Path("artifacts/count_mt5_log.txt"),
        Path("artifacts/install_mt4_log.txt"),
        Path("artifacts/count_mt4_log.txt"),
    ]
    for src in debug_sources:
        dst = DEBUG_DIR / src.name
        if src.exists():
            shutil.copy(src, dst)
            print(f"[aggregate] copied {src} -> {dst}")
        else:
            placeholder = "[]\n" if src.suffix == ".json" else f"(no {src.name} produced)\n"
            dst.write_text(placeholder, encoding="utf-8")
            print(f"[aggregate] {src} missing — wrote placeholder to {dst}")

    # Per-symbol breakdown lists (variable filenames mt5_symbols_*.csv etc.).
    for src in Path("artifacts").glob("*_symbols_*.csv"):
        dst = DEBUG_DIR / src.name
        shutil.copy(src, dst)
        print(f"[aggregate] copied {src} -> {dst}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
