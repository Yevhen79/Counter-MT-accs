# Install every broker terminal referenced by config.json, once per unique
# installer_url, and write terminals.json mapping each installer_url to the
# folder its terminal landed in.
#
# Broker installers ignore documented silent flags and pop a GUI, so each
# flag is tried in turn while we poll for the terminal to appear; the first
# flag that produces one wins, and only leftover GUI windows are killed
# afterwards. We poll DURING the install (not just after a fixed timeout)
# because some broker builds take well over 30s to lay down terminal64.exe —
# killing early would abort a working install. The install folder is found
# by diffing the set of terminal executables before/after (robust to
# whatever folder name the broker uses).

$ErrorActionPreference = "Stop"

if (-not (Test-Path "config.json")) {
    Write-Error "config.json missing — run the Convert config.yaml step first."
    exit 1
}
$config = Get-Content -Raw -Path "config.json" | ConvertFrom-Json

# Roots an MT5 (64-bit) install might land in. Newer broker installers /
# runner images sometimes drop the terminal in a per-user location instead
# of Program Files, so scan the profile/appdata roots too.
function Get-Mt5Roots {
    $roots = @("C:\Program Files", "C:\Program Files (x86)")
    foreach ($e in @($env:LOCALAPPDATA, $env:APPDATA, $env:ProgramData, $env:USERPROFILE)) {
        if ($e -and (Test-Path $e)) { $roots += $e }
    }
    if (Test-Path "C:\Users") { $roots += "C:\Users" }
    return ($roots | Select-Object -Unique)
}

function Get-TerminalExes($platform) {
    $found = @()
    if ($platform -eq "mt5") {
        foreach ($root in (Get-Mt5Roots)) {
            if (-not (Test-Path $root)) { continue }
            $found += Get-ChildItem $root -Filter "terminal64.exe" -Recurse -Depth 5 -ErrorAction SilentlyContinue |
                      ForEach-Object { $_.FullName }
        }
    } else {
        foreach ($root in @("C:\Program Files", "C:\Program Files (x86)")) {
            if (-not (Test-Path $root)) { continue }
            # MT4 = terminal.exe in a folder that has no terminal64.exe
            # (MT5 ships a 32-bit terminal.exe too; exclude those).
            $found += Get-ChildItem $root -Filter "terminal.exe" -Recurse -Depth 5 -ErrorAction SilentlyContinue |
                      Where-Object { -not (Test-Path (Join-Path $_.DirectoryName "terminal64.exe")) } |
                      ForEach-Object { $_.FullName }
        }
    }
    return @($found | Select-Object -Unique)
}

# On failure, dump where (if anywhere) a terminal64.exe exists and what the
# installer left behind, so the next run's log tells us definitively what
# changed (e.g. a new runner image installing MT5 to a different location).
function Dump-Mt5Diagnostics {
    Write-Host "  --- MT5 diagnostics ---"
    try {
        $hits = @()
        foreach ($root in @("C:\Program Files", "C:\Program Files (x86)", $env:LOCALAPPDATA, $env:APPDATA, $env:ProgramData, "C:\Users")) {
            if ($root -and (Test-Path $root)) {
                $hits += Get-ChildItem $root -Filter "terminal64.exe" -Recurse -Depth 6 -ErrorAction SilentlyContinue |
                         ForEach-Object { $_.FullName }
            }
        }
        $hits = $hits | Select-Object -Unique
        if ($hits.Count -gt 0) {
            Write-Host "  terminal64.exe found at:"
            $hits | ForEach-Object { Write-Host "    $_" }
        } else {
            Write-Host "  no terminal64.exe found anywhere under Program Files / user profile"
        }
    } catch { Write-Host "  diag scan failed: $_" }
    try {
        Write-Host "  new dirs in C:\Program Files (top level):"
        Get-ChildItem "C:\Program Files" -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-30) } |
            ForEach-Object { Write-Host "    $($_.FullName)  (modified $($_.LastWriteTime))" }
    } catch {}
    Write-Host "  --- end diagnostics ---"
}

function Is-PE($path) {
    if (-not (Test-Path $path)) { return $false }
    try {
        $fs = [System.IO.File]::OpenRead($path)
        $b1 = $fs.ReadByte(); $b2 = $fs.ReadByte(); $fs.Close()
        return ($b1 -eq 0x4D -and $b2 -eq 0x5A)   # "MZ"
    } catch { return $false }
}

