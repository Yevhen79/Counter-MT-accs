# Committed broker installers

Some broker download URLs sit behind a Cloudflare "Just a moment…"
JavaScript challenge that an automated download (`Invoke-WebRequest`)
cannot pass. For those, commit the installer here and the workflow uses
it directly instead of downloading.

`install_terminals.ps1` looks for `installers/<filename>` where
`<filename>` is the last path segment of the account's `installer_url`
in `config.yaml`. If a valid `.exe` (PE binary) is present, it is used;
otherwise the script downloads the URL.

Currently needed (download in a browser, then upload here):

| File | For | URL it stands in for |
| ---- | --- | -------------------- |
| `libertexcom5setup.exe` | Libertex MT5 Market | https://download.libertex.com/software/metatrader5/libertexcom5setup.exe |

To add it via the GitHub web UI: open this folder → **Add file → Upload
files** → drag the `.exe` → commit to branch
`claude/trading-tools-report-MCrOV`.
