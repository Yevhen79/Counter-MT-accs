# Install MetaTrader 4 for headless instrument counting.
#
# We install MetaQuotes' GENERIC MT4 (not the broker-branded ForexClub
# build). Reason: the FC-branded MT4 build 1473 silently ignores the
# [Common] login block in our start.ini — the terminal starts, recompiles
# its bundled samples, then idles without ever logging in, so no chart
# opens and the counting EA never attaches. The generic MetaQuotes
# terminal honors the config block exactly the way the generic MT5
# terminal does (which works), and it resolves the ForexClub server name
# via MetaQuotes' global server registry.
#
# Exports MT4_DIR to $GITHUB_ENV on success.

$ErrorActionPreference = "Stop"

function Stop-AllTerminals {
    Get-Process terminal -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

$installer = "$env:RUNNER_TEMP\mt4setup.exe"
$url = "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt4/mt4setup.exe"

Write-Host "Downloading generic MetaQuotes MT4 from $url ..."
Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing -TimeoutSec 120
Write-Host ("Downloaded {0:N0} bytes" -f (Get-Item $installer).Length)

Write-Host "Installing MT4 silently (/auto) ..."
Start-Process -FilePath $installer -ArgumentList "/auto" -Wait

# The /auto installer auto-launches the terminal once installed — kill it
# so it isn't holding any modal first-run window.
Stop-AllTerminals

$candidates = @(
    "C:\Program Files (x86)\MetaTrader 4\terminal.exe",
    "C:\Program Files\MetaTrader 4\terminal.exe",
    "C:\Program Files (x86)\MetaTrader 4 Terminal\terminal.exe"
)

$installed = $null
foreach ($c in $candidates) {
    if (Test-Path $c) { $installed = $c; break }
}

if (-not $installed) {
    # Search Program Files for a generic MT4 (terminal.exe next to
    # metaeditor.exe, no terminal64.exe which would indicate MT5).
    Write-Host "Default location not found — searching Program Files..."
    foreach ($root in @("C:\Program Files", "C:\Program Files (x86)")) {
        if (Test-Path $root) {
            $hit = Get-ChildItem -Path $root -Filter "terminal.exe" -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                   Where-Object {
                       (Test-Path (Join-Path $_.DirectoryName "metaeditor.exe")) -and
                       -not (Test-Path (Join-Path $_.DirectoryName "terminal64.exe"))
                   } | Select-Object -First 1
            if ($hit) { $installed = $hit.FullName; break }
        }
    }
}

if (-not $installed) {
    Write-Warning "MT4 install did not produce terminal.exe anywhere known. Skipping MT4."
    exit 0
}

$mt4Dir = Split-Path $installed -Parent
"MT4_DIR=$mt4Dir" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
Write-Host "Generic MT4 installed at: $mt4Dir"
