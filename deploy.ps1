$ErrorActionPreference = "Stop"

$root = Join-Path $env:USERPROFILE "shop-deploy"
$python = Join-Path $root ".venv\Scripts\python.exe"
$stateFile = Join-Path $root "process.json"
$keyFile = Join-Path $root "data\secret-key.txt"

$version = $env:GITHUB_SHA
if (-not $version) {
    throw "Run this script through GitHub Actions."
}

$releaseName = "$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
$release = Join-Path $root "releases\$releaseName"
$appFile = Join-Path $release "app.py"

if (-not (Test-Path $python)) {
    throw "Deployment Python environment not found: $python"
}

New-Item -ItemType Directory -Force -Path $release | Out-Null
Expand-Archive -Path "dist\shop.zip" -DestinationPath $release -Force

# Prepare dependencies before stopping the previous version.
& $python -m pip install -r "$release\requirements.txt"
if ($LASTEXITCODE -ne 0) {
    throw "Dependency installation failed."
}

if (-not (Test-Path $keyFile)) {
    $key = [guid]::NewGuid().ToString("N") + [guid]::NewGuid().ToString("N")
    Set-Content -Path $keyFile -Value $key -Encoding ASCII
}

# Stop only the application recorded by this deployment script.
if (Test-Path $stateFile) {
    $previous = Get-Content $stateFile -Raw | ConvertFrom-Json
    $oldProcess = Get-CimInstance Win32_Process `
        -Filter "ProcessId = $($previous.processId)"

    if ($oldProcess) {
        $matchesApp = $oldProcess.CommandLine -and
            $oldProcess.CommandLine.Contains([string]$previous.appFile)

        if (-not $matchesApp) {
            throw "Saved PID belongs to another process. Deployment stopped."
        }

        Stop-Process -Id $previous.processId -Force
        Wait-Process -Id $previous.processId -Timeout 15 -ErrorAction SilentlyContinue
    }

    Remove-Item $stateFile
}

# Do not stop an unrelated application using this port.
$listener = Get-NetTCPConnection -LocalPort 8001 -State Listen `
    -ErrorAction SilentlyContinue
if ($listener) {
    throw "Port 8001 is occupied. Deployment stopped."
}

$env:PORT = "8001"
$env:SHOP_DATABASE = Join-Path $root "data\shop.db"
$env:SHOP_SECRET_KEY = (Get-Content $keyFile -Raw).Trim()
$env:BUILD_VERSION = $version

# Keep the deployed server running after the CI job finishes.
$tracking = $env:RUNNER_TRACKING_ID
Remove-Item Env:\RUNNER_TRACKING_ID -ErrorAction SilentlyContinue

try {
    $server = Start-Process -FilePath $python `
        -ArgumentList "`"$appFile`"" `
        -WorkingDirectory $release `
        -RedirectStandardOutput "$root\logs\$releaseName.out.log" `
        -RedirectStandardError "$root\logs\$releaseName.err.log" `
        -WindowStyle Hidden -PassThru
}
finally {
    if ($null -ne $tracking) {
        $env:RUNNER_TRACKING_ID = $tracking
    }
    Remove-Item Env:\SHOP_SECRET_KEY -ErrorAction SilentlyContinue
}

@{
    processId = $server.Id
    appFile = $appFile
    version = $version
} | ConvertTo-Json | Set-Content $stateFile -Encoding UTF8

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
    Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    Remove-Item $stateFile -ErrorAction SilentlyContinue
    Get-Content "$root\logs\$releaseName.err.log" -ErrorAction SilentlyContinue
    throw "Deployment health check failed."
}

Write-Output "Deployment successful: $version"
Write-Output "Shop URL: http://127.0.0.1:8001"