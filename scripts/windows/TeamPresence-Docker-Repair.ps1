param(
    [string]$LogDir = "C:\docker\oem\logs",
    [int]$DockerWaitSeconds = 180
)

$ErrorActionPreference = "Continue"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$DockerDir = Join-Path $RepoRoot "docker"
$Date = Get-Date -Format "yyyy-MM-dd"
$LogFile = Join-Path $LogDir "docker-repair-$Date.log"

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Write-Log([string]$Message) {
    $line = "{0} {1}" -f (Get-Date -Format "s"), $Message
    Add-Content -LiteralPath $LogFile -Value $line
    Write-Host $line
}

function Test-CommandExists([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-DockerEngine {
    try {
        docker info *> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Wait-DockerEngine([int]$TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-DockerEngine) { return $true }
        Start-Sleep -Seconds 5
    }
    return $false
}

function Test-Wsl {
    if (-not (Test-CommandExists "wsl.exe")) { return $false }
    try {
        wsl --status *> $null
        $statusOk = ($LASTEXITCODE -eq 0)
        wsl --version *> $null
        $versionOk = ($LASTEXITCODE -eq 0)
        return ($statusOk -and $versionOk)
    } catch {
        return $false
    }
}

Write-Log "TeamPresence Docker repair started"

if (-not (Test-CommandExists "docker.exe")) {
    Write-Log "Docker CLI is not available. Install or repair Docker Desktop manually."
    exit 1
}

$dockerReady = Test-DockerEngine
if (-not $dockerReady) {
    Write-Log "Docker Engine is not responding."
    $wslReady = Test-Wsl
    if (-not $wslReady) {
        Write-Log "WSL status/version check failed. Running safe WSL shutdown to clear a stuck runtime."
        wsl --shutdown 2>&1 | ForEach-Object { Write-Log $_ }
        Start-Sleep -Seconds 5
    } else {
        Write-Log "WSL is responding."
    }

    $dockerDesktop = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    if (Test-Path -LiteralPath $dockerDesktop) {
        Write-Log "Starting Docker Desktop."
        Start-Process -FilePath $dockerDesktop -WindowStyle Hidden
    } else {
        Write-Log "Docker Desktop executable not found at $dockerDesktop."
    }

    $dockerReady = Wait-DockerEngine -TimeoutSeconds $DockerWaitSeconds
}

if (-not $dockerReady) {
    Write-Log "Docker Engine did not become ready within $DockerWaitSeconds seconds."
    exit 1
}

Write-Log "Docker Engine is ready."
Push-Location $DockerDir
try {
    Write-Log "Ensuring TeamPresence containers are started without forcing recreation."
    docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d 2>&1 | ForEach-Object { Write-Log $_ }
    docker compose -f docker-compose.yml -f docker-compose.prod.yml ps 2>&1 | ForEach-Object { Write-Log $_ }
} finally {
    Pop-Location
}

Write-Log "Running diagnostics snapshot."
& (Join-Path $PSScriptRoot "TeamPresence-Docker-Diagnostics.ps1") -LogDir $LogDir | Out-Null
Write-Log "TeamPresence Docker repair completed"
