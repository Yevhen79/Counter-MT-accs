"""Count tradeable instruments on each MT5 account configured in config.yaml.

Strategy:
  1. mt5.initialize(path=...) once to launch and warm up terminal64.exe (no
     account, just bring the process up). This separates "terminal cold-start"
     from "broker login" so IPC timeouts point to the right culprit.
  2. For each MT5 account in config.yaml call mt5.login(login=..., password=...,
     server=...). On success enumerate symbols and count SYMBOL_TRADE_MODE_FULL.
  3. mt5.shutdown() once at the very end.

Per-account passwords come from environment variables whose names live in each
account's ``password_secret`` field in config.yaml. Logins and server names
come from config.yaml directly.
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

import MetaTrader5 as mt5
import yaml

ARTIFACT = Path("artifacts/mt5_results.json")
TERMINAL_PATH = r"C:\Program Files\MetaTrader 5\terminal64.exe"
INIT_TIMEOUT_MS = 120_000
LOGIN_TIMEOUT_MS = 120_000


def err_dict(label: str, stage: str) -> dict:
    return {"label": label, "error": f"{stage}: {mt5.last_error()}"}


def count_account(label: str, login: int, password: str, server: str) -> dict:
    print(f"[mt5] === {label} (login={login}, server={server!r}) ===")
    if not mt5.login(login=login, password=password, server=server, timeout=LOGIN_TIMEOUT_MS):
        err = mt5.last_error()
        print(f"[mt5] login failed: {err}")
        return {"label": label, "error": f"login_failed: {err}"}

    info = mt5.account_info()
    if info is None:
        print(f"[mt5] account_info() returned None after login: {mt5.last_error()}")
        return err_dict(label, "account_info_none")
    print(f"[mt5] logged in as {info.login} on {info.server} ({info.company}); balance={info.balance} {info.currency}")

    symbols = mt5.symbols_get()
    if symbols is None:
        print(f"[mt5] symbols_get returned None: {mt5.last_error()}")
        return err_dict(label, "symbols_get_none")

    full = sum(1 for s in symbols if s.trade_mode == mt5.SYMBOL_TRADE_MODE_FULL)
    total = len(symbols)
    print(f"[mt5] {label}: full={full} total={total}")
    return {"label": label, "full": full, "total": total, "server": server}


def main() -> int:
    with open("config.yaml", encoding="utf-8") as f:
        config = yaml.safe_load(f)
    mt5_accounts = [a for a in config["accounts"] if a["platform"] == "mt5"]

    if not Path(TERMINAL_PATH).exists():
        print(f"[mt5] terminal not found at {TERMINAL_PATH} — was the install step skipped?")
        results = [{"label": a["label"], "error": "terminal_missing"} for a in mt5_accounts]
        ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
        ARTIFACT.write_text(json.dumps(results, indent=2, ensure_ascii=False), encoding="utf-8")
        return 0

    # Warm the terminal up without logging in. Gives it the full timeout to
    # complete its first-run setup before we ask it to authenticate.
    print(f"[mt5] launching {TERMINAL_PATH} (timeout {INIT_TIMEOUT_MS/1000:.0f}s)...")
    t0 = time.time()
    if not mt5.initialize(path=TERMINAL_PATH, timeout=INIT_TIMEOUT_MS):
        err = mt5.last_error()
        print(f"[mt5] terminal initialize failed: {err}")
        mt5.shutdown()
        results = [{"label": a["label"], "error": f"terminal_init_failed: {err}"} for a in mt5_accounts]
        ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
        ARTIFACT.write_text(json.dumps(results, indent=2, ensure_ascii=False), encoding="utf-8")
        return 0
    print(f"[mt5] terminal up after {time.time()-t0:.1f}s")

    term_info = mt5.terminal_info()
    if term_info is not None:
        print(f"[mt5] terminal_info: build={term_info.build} community={term_info.community_connection} "
              f"connected={term_info.connected} data_path={term_info.data_path}")

    results = []
    for acc in mt5_accounts:
        label = acc["label"]
        password = os.environ.get(acc["password_secret"], "")
        if not password:
            print(f"[mt5] {label}: env var {acc['password_secret']} is empty — secret missing or empty value")
            results.append({"label": label, "error": "no_password_secret"})
            continue
        try:
            results.append(count_account(label, int(acc["login"]), password, acc["server"]))
        except Exception as e:
            print(f"[mt5] {label}: exception {e!r}")
            results.append({"label": label, "error": f"exception: {e!r}"})

    mt5.shutdown()

    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    ARTIFACT.write_text(json.dumps(results, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"[mt5] wrote {ARTIFACT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
