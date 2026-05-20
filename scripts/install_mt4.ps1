# Install MT4 from the broker's installer URL configured in config.yaml.
#
# Accepts either a direct .exe URL or a download page URL. The downloader
# probes the response: if the body starts with the PE magic bytes (MZ), it
# is treated as the installer. Otherwise it is parsed as HTML and the first
# plausible .exe link is followed.
#
# If the URL is empty (or unreachable / no installer found), exit 0 with a
# warning so the workflow can continue and at least report MT5 counts.

$ErrorActionPreference = "Stop"

function Ensure-Module($name) {
    if (-not (Get-Module -ListAvailable -Name $name)) {
        Install-Module $name -Force -Scope CurrentUser -AllowClobber | Out-Null
    }
    Import-Module $name -Force
}

function Is-PE($path) {
    if (-not (Test-Path $path)) { return $false }
    try {
        $fs = [System.IO.File]::OpenRead($path)
        $b1 = $fs.ReadByte(); $b2 = $fs.ReadByte()
        $fs.Close()
        return ($b1 -eq 0x4D -and $b2 -eq 0x5A)   # "MZ"
    } catch { return $false }
}

function Fetch-Installer($url, $out) {
    $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
    Write-Host "Fetching: $url"
    try {
        Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -UserAgent $ua -TimeoutSec 60 -MaximumRedirection 10
    } catch {
        Write-Warning "Fetch failed: $_"
        return $false
    }
    Write-Host ("Downloaded {0:N0} bytes from {1}" -f (Get-Item $out).Length, $url)
    return $true
}

Ensure-Module powershell-yaml

$config = (Get-Content -Raw -Path "config.yaml") | ConvertFrom-Yaml
$url = $config.mt4_installer_url

if ([string]::IsNullOrWhiteSpace($url)) {
    Write-Warning "config.yaml: mt4_installer_url is empty — skipping MT4 install."
    exit 0
}

$installer = "$env:RUNNER_TEMP\mt4setup.exe"
$probe     = "$env:RUNNER_TEMP\mt4_probe.bin"

if (-not (Fetch-Installer $url $probe)) {
    Write-Warning "Initial fetch failed — MT4 step will be skipped."
    exit 0
}

if (Is-PE $probe) {
    Write-Host "Response is a PE binary — using it as the installer."
    Move-Item $probe $installer -Force
} else {
    Write-Host "Response is not a PE binary — assuming HTML, scraping for .exe link..."
    $html = Get-Content -Raw -Path $probe
    Remove-Item $probe -Force
    Write-Host ("HTML length: {0:N0} chars" -f $html.Length)

    # Order patterns from most-specific to least so we prefer broker-branded files.
    $patterns = @(
        '(?i)https?://[^\s"''<>]*(?:libertex|forexclub)[^\s"''<>]*\.exe',
        '(?i)https?://[^\s"''<>]*mt4[^\s"''<>]*\.exe',
        '(?i)https?://[^\s"''<>]+\.exe'
    )

    $exeUrl = $null
    foreach ($p in $patterns) {
        $m = [regex]::Matches($html, $p)
        if ($m.Count -gt 0) {
            $exeUrl = $m[0].Value
            Write-Host "Found candidate installer URL: $exeUrl"
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($exeUrl)) {
        Write-Warning "No .exe link found on the page. MT4 step will be skipped."
        Write-Warning "Inspect the HTML manually (or use DevTools on the page) and paste the direct .exe URL into config.yaml -> mt4_installer_url."
        exit 0
    }

    if (-not (Fetch-Installer $exeUrl $installer)) {
        Write-Warning "Downloading $exeUrl failed."
        exit 0
    }
    if (-not (Is-PE $installer)) {
        Write-Warning "Followed link did not return a PE binary either. Skipping."
        exit 0
    }
}

# Try common silent-install flags. NSIS uses /S; Inno Setup uses /VERYSILENT;
# MSI uses /quiet; MetaQuotes' own bundle uses /auto.
$flagsToTry = @("/auto", "/S", "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART", "/silent", "/quiet")

$candidates = @(
    "C:\Program Files (x86)\Libertex MetaTrader 4\terminal.exe",
    "C:\Program Files\Libertex MetaTrader 4\terminal.exe",
    "C:\Program Files (x86)\ForexClub MetaTrader 4\terminal.exe",
    "C:\Program Files\ForexClub MetaTrader 4\terminal.exe",
    "C:\Program Files (x86)\Libertex MT4\terminal.exe",
    "C:\Program Files\Libertex MT4\terminal.exe",
    "C:\Program Files (x86)\MetaTrader 4\terminal.exe",
    "C:\Program Files\MetaTrader 4\terminal.exe"
)

$installed = $null
foreach ($flag in $flagsToTry) {
    Write-Host "Trying silent install with flags: $flag"
    Start-Process -FilePath $installer -ArgumentList $flag -PassThru -Wait -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 5

    foreach ($c in $candidates) {
        if (Test-Path $c) {
            Write-Host "MT4 installed at: $c"
            $installed = $c
            break
        }
    }
    if ($installed) { break }
}

if (-not $installed) {
    # Final fallback: search Program Files for any terminal.exe whose parent
    # dir name hints at MT4.
    Write-Host "No known install location matched — searching Program Files..."
    $hits = @()
    foreach ($root in @("C:\Program Files", "C:\Program Files (x86)")) {
        if (Test-Path $root) {
            $hits += Get-ChildItem -Path $root -Filter "terminal.exe" -Recurse -ErrorAction SilentlyContinue |
                Where-Object {
                    $parent = Split-Path $_.DirectoryName -Leaf
                    $parent -match "(?i)(MT4|MetaTrader\s*4|Libertex|ForexClub)" -and
                    -not (Test-Path (Join-Path $_.DirectoryName "terminal64.exe"))
                }
        }
    }
    if ($hits.Count -gt 0) {
        $installed = $hits[0].FullName
        Write-Host "Discovered MT4 at: $installed"
    }
}

if (-not $installed) {
    Write-Warning "MT4 silent install did not produce terminal.exe anywhere obvious."
    Write-Warning "MT4 counting will be skipped this run."
    exit 0
}

$mt4Dir = Split-Path $installed -Parent
"MT4_DIR=$mt4Dir" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
