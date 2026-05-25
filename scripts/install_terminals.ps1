# Install every broker terminal referenced by config.json, once per unique
# installer_url, and write terminals.json mapping each installer_url to the
# folder its terminal landed in.
#
# Broker installers ignore documented silent flags and pop a GUI, so each
# flag is tried with a short timeout and the leftover window is killed —
# one of them completes the install in the background. The install folder
# is found by diffing the set of terminal executables before/after (robust
# to whatever folder name the broker uses).

$ErrorActionPreference = "Stop"

if (-not (Test-Path "config.json")) {
    Write-Error "config.json missing — run the Convert config.yaml step first."
    exit 1
}
$config = Get-Content -Raw -Path "config.json" | ConvertFrom-Json

function Get-TerminalExes($platform) {
    $found = @()
    foreach ($root in @("C:\Program Files", "C:\Program Files (x86)")) {
        if (-not (Test-Path $root)) { continue }
        if ($platform -eq "mt5") {
            $found += Get-ChildItem $root -Filter "terminal64.exe" -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                      ForEach-Object { $_.FullName }
        } else {
            # MT4 = terminal.exe in a folder that has no terminal64.exe
            # (MT5 ships a 32-bit terminal.exe too; exclude those).
            $found += Get-ChildItem $root -Filter "terminal.exe" -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                      Where-Object { -not (Test-Path (Join-Path $_.DirectoryName "terminal64.exe")) } |
                      ForEach-Object { $_.FullName }
        }
    }
    return @($found)
}

function Try-SilentInstall($installer, $flag, $timeoutSec) {
    Write-Host "  flag '$flag' (timeout ${timeoutSec}s)"
    $p = Start-Process -FilePath $installer -ArgumentList $flag -PassThru -ErrorAction SilentlyContinue
    if (-not $p) { return }
    $w = 0
    while (-not $p.HasExited -and $w -lt $timeoutSec) { Start-Sleep -Seconds 3; $w += 3 }
    if (-not $p.HasExited) {
        Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match "(?i)(setup|install|forexclub|libertex|metatrader|metaquotes|fcmt)"
        } | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {} }
        Start-Sleep -Seconds 2
    }
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

    $before = Get-TerminalExes $t.platform

    $file = Join-Path $env:RUNNER_TEMP ("setup_{0}.exe" -f $i)
    try {
        Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing -TimeoutSec 180 `
            -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
        Write-Host ("  downloaded {0:N0} bytes" -f (Get-Item $file).Length)
    } catch {
        Write-Warning "  download failed: $_"
        $results += [pscustomobject]@{ url = $url; platform = $t.platform; dir_hint = $t.dir_hint; dir = $null }
        continue
    }

    $dir = $null
    foreach ($flag in @("/auto", "/S", "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-", "/silent", "/quiet")) {
        Try-SilentInstall $file $flag 30
        # Look for a newly-appeared terminal exe that also matches the hint.
        $after = Get-TerminalExes $t.platform
        $new = @($after | Where-Object { $before -notcontains $_ })
        $hit = $new | Where-Object { (Split-Path $_ -Parent) -match [Regex]::Escape($t.dir_hint) } | Select-Object -First 1
        if (-not $hit -and $new.Count -gt 0) { $hit = $new[0] }
        if ($hit) { $dir = Split-Path $hit -Parent; break }
    }

    if ($dir) {
        Write-Host "  installed at: $dir"
        try { Add-MpPreference -ExclusionPath $dir -ErrorAction SilentlyContinue } catch {}
    } else {
        Write-Warning "  could not locate installed terminal for $url"
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
