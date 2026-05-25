# Install the ForexClub-branded MetaTrader 4.
#
# We need the BROKER build (not generic MetaQuotes MT4) because generic MT4
# cannot resolve the ForexClub MT4 server names — the terminal loads our
# config and the EA attaches, but there is no broker connection ("cannot
# refresh history [4073]"), so no symbols load. The FC installer bundles
# the ForexClub *.srv server->IP files. (Generic MT5 worked because the
# MetaQuotes global server registry does carry the ForexClub MT5 servers;
# the MT4 servers are not in it.)
#
# The FC installer ignores documented silent flags and opens a GUI, so we
# try each flag with a short timeout and kill the leftover window — one of
# them completes the install in the background. Exports MT4_DIR on success.

$ErrorActionPreference = "Stop"

$installer = "$env:RUNNER_TEMP\fcmt4setup.exe"
$url = "https://download.fxclub.org/Metatrader/fcmt4setup_ru.exe"

Write-Host "Downloading ForexClub MT4 from $url ..."
Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing -TimeoutSec 120 `
    -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
Write-Host ("Downloaded {0:N0} bytes" -f (Get-Item $installer).Length)

$candidates = @(
    "C:\Program Files (x86)\ForexClub MT4\terminal.exe",
    "C:\Program Files\ForexClub MT4\terminal.exe",
    "C:\Program Files (x86)\ForexClub MetaTrader 4\terminal.exe",
    "C:\Program Files\ForexClub MetaTrader 4\terminal.exe"
)

function Find-MT4 {
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    foreach ($root in @("C:\Program Files", "C:\Program Files (x86)")) {
        if (Test-Path $root) {
            $hit = Get-ChildItem -Path $root -Filter "terminal.exe" -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                   Where-Object {
                       $p = Split-Path $_.DirectoryName -Leaf
                       $p -match "(?i)(ForexClub|FXClub|Libertex)" -and
                       -not (Test-Path (Join-Path $_.DirectoryName "terminal64.exe"))
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
            $_.Name -match "(?i)(fcmt4setup|setup|install|forexclub|metatrader)"
        } | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {} }
        Start-Sleep -Seconds 2
    } else {
        Write-Host "  installer exited with code $($p.ExitCode) after ${w}s."
    }
}

$installed = Find-MT4
foreach ($flag in @("/auto", "/S", "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-", "/silent", "/quiet")) {
    if ($installed) { break }
    Try-SilentInstall $flag 30
    $installed = Find-MT4
}

if (-not $installed) {
    Write-Warning "ForexClub MT4 install did not produce terminal.exe. Skipping MT4."
    exit 0
}

$mt4Dir = Split-Path $installed -Parent
"MT4_DIR=$mt4Dir" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
Write-Host "ForexClub MT4 installed at: $mt4Dir"
