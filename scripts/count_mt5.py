"""Count tradeable instruments on each MT5 account configured in config.yaml.

Uses the official ``MetaTrader5`` Python package which launches and drives the
already-installed MT5 terminal headlessly. For each MT5 account we log in,
enumerate symbols, count those with ``SYMBOL_TRADE_MODE_FULL``, and write the
results to ``artifacts/mt5_results.json``.

Passwords are read from environment variables whose names come from each
account's ``password_secret`` field in config.yaml. Logins and server names
come from config.yaml directly.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import MetaTrader5 as mt5
import yaml

ARTIFACT = Path("artifacts/mt5_results.json")
TERMINAL_PATH = r"C:\Program Files\MetaTrader 5\terminal64.exe"


def count_account(label: str, login: int, password: str, server: str) -> dict:
    print(f"[mt5] === {label} (login={login}, server={server!r}) ===")

    ok = mt5.initialize(
        path=TERMINAL_PATH,
        login=login,
        password=password,
        server=server,
        timeout=60_000,
    )
    if not ok:
        err = mt5.last_error()
        print(f"[mt5] initialize failed: {err}")
        mt5.shutdown()
        return {"label": label, "error": f"initialize_failed: {err}"}

    info = mt5.account_info()
    if info is None:
        err = mt5.last_error()
        print(f"[mt5] account_info None: {err}")
        mt5.shutdown()
        return {"label": label, "error": f"account_info_none: {err}"}
    print(f"[mt5] logged in as {info.login} on {info.server} ({info.company})")

    symbols = mt5.symbols_get()
    if symbols is None:
        err = mt5.last_error()
        print(f"[mt5] symbols_get None: {err}")
        mt5.shutdown()
        return {"label": label, "error": f"symbols_get_none: {err}"}

    full = sum(1 for s in symbols if s.trade_mode == mt5.SYMBOL_TRADE_MODE_FULL)
    total = len(symbols)
    print(f"[mt5] {label}: full={full} total={total}")

    mt5.shutdown()
    return {"label": label, "full": full, "total": total, "server": server}


def main() -> int:
    with open("config.yaml", encoding="utf-8") as f:
        config = yaml.safe_load(f)

    results = []
    for acc in config["accounts"]:
        if acc["platform"] != "mt5":
            continue
        label = acc["label"]
        password = os.environ.get(acc["password_secret"], "")
        if not password:
            print(f"[mt5] {label}: no password in env var {acc['password_secret']}, skipping")
            results.append({"label": label, "error": "no_password_secret"})
            continue

        try:
            results.append(count_account(label, int(acc["login"]), password, acc["server"]))
        except Exception as e:
            print(f"[mt5] {label}: exception {e!r}")
            results.append({"label": label, "error": f"exception: {e!r}"})

    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    with ARTIFACT.open("w", encoding="utf-8") as f:
        json.dump(results, f, indent=2, ensure_ascii=False)
    print(f"[mt5] wrote {ARTIFACT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
