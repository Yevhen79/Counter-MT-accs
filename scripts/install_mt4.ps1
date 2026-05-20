# Install MT4 from the broker's installer URL configured in config.yaml.
# If the URL is empty, exit 0 with a warning so the workflow can continue
# and at least report MT5 counts.

$ErrorActionPreference = "Stop"

function Ensure-Module($name) {
    if (-not (Get-Module -ListAvailable -Name $name)) {
        Install-Module $name -Force -Scope CurrentUser -AllowClobber | Out-Null
    }
    Import-Module $name -Force
}

Ensure-Module powershell-yaml

$config = (Get-Content -Raw -Path "config.yaml") | ConvertFrom-Yaml
$url = $config.mt4_installer_url

if ([string]::IsNullOrWhiteSpace($url)) {
    Write-Warning "config.yaml: mt4_installer_url is empty — skipping MT4 install."
    Write-Warning "Set it to the ForexClub MT4 installer URL to enable MT4 counting."
    exit 0
}

Write-Host "Downloading MT4 installer from $url ..."
$installer = "$env:RUNNER_TEMP\mt4setup.exe"
Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing
Write-Host ("Downloaded: {0:N0} bytes" -f (Get-Item $installer).Length)

# Try common silent-install flags. Different brokers use different installers
# (NSIS uses /S, Inno Setup uses /VERYSILENT, MSI uses /quiet).
$flagsToTry = @("/auto", "/S", "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART", "/silent", "/quiet")

$installed = $false
foreach ($flag in $flagsToTry) {
    Write-Host "Trying silent install with flags: $flag"
    $proc = Start-Process -FilePath $installer -ArgumentList $flag -PassThru -Wait -ErrorAction SilentlyContinue
    # Wait a moment for filesystem to settle.
    Start-Sleep -Seconds 5

    # Look for terminal.exe in common install locations.
    $candidates = @(
        "C:\Program Files (x86)\ForexClub MetaTrader 4\terminal.exe",
        "C:\Program Files\ForexClub MetaTrader 4\terminal.exe",
        "C:\Program Files (x86)\Libertex MetaTrader 4\terminal.exe",
        "C:\Program Files\Libertex MetaTrader 4\terminal.exe",
        "C:\Program Files (x86)\MetaTrader 4\terminal.exe",
        "C:\Program Files\MetaTrader 4\terminal.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            Write-Host "MT4 installed at: $c"
            "MT4_DIR=$([System.IO.Path]::GetDirectoryName($c))" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
            $installed = $true
            break
        }
    }
    if ($installed) { break }
}

if (-not $installed) {
    Write-Warning "MT4 silent install did not produce terminal.exe in any known location."
    Write-Warning "MT4 counting will be skipped this run. Inspect installer flags or path."
    # Don't fail the whole workflow.
    exit 0
}
