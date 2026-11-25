$ErrorActionPreference = "Stop"

$root = Join-Path $env:USERPROFILE "shop-deploy"
$python = Join-Path $root ".venv\Scripts\python.exe"
$stateFile = Join-Path $root "process.json"
$taskName = "ShopLocalServer"
$version = $env:GITHUB_SHA

if (-not $version) {
    throw "Run this script through GitHub Actions."
}

# Check the independent server launcher before changing anything.
Get-ScheduledTask -TaskName $taskName -ErrorAction Stop | Out-Null

if (-not (Test-Path "$root\run-server.py")) {
    throw "Server launcher not found."
}
if (-not (Test-Path "$root\data\secret-key.txt")) {
    throw "Session key not found."
}

$releaseName = "$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
$release = Join-Path $root "releases\$releaseName"

New-Item -ItemType Directory -Force -Path $release | Out-Null
Expand-Archive "dist\shop.zip" -DestinationPath $release -Force

& $python -m pip install -r "$release\requirements.txt"
if ($LASTEXITCODE -ne 0) {
    throw "Dependency installation failed."
}

# Stop the scheduled server and wait for its port to become free.
Stop-ScheduledTask -TaskName $taskName

for ($attempt = 0; $attempt -lt 20; $attempt++) {
    $listener = Get-NetTCPConnection -LocalPort 8001 -State Listen `
        -ErrorAction SilentlyContinue

    if (-not $listener) {
        break
    }
    Start-Sleep -Seconds 1
}

if ($listener) {
    throw "Port 8001 is still occupied. No unrelated processes were stopped."
}

# The launcher reads this file to select the new release.
@{
    appFile = Join-Path $release "app.py"
    version = $version
} | ConvertTo-Json | Set-Content $stateFile -Encoding UTF8

Start-ScheduledTask -TaskName $taskName

$healthy = $false
for ($attempt = 0; $attempt -lt 30; $attempt++) {
    Start-Sleep -Seconds 1
    try {
        $health = Invoke-RestMethod `
            -Uri "http://127.0.0.1:8001/health" -TimeoutSec 2

        if ($health.status -eq "ok" -and $health.version -eq $version) {
            $healthy = $true
            break
        }
    }
    catch {}
}

if (-not $healthy) {
    Get-Content "$root\logs\server.log" -Tail 30 -ErrorAction SilentlyContinue
    throw "Deployment health check failed."
}

Write-Output "Deployment successful: $version"
Write-Output "Shop URL: http://127.0.0.1:8001"