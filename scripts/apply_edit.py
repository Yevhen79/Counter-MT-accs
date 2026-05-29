"""Apply an account change requested via the "Run workflow" form
(workflow_dispatch inputs) to config.yaml, preserving comments/formatting.

Inputs come from env:
  EDIT_ACCOUNT - the account label to change (or the "no change" sentinel)
  EDIT_LOGIN   - new login number (optional)
  EDIT_SERVER  - new server name (optional)

Does nothing (exit 0) if no account is selected or no new values are given.
On success it rewrites config.yaml; the workflow then commits it.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

from ruamel.yaml import YAML

NO_CHANGE = "(no change - just run)"


def main() -> int:
    account = (os.environ.get("EDIT_ACCOUNT") or "").strip()
    new_login = (os.environ.get("EDIT_LOGIN") or "").strip()
    new_server = (os.environ.get("EDIT_SERVER") or "").strip()

    if not account or account == NO_CHANGE:
        print("No account change requested — running with config.yaml as-is.")
        return 0
    if not new_login and not new_server:
        print(f"Account '{account}' selected but neither login nor server given — nothing to change.")
        return 0

    yaml = YAML()
    yaml.preserve_quotes = True
    path = Path("config.yaml")
    data = yaml.load(path)

    acc = next((a for a in data["accounts"] if a.get("label") == account), None)
    if acc is None:
        labels = ", ".join(a.get("label", "?") for a in data["accounts"])
        print(f"ERROR: account labelled '{account}' not found. Known: {labels}")
        return 1

    changed = []
    if new_login:
        if not new_login.isdigit():
            print(f"ERROR: login must be digits only, got '{new_login}'.")
            return 1
        acc["login"] = int(new_login)
        changed.append(f"login={new_login}")
    if new_server:
        acc["server"] = new_server
        changed.append(f"server='{new_server}'")

    yaml.dump(data, path)
    print(f"Updated '{account}': " + ", ".join(changed))
    print("NOTE: if the password also changed, update the secret "
          f"'{acc.get('password_secret')}' in repo Settings -> Secrets.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
