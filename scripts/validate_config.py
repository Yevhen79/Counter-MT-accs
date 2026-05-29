"""Validate config.yaml before a run so a self-service edit that breaks the
structure fails fast with a clear message instead of midway through.

Checks:
  - YAML parses
  - accounts is a non-empty list
  - each account has the required fields with sane values
  - platform is mt4 or mt5
  - login is an integer
  - labels and keys are unique (labels become history.csv columns)
Exits non-zero with a readable explanation on any problem.
"""

from __future__ import annotations

import sys
from pathlib import Path

import yaml

REQUIRED = ["key", "label", "platform", "login", "server", "password_secret",
            "installer_url", "dir_hint"]


def main() -> int:
    path = Path("config.yaml")
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as e:
        print(f"ERROR: config.yaml is not valid YAML (check indentation / quotes):\n{e}")
        return 1

    if not isinstance(data, dict) or "accounts" not in data:
        print("ERROR: config.yaml must have a top-level 'accounts:' list.")
        return 1

    accounts = data["accounts"]
    if not isinstance(accounts, list) or not accounts:
        print("ERROR: 'accounts' must be a non-empty list.")
        return 1

    problems: list[str] = []
    seen_labels: dict[str, int] = {}
    seen_keys: dict[str, int] = {}

    for i, acc in enumerate(accounts, 1):
        where = f"account #{i}"
        if not isinstance(acc, dict):
            problems.append(f"{where}: not a mapping (check the '- key:' indentation).")
            continue
        label = acc.get("label", f"(#{i})")
        where = f"account #{i} '{label}'"

        for field in REQUIRED:
            if field not in acc or acc[field] in (None, ""):
                problems.append(f"{where}: missing/empty required field '{field}'.")

        plat = acc.get("platform")
        if plat not in ("mt4", "mt5"):
            problems.append(f"{where}: platform must be 'mt4' or 'mt5', got {plat!r}.")

        login = acc.get("login")
        if not isinstance(login, int):
            problems.append(f"{where}: login must be a number (no quotes), got {login!r}.")

        if "label" in acc:
            seen_labels[acc["label"]] = seen_labels.get(acc["label"], 0) + 1
        if "key" in acc:
            seen_keys[acc["key"]] = seen_keys.get(acc["key"], 0) + 1

    for label, n in seen_labels.items():
        if n > 1:
            problems.append(f"duplicate label {label!r} ({n}×) — labels must be unique (they are the report columns).")
    for key, n in seen_keys.items():
        if n > 1:
            problems.append(f"duplicate key {key!r} ({n}×) — keys must be unique.")

    if problems:
        print("config.yaml has problems:")
        for p in problems:
            print(f"  - {p}")
        return 1

    print(f"config.yaml OK — {len(accounts)} accounts:")
    for acc in accounts:
        print(f"  - {acc['label']}: {acc['platform']} login={acc['login']} "
              f"server={acc['server']!r} secret={acc['password_secret']}")
    # Reminder about the secrets (their values are not visible here).
    secrets = sorted({a["password_secret"] for a in accounts if a.get("password_secret")})
    print("Password secrets expected in GitHub Secrets: " + ", ".join(secrets))
    return 0


if __name__ == "__main__":
    sys.exit(main())