function Download-Installer($url, $out) {
    $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -TimeoutSec 180 `
                -UserAgent $ua -Headers @{ "Accept" = "*/*"; "Accept-Language" = "en-US,en;q=0.9" }
        } catch {
            Write-Warning "  download attempt $attempt failed: $_"
        }
        if ((Test-Path $out) -and (Is-PE $out)) {
            Write-Host ("  downloaded {0:N0} bytes (attempt {1})" -f (Get-Item $out).Length, $attempt)
            return $true
        }
        # Likely a Cloudflare 'Just a moment...' HTML challenge — back off
        # (these are usually rate-based and clear after a pause) and retry.
        $wait = [int][Math]::Pow(2, $attempt) * 5
        Write-Warning "  attempt $attempt did not yield a PE binary (Cloudflare?), waiting ${wait}s..."
        Start-Sleep -Seconds $wait
    }
    return $false
}

function Find-NewTerminal($platform, $before, $dirHint) {
    $after = Get-TerminalExes $platform
    $new = @($after | Where-Object { $before -notcontains $_ })
    if ($new.Count -eq 0) { return $null }
    $hit = $new | Where-Object { (Split-Path $_ -Parent) -match [Regex]::Escape($dirHint) } | Select-Object -First 1
    if (-not $hit) { $hit = $new[0] }
    return $hit
}

function Kill-Installers {
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match "(?i)(setup|install|forexclub|libertex|metatrader|metaquotes|fcmt)"
    } | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {} }
}

# Run the installer with one flag, polling for the terminal WHILE it installs.
# Returns the install dir as soon as the terminal appears (without killing the
# installer), or $null after the timeout. Some broker installers take well
# over 30s to lay down terminal64.exe, so killing early aborts the install —
# hence the in-flight polling and the longer window.
function Install-With-Flag($installer, $flag, $platform, $before, $dirHint, $timeoutSec = 100) {
    Write-Host "  flag '$flag' (up to ${timeoutSec}s, polling)"
    $p = Start-Process -FilePath $installer -ArgumentList $flag -PassThru -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    $waited = 0
    while ($waited -lt $timeoutSec) {
        Start-Sleep -Seconds 5
        $waited += 5
        $hit = Find-NewTerminal $platform $before $dirHint
        if ($hit) { Write-Host "    -> terminal appeared after ${waited}s"; return (Split-Path $hit -Parent) }
        if ($p.HasExited) {
            Write-Host "    installer exited (code $($p.ExitCode)) after ${waited}s"
            Start-Sleep -Seconds 3   # let the filesystem settle after exit
            $hit = Find-NewTerminal $platform $before $dirHint
            if ($hit) { return (Split-Path $hit -Parent) }
            break   # installer finished without producing a terminal; try next flag
        }
    }
    # Not found (timeout or clean exit): kill any leftover GUI, then re-check
    # once — the files may have landed just as we killed the wrapper window.
    Kill-Installers
    Start-Sleep -Seconds 3
    $hit = Find-NewTerminal $platform $before $dirHint
    if ($hit) { return (Split-Path $hit -Parent) }
    return $null
}

# Unique installers, preserving the platform/dir_hint of the first account
# that references each.
$installers = [ordered]@{}
foreach ($acc in $config.accounts) {
    $url = $acc.installer_url
    if ([string]::IsNullOrWhiteSpace($url)) { continue }
    if (-not $installers.Contains($url)) {
        $installers[$url] = [pscustomobject]@{
            url = $url; platform = $acc.platform; dir_hint = $acc.dir_hint
        }
    }
}

$results = @()
$i = 0
foreach ($url in $installers.Keys) {
    $t = $installers[$url]
    $i++
    Write-Host ""
    Write-Host "=== Installing terminal $i/$($installers.Count): $url (platform=$($t.platform), hint=$($t.dir_hint)) ==="

    # Small spacing between installers to avoid bursty requests tripping
    # the brokers' Cloudflare rate checks.
    if ($i -gt 1) { Start-Sleep -Seconds 8 }

    $before = Get-TerminalExes $t.platform

    $file = Join-Path $env:RUNNER_TEMP ("setup_{0}.exe" -f $i)

    # If the installer is committed under installers/<filename> (e.g. for a
    # host behind a Cloudflare JS challenge that Invoke-WebRequest cannot
    # pass), use it directly and skip the download.
    $fname = [System.IO.Path]::GetFileName(([uri]$url).AbsolutePath)
    $localFile = Join-Path (Get-Location).Path ("installers/" + $fname)
    if ((Test-Path $localFile) -and (Is-PE $localFile)) {
        Write-Host "  using committed installer: $localFile"
        Copy-Item $localFile $file -Force
    } elseif (-not (Download-Installer $url $file)) {
        Write-Warning "  could not download a valid installer for $url, and no committed installers/$fname — skipping."
        $results += [pscustomobject]@{ url = $url; platform = $t.platform; dir_hint = $t.dir_hint; dir = $null }
        continue
    }

    $dir = $null
    foreach ($flag in @("/auto", "/S", "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-", "/silent", "/quiet")) {
        $dir = Install-With-Flag $file $flag $t.platform $before $t.dir_hint 100
        if ($dir) { break }
    }

    if ($dir) {
        Write-Host "  installed at: $dir"
        try { Add-MpPreference -ExclusionPath $dir -ErrorAction SilentlyContinue } catch {}
    } else {
        Write-Warning "  could not locate installed terminal for $url"
        if ($t.platform -eq "mt5") { Dump-Mt5Diagnostics }
    }
    $results += [pscustomobject]@{ url = $url; platform = $t.platform; dir_hint = $t.dir_hint; dir = $dir }
}

# Kill any auto-launched terminals and relax Defender (suspected launch
# interference) for the whole run.
Get-Process terminal, terminal64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
try { Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue } catch {}

$results | ConvertTo-Json -Depth 5 | Out-File -FilePath "terminals.json" -Encoding utf8
Write-Host ""
Write-Host "Wrote terminals.json:"
Get-Content terminals.json -Raw | Write-Host
