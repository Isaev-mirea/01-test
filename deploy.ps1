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

Stop-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 2

$listeners = @(Get-NetTCPConnection -LocalPort 8001 -State Listen `
    -ErrorAction SilentlyContinue)

if ($listeners.Count -gt 0) {
    $previous = Get-Content $stateFile -Raw | ConvertFrom-Json
    $previousApp = [string]$previous.appFile
    $releaseRoot = Join-Path $root "releases\"

    if (-not $previousApp.StartsWith(
        $releaseRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Previous application path is outside the deployment folder."
    }

    $processIds = @($listeners |
        Select-Object -ExpandProperty OwningProcess -Unique)

    # Validate every listener before stopping any process.
    foreach ($processId in $processIds) {
        $process = Get-CimInstance Win32_Process `
            -Filter "ProcessId = $processId"

        if (-not $process) {
            continue
        }

        $matchesApp = $process.CommandLine -and
            ($process.CommandLine.IndexOf(
                $previousApp,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0)

        if ($process.Name -notmatch '^python(w)?\.exe$' -or -not $matchesApp) {
            throw "Port 8001 belongs to another application. Nothing stopped."
        }
    }

    foreach ($processId in $processIds) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    }
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