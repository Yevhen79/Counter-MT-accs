# Count MT5 instruments via a headless terminal + MQL5 EA, mirroring the
# MT4 path. The Python MetaTrader5 module's IPC consistently times out in
# this GitHub Actions environment regardless of warmup strategy, so we
# bypass it entirely.
#
# For each MT5 account in config.json:
#   1. Compile mql5\CountInstruments.mq5 -> .ex5 via metaeditor64.exe.
#   2. Write start.ini under <install>/config/ with the account credentials
#      and [StartUp] Expert=CountInstruments Symbol=EURUSD Period=H1.
#   3. Launch terminal64.exe /portable /config:start.ini /skipupdate.
#   4. Poll <install>/MQL5/Files/done.flag for up to 240 s.
#   5. Read count.json. Kill the terminal.
#
# Results -> artifacts/mt5_results.json.

$ErrorActionPreference = "Stop"

# Baseline write so the aggregator always sees a file even if we crash.
if (-not (Test-Path "artifacts")) {
    New-Item -ItemType Directory -Path "artifacts" -Force | Out-Null
}
"[]" | Set-Content -Path "artifacts/mt5_results.json" -Encoding utf8

if (-not (Test-Path "config.json")) {
    Write-Warning "config.json missing — Convert config.yaml step was skipped, nothing to do."
    exit 0
}
$config = Get-Content -Raw -Path "config.json" | ConvertFrom-Json
$mt5Dir = $env:MT5_DIR
$terminal = $env:MT5_TERMINAL
if ([string]::IsNullOrWhiteSpace($mt5Dir)) { $mt5Dir = "C:\Program Files\MetaTrader 5" }
if ([string]::IsNullOrWhiteSpace($terminal)) { $terminal = Join-Path $mt5Dir "terminal64.exe" }

if (-not (Test-Path $terminal)) {
    Write-Warning "MT5 terminal not found at $terminal — install step probably failed."
    exit 0
}

Write-Host "Using MT5 install: $mt5Dir"

# Symbol candidates to try as the [StartUp] chart symbol. Pick the first one
# the broker has — without a valid Symbol the chart does not open and the
# EA never attaches.
$symbolCandidates = @("EURUSD", "EURUSDx", "GBPUSD", "USDRUB")

$results = New-Object System.Collections.ArrayList

