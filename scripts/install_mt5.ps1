# Install the ForexClub-branded MetaTrader 5.
#
# We must use the BROKER build, not generic MetaQuotes MT5. Logging the
# same account into generic MT5 returns a completely different symbol
# universe (~10157 raw Nasdaq exchange tickers: AAPL, AMZN, ... with no
# crypto) than what the user actually trades. The ForexClub-branded
# terminal shows the retail catalog (~305: name-based stocks like
# "Apple"/"Amazon", crypto, FX, metals, indices) — the set the user sees
# and wants counted. The broker server serves different symbol sets to
# the branded vs generic terminal.
#
# The FC installer ignores documented silent flags and opens a GUI, so we
# try each flag with a short timeout and kill the leftover window — one of
# them completes the install in the background. Exports MT5_DIR and
# MT5_TERMINAL on success.

$ErrorActionPreference = "Stop"

$installer = "$env:RUNNER_TEMP\fcmt5setup.exe"
$url = "https://download.libertex.org/metatrader/fcmt5setup.exe"

Write-Host "Downloading ForexClub MT5 from $url ..."
Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing -TimeoutSec 180 `
    -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
Write-Host ("Downloaded {0:N0} bytes" -f (Get-Item $installer).Length)

$candidates = @(
    "C:\Program Files\ForexClub MetaTrader 5\terminal64.exe",
    "C:\Program Files\ForexClub MT5\terminal64.exe",
    "C:\Program Files\Libertex MetaTrader 5\terminal64.exe",
    "C:\Program Files\Libertex MT5\terminal64.exe"
)

function Find-MT5 {
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    foreach ($root in @("C:\Program Files", "C:\Program Files (x86)")) {
        if (Test-Path $root) {
            $hit = Get-ChildItem -Path $root -Filter "terminal64.exe" -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                   Where-Object {
                       $p = Split-Path $_.DirectoryName -Leaf
                       $p -match "(?i)(ForexClub|FXClub|Libertex)"
                   } | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }
    return $null
}

function Try-SilentInstall($flag, $timeoutSec) {
    Write-Host "Trying install flag '$flag' (timeout ${timeoutSec}s)..."
    $p = Start-Process -FilePath $installer -ArgumentList $flag -PassThru -ErrorAction SilentlyContinue
    if (-not $p) { return }
    $w = 0
    while (-not $p.HasExited -and $w -lt $timeoutSec) { Start-Sleep -Seconds 3; $w += 3 }
    if (-not $p.HasExited) {
        Write-Host "  installer still running after ${timeoutSec}s — killing GUI processes."
        Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match "(?i)(fcmt5setup|setup|install|forexclub|metatrader|metaquotes)"
        } | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {} }
        Start-Sleep -Seconds 2
    } else {
        Write-Host "  installer exited with code $($p.ExitCode) after ${w}s."
    }
}

$installed = Find-MT5
foreach ($flag in @("/auto", "/S", "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-", "/silent", "/quiet")) {
    if ($installed) { break }
    Try-SilentInstall $flag 30
    $installed = Find-MT5
}

# Kill any terminal the installer auto-launched (first-run wizard is modal).
Get-Process terminal64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

if (-not $installed) {
    Write-Error "ForexClub MT5 install did not produce terminal64.exe."
    exit 1
}

$mt5Dir = Split-Path $installed -Parent
"MT5_DIR=$mt5Dir"        | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
"MT5_TERMINAL=$installed" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
Write-Host "ForexClub MT5 installed at: $mt5Dir"

# Exclude from Defender realtime scanning (suspected IPC/launch interference).
try {
    Add-MpPreference -ExclusionPath $mt5Dir -ErrorAction SilentlyContinue
    Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
    Write-Host "Defender realtime disabled, $mt5Dir excluded."
} catch {
    Write-Warning "Could not adjust Defender preferences: $_"
}
