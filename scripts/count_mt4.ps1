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

# Always write at least a baseline empty results file so the aggregator and
# upload-artifact step never see a missing file regardless of what happens
# below. This is overwritten by the real results at the end.
if (-not (Test-Path "artifacts")) {
    New-Item -ItemType Directory -Path "artifacts" -Force | Out-Null
}
"[]" | Set-Content -Path "artifacts/mt4_results.json" -Encoding utf8

if (-not (Test-Path "config.json")) {
    Write-Warning "config.json missing — Convert config.yaml step was skipped, nothing to do."
    exit 0
}
$config = Get-Content -Raw -Path "config.json" | ConvertFrom-Json

# Map each installer_url to the folder its terminal landed in.
$terminalDirByUrl = @{}
if (Test-Path "terminals.json") {
    foreach ($t in (Get-Content -Raw -Path "terminals.json" | ConvertFrom-Json)) {
        if ($t.dir) { $terminalDirByUrl[$t.url] = $t.dir }
    }
}

$results = New-Object System.Collections.ArrayList

foreach ($acc in $config.accounts | Where-Object { $_.platform -eq "mt4" }) {
    $label   = $acc.label
    $login   = $acc.login
    $server  = $acc.server
    $secret  = $acc.password_secret
    $password = [Environment]::GetEnvironmentVariable($secret)

    Write-Host ""
    Write-Host "=== $label (login=$login, server='$server') ==="

    $mt4Dir = $terminalDirByUrl[$acc.installer_url]
    if ([string]::IsNullOrWhiteSpace($mt4Dir) -or -not (Test-Path (Join-Path $mt4Dir "terminal.exe"))) {
        Write-Warning "No installed terminal for $($acc.installer_url) — skipping $label."
        [void]$results.Add(@{ label = $label; error = "terminal_not_installed" })
        continue
    }
    Write-Host "Using MT4 install: $mt4Dir"

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
    # The MT4 install dir contains a space ("Program Files (x86)") and the
    # broker name. metaeditor.exe's /compile: argument does not handle
    # internal spaces well, so cd into the Experts folder and pass a
    # quote-less relative path instead.
    Copy-Item "mql4\CountInstruments.mq4" -Destination (Join-Path $expertsDir "CountInstruments.mq4") -Force
    $metaeditor = Join-Path $mt4Dir "metaeditor.exe"
    $compileLog = Join-Path $expertsDir "CountInstruments.log"
    Remove-Item $compileLog -ErrorAction SilentlyContinue
    if (Test-Path $metaeditor) {
        Push-Location $expertsDir
        try {
            Write-Host "Compiling EA via $metaeditor in $($PWD.Path) ..."
            $proc = Start-Process -FilePath $metaeditor `
                                  -ArgumentList "/compile:CountInstruments.mq4","/log:CountInstruments.log" `
                                  -WorkingDirectory $expertsDir `
                                  -PassThru -NoNewWindow
            $waited = 0
            while (-not $proc.HasExited -and $waited -lt 60) {
                Start-Sleep -Seconds 2
                $waited += 2
            }
            if (-not $proc.HasExited) {
                Write-Warning "metaeditor.exe did not exit within 60s — killing."
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            } else {
                Write-Host "metaeditor exit code: $($proc.ExitCode)"
            }
        } finally {
            Pop-Location
        }
        if (Test-Path $compileLog) {
            Write-Host "--- compile log ($compileLog) ---"
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
        } else {
            Write-Host "(no compile log produced at $compileLog)"
        }
    } else {
        Write-Warning "metaeditor.exe not found at $metaeditor — listing MT4 install dir for diagnosis:"
        Get-ChildItem -Path $mt4Dir -Force | Select-Object Name, Length, LastWriteTime | Format-Table | Out-String | Write-Host
    }
    if (-not (Test-Path (Join-Path $expertsDir "CountInstruments.ex4"))) {
        Write-Warning "EA compile failed (no .ex4 produced) for $label"
        [void]$results.Add(@{ label = $label; error = "compile_failed" })
        continue
    }

    # EURUSD is confirmed to exist and the EA now loads on it, so try it
    # first with a short fallback. The per-attempt timeout (below) must
    # exceed the EA's own retry budget so we don't kill it mid-count.
    $symbolCandidates = @("EURUSD", "GBPUSD")

    $vsBase = Join-Path $env:LOCALAPPDATA "VirtualStore"
    $vsMt4 = Join-Path $vsBase ($mt4Dir.Substring(3))
    $vsFilesDir = Join-Path $vsMt4 "MQL4\Files"

    $success = $false
    $acctMismatch = $false
    foreach ($symbol in $symbolCandidates) {
        if ($success) { break }
        Write-Host ""
        Write-Host "Attempt with Symbol=$symbol"

        # Clean stale outputs each attempt.
        Remove-Item (Join-Path $filesDir "count.json") -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $filesDir "done.flag")  -ErrorAction SilentlyContinue
        if (Test-Path $vsFilesDir) {
            Remove-Item (Join-Path $vsFilesDir "count.json") -ErrorAction SilentlyContinue
            Remove-Item (Join-Path $vsFilesDir "done.flag")  -ErrorAction SilentlyContinue
        }

        # Write start.ini. ANSI encoding matters: MT4 expects 1-byte chars.
        # Include both Login= and Account= — builds differ on key name.
        $iniLines = @(
            "[Common]",
            "Login=$login",
            "Account=$login",
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
            "Symbol=$symbol",
            "Period=H1"
        )
        # Write start.ini in the CURRENT working directory (repo checkout,
        # no spaces in its path). MT4/MT5 resolve /config:<name> relative
        # to the launch CWD, not the data folder — writing under
        # <install>\config left the terminal unable to find it. Pass the
        # absolute path to /config:.
        $iniPath = Join-Path (Get-Location).Path "mt4_start.ini"
        [System.IO.File]::WriteAllLines($iniPath, $iniLines, [System.Text.Encoding]::ASCII)

        Write-Host "wrote $iniPath (login=$login, server='$server', symbol=$symbol)"

        # MT4 takes the startup config as a POSITIONAL argument
        # ("terminal.exe config.ini"), NOT via /config: (that's MT5 syntax).
        # Passing /config: to MT4 was silently ignored, so the terminal
        # launched with no account config at all — which is why it just
        # recompiled samples and idled with no login. Pass the absolute ini
        # path positionally; keep /portable so MQL4\Files resolves to the
        # install dir where we poll for done.flag.
        $terminal = Join-Path $mt4Dir "terminal.exe"
        $tArgs = @($iniPath, "/portable", "/skipupdate")
        Write-Host "Launching terminal.exe $($tArgs -join ' ')"
        $proc = Start-Process -FilePath $terminal -ArgumentList $tArgs -PassThru

        # Poll for done flag. The EA waits up to 60 timer ticks x 2s = 120s
        # for the symbol list to populate before writing its result, so the
        # host timeout must exceed that or we kill the terminal mid-count.
        $timeout = 135
        $elapsed = 0
        while ($elapsed -lt $timeout) {
            if ((Test-Path (Join-Path $filesDir "done.flag")) -or
                (Test-Path (Join-Path $vsFilesDir "done.flag"))) {
                break
            }
            Start-Sleep -Seconds 3
            $elapsed += 3
        }

        $countFile = Join-Path $filesDir "count.json"
        $vsCountFile = Join-Path $vsFilesDir "count.json"
        if (Test-Path $vsCountFile) {
            Write-Host "Found count.json in VirtualStore at $vsCountFile"
            $countFile = $vsCountFile
        }

        if (Test-Path $countFile) {
            try {
                $obj = Get-Content -Raw -Path $countFile | ConvertFrom-Json
                $acctMatch = ([string]$obj.account -eq [string]$login)
                Write-Host "${label}: full(all)=$($obj.full) total(all)=$($obj.total) full(marketwatch)=$($obj.full_marketwatch) total(marketwatch)=$($obj.total_marketwatch) account=$($obj.account) (expected $login, match=$acctMatch, symbol=$symbol)"
                if (-not $acctMatch) {
                    Write-Warning "Account mismatch — terminal reported $($obj.account) but expected $login. Rejecting (stale session)."
                    $acctMismatch = $true
                    break
                } else {
                    $symbolsCsv = Join-Path $filesDir "symbols.csv"
                    $vsSymbolsCsv = Join-Path $vsFilesDir "symbols.csv"
                    if (Test-Path $vsSymbolsCsv) { $symbolsCsv = $vsSymbolsCsv }
                    if (Test-Path $symbolsCsv) {
                        $key = ($label -replace '\s','_')
                        Copy-Item $symbolsCsv -Destination "artifacts/mt4_symbols_$key.csv" -Force
                        Write-Host "saved symbol list -> artifacts/mt4_symbols_$key.csv"
                    }
                    [void]$results.Add(@{
                        label = $label
                        full  = [int]$obj.full
                        total = [int]$obj.total
                        closeonly = [int]$obj.closeonly
                        disabled  = [int]$obj.disabled
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
            $eaInit = (Test-Path (Join-Path $filesDir "ea_init.flag")) -or
                      (Test-Path (Join-Path $vsFilesDir "ea_init.flag"))
            Write-Host "EA OnInit ran (ea_init.flag present): $eaInit"

            # Dump terminal logs for diagnosis. MT4 writes them to
            # <install>\logs\YYYYMMDD.log and <install>\MQL4\Logs\YYYYMMDD.log
            # (and VirtualStore-redirected copies if portable mode hits UAC).
            # Only do the heavy dump on the LAST symbol attempt to keep the
            # log size manageable.
            $isLastAttempt = ($symbol -eq $symbolCandidates[-1])
            if ($isLastAttempt) {
                foreach ($logRoot in @(
                    (Join-Path $mt4Dir "logs"),
                    (Join-Path $mt4Dir "MQL4\Logs"),
                    (Join-Path $vsMt4 "logs"),
                    (Join-Path $vsMt4 "MQL4\Logs")
                )) {
                    if (Test-Path $logRoot) {
                        $latest = Get-ChildItem -Path $logRoot -Filter "*.log" -ErrorAction SilentlyContinue |
                                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
                        if ($latest) {
                            Write-Host "--- $($latest.FullName) (tail) ---"
                            try { Get-Content -Path $latest.FullName -Tail 80 | Write-Host } catch { Write-Host "(read failed: $_)" }
                            Write-Host "--- end ---"
                        }
                    }
                }
                # Also dump the actual Files dir listing.
                foreach ($d in @($filesDir, $vsFilesDir)) {
                    if (Test-Path $d) {
                        Write-Host "Listing $d :"
                        Get-ChildItem -Path $d -Force | Select-Object Name, Length, LastWriteTime |
                            Format-Table | Out-String | Write-Host
                    }
                }
            }
        }

        # Kill the terminal each attempt so the next one starts fresh.
        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
        Get-Process terminal -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3

        if ($acctMismatch) { break }
    }   # foreach ($symbol)

    if (-not $success) {
        if ($acctMismatch) {
            [void]$results.Add(@{ label = $label; error = "account_mismatch_stale_session" })
        } else {
            [void]$results.Add(@{
                label = $label
                error = "no_symbol_worked"
                tried = ($symbolCandidates -join ",")
            })
        }
    }
}

$results | ConvertTo-Json -Depth 5 | Out-File -FilePath "artifacts/mt4_results.json" -Encoding utf8
Write-Host ""
Write-Host "Wrote artifacts/mt4_results.json"