foreach ($acc in $config.accounts | Where-Object { $_.platform -eq "mt5" }) {
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

    $filesDir   = Join-Path $mt5Dir "MQL5\Files"
    $expertsDir = Join-Path $mt5Dir "MQL5\Experts"
    $configDir  = Join-Path $mt5Dir "config"
    foreach ($d in @($filesDir, $expertsDir, $configDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    # Clean stale outputs.
    Remove-Item (Join-Path $filesDir "count.json") -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $filesDir "done.flag")  -ErrorAction SilentlyContinue

    # Stage EA source + compile to .ex5 via metaeditor64.exe.
    Copy-Item "mql5\CountInstruments.mq5" -Destination (Join-Path $expertsDir "CountInstruments.mq5") -Force
    $metaeditor = Join-Path $mt5Dir "metaeditor64.exe"
    $compileLog = Join-Path $expertsDir "CountInstruments.log"
    Remove-Item $compileLog -ErrorAction SilentlyContinue
    if (Test-Path $metaeditor) {
        Push-Location $expertsDir
        try {
            Write-Host "Compiling EA via $metaeditor in $($PWD.Path) ..."
            $proc = Start-Process -FilePath $metaeditor `
                                  -ArgumentList "/compile:CountInstruments.mq5","/log:CountInstruments.log" `
                                  -WorkingDirectory $expertsDir `
                                  -PassThru -NoNewWindow
            $waited = 0
            while (-not $proc.HasExited -and $waited -lt 60) {
                Start-Sleep -Seconds 2
                $waited += 2
            }
            if (-not $proc.HasExited) {
                Write-Warning "metaeditor64.exe did not exit within 60s — killing."
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            } else {
                Write-Host "metaeditor64 exit code: $($proc.ExitCode)"
            }
        } finally {
            Pop-Location
        }
        if (Test-Path $compileLog) {
            Write-Host "--- compile log ---"
            foreach ($enc in @([Text.Encoding]::Unicode, [Text.Encoding]::UTF8, [Text.Encoding]::Default)) {
                try {
                    $txt = [IO.File]::ReadAllText($compileLog, $enc)
                    if ($txt -and ($txt -notmatch '^(\x00|\xFE|\xFF)')) {
                        Write-Host $txt
                        break
                    }
                } catch {}
            }
            Write-Host "--- end compile log ---"
        }
    } else {
        Write-Warning "metaeditor64.exe not found at $metaeditor"
    }
    if (-not (Test-Path (Join-Path $expertsDir "CountInstruments.ex5"))) {
        Write-Warning "EA compile failed (no .ex5 produced) for $label"
        [void]$results.Add(@{ label = $label; error = "compile_failed" })
        continue
    }

    $success = $false
    $acctMismatch = $false
    foreach ($symbol in $symbolCandidates) {
        if ($success) { break }
        Write-Host "Trying with Symbol=$symbol ..."

        Remove-Item (Join-Path $filesDir "count.json") -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $filesDir "done.flag")  -ErrorAction SilentlyContinue

        $iniLines = @(
            "[Common]",
            "Login=$login",
            "Account=$login",
            "Password=$password",
            "Server=$server",
            "EnableExperts=true",
            "EnableNews=false",
            "ProxyEnable=false",
            "CertInstall=false",
            "[Experts]",
            "AllowLiveTrading=true",
            "AllowDllImport=false",
            "Enabled=true",
            "[StartUp]",
            "Expert=CountInstruments",
            "Symbol=$symbol",
            "Period=H1"
        )
        # Write start.ini in the CURRENT working directory (the repo
        # checkout, which has no spaces in its path). MT5 build 5836
        # resolves /config:<name> relative to the launch CWD, NOT the
        # data folder — the previous run logged
        # "cannot load config D:\a\...\start.ini at start" because the
        # file lived under <install>\config and was never found. Pass the
        # absolute path to /config: to be unambiguous.
        $iniPath = Join-Path (Get-Location).Path "mt5_start.ini"
        [System.IO.File]::WriteAllLines($iniPath, $iniLines, [System.Text.Encoding]::ASCII)

        # Don't print the raw start.ini — it contains the password.
        Write-Host "wrote $iniPath (login=$login, server='$server', symbol=$symbol)"

        Write-Host "Launching terminal64.exe with /config:$iniPath ..."
        $tProc = Start-Process -FilePath $terminal `
                               -ArgumentList "/portable","/config:$iniPath","/skipupdate" `
                               -PassThru

        $timeout = 90
        $elapsed = 0
        while (-not (Test-Path (Join-Path $filesDir "done.flag")) -and $elapsed -lt $timeout) {
            Start-Sleep -Seconds 3
            $elapsed += 3
        }

        $countFile = Join-Path $filesDir "count.json"
        if (Test-Path $countFile) {
            try {
                $obj = Get-Content -Raw -Path $countFile | ConvertFrom-Json
                $acctMatch = ([string]$obj.account -eq [string]$login)
                Write-Host "${label}: full(all)=$($obj.full) total(all)=$($obj.total) full(marketwatch)=$($obj.full_marketwatch) total(marketwatch)=$($obj.total_marketwatch) account=$($obj.account) (expected $login, match=$acctMatch)"
                if (-not $acctMatch) {
                    Write-Warning "Account mismatch — terminal reported $($obj.account) but expected $login. Possible stale/cached session; rejecting this result."
                    $acctMismatch = $true
                    break  # a different symbol won't fix a wrong login
                } else {
                    # Save the per-symbol list for review.
                    $symbolsCsv = Join-Path $filesDir "symbols.csv"
                    if (Test-Path $symbolsCsv) {
                        $key = ($label -replace '\s','_')
                        Copy-Item $symbolsCsv -Destination "artifacts/mt5_symbols_$key.csv" -Force
                        Write-Host "saved symbol list -> artifacts/mt5_symbols_$key.csv"
                    }
                    [void]$results.Add(@{
                        label = $label
                        full  = [int]$obj.full
                        total = [int]$obj.total
                        full_marketwatch  = [int]$obj.full_marketwatch
                        total_marketwatch = [int]$obj.total_marketwatch
                        server = $server
                        symbol = $symbol
                        account = "$($obj.account)"
                    })
                    $success = $true
                }
            } catch {
                Write-Warning "Failed to parse count.json: $_"
            }
        } else {
            Write-Warning "Timed out (${timeout}s) on Symbol=$symbol"
            # Dump terminal log for diagnosis.
            $logsDir = Join-Path $mt5Dir "logs"
            if (Test-Path $logsDir) {
                $latest = Get-ChildItem -Path $logsDir -Filter "*.log" -ErrorAction SilentlyContinue |
                          Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($latest) {
                    Write-Host "--- $($latest.FullName) (tail 50) ---"
                    try { Get-Content -Path $latest.FullName -Tail 50 | Write-Host } catch {}
                    Write-Host "--- end ---"
                }
            }
        }

        try { Stop-Process -Id $tProc.Id -Force -ErrorAction SilentlyContinue } catch {}
        Get-Process terminal64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3

        if ($acctMismatch) { break }  # stop trying symbols on wrong login
    }

    if (-not $success) {
        if ($acctMismatch) {
            [void]$results.Add(@{ label = $label; error = "account_mismatch_stale_session" })
        } else {
            [void]$results.Add(@{ label = $label; error = "no_symbol_worked"; tried = $symbolCandidates -join ',' })
        }
    }
}

$results | ConvertTo-Json -Depth 5 | Out-File -FilePath "artifacts/mt5_results.json" -Encoding utf8
Write-Host ""
Write-Host "Wrote artifacts/mt5_results.json"
