# Count tradeable instruments on each MT4 account configured in config.yaml.
#
# For each MT4 account:
#   1. Copy CountInstruments.mq4 into the terminal's MQL4\Experts folder.
#   2. Compile it via metaeditor.exe.
#   3. Write a start.ini config with login/password/server and a [StartUp]
#      block that auto-attaches CountInstruments to a chart.
#   4. Launch terminal.exe with /portable /config:start.ini /skipupdate.
#   5. Wait until MQL4\Files\done.flag appears (or timeout).
#   6. Read MQL4\Files\count.json.
#   7. Kill the terminal.
#
# Results are written to artifacts/mt4_results.json so aggregate.py can pick
# them up.

$ErrorActionPreference = "Stop"

function Ensure-Module($name) {
    if (-not (Get-Module -ListAvailable -Name $name)) {
        Install-Module $name -Force -Scope CurrentUser -AllowClobber | Out-Null
    }
    Import-Module $name -Force
}

Ensure-Module powershell-yaml

$config = (Get-Content -Raw -Path "config.yaml") | ConvertFrom-Yaml
$mt4Dir = $env:MT4_DIR

if (-not (Test-Path "artifacts")) {
    New-Item -ItemType Directory -Path "artifacts" -Force | Out-Null
}

if ([string]::IsNullOrWhiteSpace($mt4Dir) -or -not (Test-Path "$mt4Dir\terminal.exe")) {
    Write-Warning "MT4_DIR is empty or terminal.exe missing — MT4 step was probably skipped earlier."
    "[]" | Set-Content -Path "artifacts/mt4_results.json" -Encoding utf8
    exit 0
}

Write-Host "Using MT4 install: $mt4Dir"

$results = New-Object System.Collections.ArrayList

foreach ($acc in $config.accounts | Where-Object { $_.platform -eq "mt4" }) {
    $label   = $acc.label
    $login   = $acc.login
    $server  = $acc.server
    $secret  = $acc.password_secret
    $password = [Environment]::GetEnvironmentVariable($secret)

    Write-Host ""
    Write-Host "=== $label (login=$login, server='$server') ==="

    if ([string]::IsNullOrWhiteSpace($password)) {
        Write-Warning "No password in env var $secret — skipping $label."
        [void]$results.Add(@{ label = $label; error = "no_password_secret" })
        continue
    }

    $filesDir   = Join-Path $mt4Dir "MQL4\Files"
    $expertsDir = Join-Path $mt4Dir "MQL4\Experts"
    $configDir  = Join-Path $mt4Dir "config"
    foreach ($d in @($filesDir, $expertsDir, $configDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    # Clean previous artifacts so we don't read stale data.
    Remove-Item (Join-Path $filesDir "count.json") -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $filesDir "done.flag")  -ErrorAction SilentlyContinue

    # Stage EA source and compile to .ex4.
    Copy-Item "mql4\CountInstruments.mq4" -Destination (Join-Path $expertsDir "CountInstruments.mq4") -Force
    $metaeditor = Join-Path $mt4Dir "metaeditor.exe"
    if (Test-Path $metaeditor) {
        Write-Host "Compiling EA..."
        & $metaeditor "/compile:$expertsDir\CountInstruments.mq4" "/log" | Out-Null
    } else {
        Write-Warning "metaeditor.exe not found at $metaeditor"
    }
    if (-not (Test-Path (Join-Path $expertsDir "CountInstruments.ex4"))) {
        Write-Warning "EA compile failed (no .ex4 produced) for $label"
        [void]$results.Add(@{ label = $label; error = "compile_failed" })
        continue
    }

    # Write start.ini. ANSI encoding matters: MT4 expects 1-byte chars.
    $iniLines = @(
        "[Common]",
        "Login=$login",
        "Password=$password",
        "Server=$server",
        "EnableExperts=true",
        "EnableDDE=false",
        "ProxyEnable=false",
        "[Experts]",
        "AllowLiveTrading=true",
        "AllowDllImport=false",
        "Enabled=true",
        "[StartUp]",
        "Expert=CountInstruments",
        "Symbol=EURUSD",
        "Period=H1"
    )
    $iniPath = Join-Path $configDir "start.ini"
    [System.IO.File]::WriteAllLines($iniPath, $iniLines, [System.Text.Encoding]::ASCII)

    # Launch terminal.
    $terminal = Join-Path $mt4Dir "terminal.exe"
    Write-Host "Launching terminal.exe ..."
    $proc = Start-Process -FilePath $terminal -ArgumentList "/portable","/config:start.ini","/skipupdate" -PassThru

    # Poll for the done flag.
    $timeout = 180
    $elapsed = 0
    while (-not (Test-Path (Join-Path $filesDir "done.flag")) -and $elapsed -lt $timeout) {
        Start-Sleep -Seconds 3
        $elapsed += 3
    }

    $countFile = Join-Path $filesDir "count.json"
    if (Test-Path $countFile) {
        try {
            $obj = Get-Content -Raw -Path $countFile | ConvertFrom-Json
            Write-Host "$label: full=$($obj.full) total=$($obj.total)"
            [void]$results.Add(@{
                label = $label
                full  = [int]$obj.full
                total = [int]$obj.total
                server = $server
            })
        } catch {
            Write-Warning "Failed to parse count.json: $_"
            [void]$results.Add(@{ label = $label; error = "parse_failed" })
        }
    } else {
        Write-Warning "Timed out after ${timeout}s waiting for done.flag ($label)"
        [void]$results.Add(@{ label = $label; error = "timeout" })
    }

    # Kill the terminal (and any lingering instances).
    try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
    Get-Process terminal -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}

$results | ConvertTo-Json -Depth 5 | Out-File -FilePath "artifacts/mt4_results.json" -Encoding utf8
Write-Host ""
Write-Host "Wrote artifacts/mt4_results.json"
