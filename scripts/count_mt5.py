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
import subprocess
import sys
import time
from pathlib import Path

import MetaTrader5 as mt5
import yaml

ARTIFACT = Path("artifacts/mt5_results.json")
# Honor MT5_TERMINAL set by the install step, fall back to the default location.
TERMINAL_PATH = os.environ.get(
    "MT5_TERMINAL",
    r"C:\Program Files\MetaTrader 5\terminal64.exe",
)
INIT_TIMEOUT_MS = 120_000
LOGIN_TIMEOUT_MS = 120_000


def err_dict(label: str, stage: str) -> dict:
    return {"label": label, "error": f"{stage}: {mt5.last_error()}"}


def kill_terminal() -> None:
    """Best-effort: kill any running terminal64.exe so the next initialize starts clean."""
    try:
        subprocess.run(
            ["taskkill", "/F", "/IM", "terminal64.exe"],
            capture_output=True, timeout=10, check=False,
        )
    except Exception as e:
        print(f"[mt5] taskkill raised: {e!r}")
    time.sleep(2)


def diagnostic_dump(tag: str) -> None:
    """Dump process state + a tiny directory listing to help diagnose."""
    print(f"[mt5] --- diagnostic dump ({tag}) ---")
    try:
        out = subprocess.run(
            ["tasklist", "/FI", "IMAGENAME eq terminal64.exe", "/FO", "CSV", "/NH"],
            capture_output=True, text=True, timeout=10,
        )
        lines = (out.stdout or "").strip().splitlines() or ["(none)"]
        for ln in lines[:5]:
            print(f"[mt5]   {ln}")
    except Exception as e:
        print(f"[mt5]   tasklist failed: {e!r}")
    try:
        appdata = Path(os.environ.get("APPDATA", "")) / "MetaQuotes" / "Terminal"
        if appdata.exists():
            for child in list(appdata.iterdir())[:5]:
                print(f"[mt5]   appdata: {child.name}")
        else:
            print(f"[mt5]   no appdata at {appdata}")
    except Exception as e:
        print(f"[mt5]   appdata dump failed: {e!r}")
    print(f"[mt5] --- end dump ---")


def write_mt5_start_ini(account: dict) -> Path:
    """Write a start.ini under the MT5 install dir so the terminal logs
    into the given account on launch and skips its broker-selection wizard."""
    password = os.environ.get(account["password_secret"], "")
    config_dir = Path(TERMINAL_PATH).parent / "config"
    config_dir.mkdir(parents=True, exist_ok=True)
    ini = config_dir / "start.ini"
    ini.write_text(
        "[Common]\n"
        f"Login={account['login']}\n"
        f"Password={password}\n"
        f"Server={account['server']}\n"
        "ProxyEnable=false\n"
        "NewsEnable=false\n"
        "CertInstall=false\n"
        "EnableExperts=false\n",
        encoding="utf-8",
    )
    print(f"[mt5] wrote {ini} for login={account['login']} server={account['server']!r}")
    return ini


def try_init(label: str, **kwargs) -> bool:
    """Wrap mt5.initialize with logging. kwargs are passed through."""
    print(f"[mt5] warmup attempt: {label}")
    t0 = time.time()
    ok = mt5.initialize(**kwargs)
    dt = time.time() - t0
    if ok:
        print(f"[mt5]   OK after {dt:.1f}s")
        ti = mt5.terminal_info()
        if ti is not None:
            print(f"[mt5]   terminal_info: build={ti.build} connected={ti.connected} "
                  f"path={ti.path} data_path={ti.data_path}")
        return True
    err = mt5.last_error()
    print(f"[mt5]   FAILED after {dt:.1f}s: {err}")
    try:
        mt5.shutdown()
    except Exception:
        pass
    return False


def warm_terminal(mt5_accounts: list) -> bool:
    """Try increasingly aggressive strategies to bring terminal64.exe up to IPC.

    -10005 IPC timeout on first init usually means terminal64.exe is sitting
    behind a modal first-run dialog or a stale instance is holding the named
    pipe. Each attempt clears any running terminal first.
    """
    diagnostic_dump("before any attempt")

    # A: clean kill + explicit path
    kill_terminal()
    if try_init("A: explicit path",
                path=TERMINAL_PATH, timeout=INIT_TIMEOUT_MS):
        return True
    diagnostic_dump("after A")

    # B: pre-launch terminal manually, give it 30s to settle, then connect
    kill_terminal()
    print("[mt5] B: pre-launching terminal via subprocess and sleeping 30s...")
    try:
        subprocess.Popen(
            [TERMINAL_PATH, "/portable", "/skipupdate"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            creationflags=getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0),
        )
    except Exception as e:
        print(f"[mt5]   Popen raised: {e!r}")
    time.sleep(30)
    diagnostic_dump("after B's pre-launch")
    if try_init("B: connect to running terminal",
                path=TERMINAL_PATH, portable=True, timeout=INIT_TIMEOUT_MS):
        return True
    diagnostic_dump("after B")

    # C: portable mode (uses install dir as data dir; needs admin which we have)
    kill_terminal()
    if try_init("C: portable mode",
                path=TERMINAL_PATH, portable=True, timeout=INIT_TIMEOUT_MS):
        return True
    diagnostic_dump("after C")

    # D: pre-write start.ini with first account, /portable /config:start.ini, sleep, connect
    if mt5_accounts:
        kill_terminal()
        write_mt5_start_ini(mt5_accounts[0])
        print("[mt5] D: launching with /portable /config:start.ini /skipupdate, sleeping 35s...")
        try:
            subprocess.Popen(
                [TERMINAL_PATH, "/portable", "/config:start.ini", "/skipupdate"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                creationflags=getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0),
            )
        except Exception as e:
            print(f"[mt5]   Popen raised: {e!r}")
        time.sleep(35)
        diagnostic_dump("after D's pre-launch")
        if try_init("D: connect after config-based login",
                    path=TERMINAL_PATH, portable=True, timeout=INIT_TIMEOUT_MS):
            return True
        diagnostic_dump("after D")

    # E: dirt-simple — no path, no portable, let MetaTrader5 auto-discover
    kill_terminal()
    if try_init("E: auto-discovery (no path)",
                timeout=INIT_TIMEOUT_MS):
        return True
    diagnostic_dump("after E")

    return False


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

    if not warm_terminal(mt5_accounts):
        err = mt5.last_error()
        print(f"[mt5] terminal warmup exhausted all strategies; last_error={err}")
        results = [{"label": a["label"], "error": f"terminal_warmup_failed: {err}"} for a in mt5_accounts]
        ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
        ARTIFACT.write_text(json.dumps(results, indent=2, ensure_ascii=False), encoding="utf-8")
        return 0

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
