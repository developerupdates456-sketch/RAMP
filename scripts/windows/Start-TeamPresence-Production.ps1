param(
    [string]$LogDir = "C:\docker\oem\logs",
    [int]$HealthTimeoutSeconds = 240
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$DockerDir = Join-Path $RepoRoot "docker"
$Date = Get-Date -Format "yyyy-MM-dd"
$LogFile = Join-Path $LogDir "docker-startup-$Date.log"

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Write-Log([string]$Message) {
    $line = "{0} {1}" -f (Get-Date -Format "s"), $Message
    Add-Content -LiteralPath $LogFile -Value $line
    Write-Host $line
}

function Wait-ServiceHealthy([string]$ContainerName, [int]$TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $status = docker inspect -f "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}" $ContainerName 2>$null
        if ($LASTEXITCODE -eq 0 -and $status.Trim() -eq "healthy") {
            return $true
        }
        Start-Sleep -Seconds 5
    }
    return $false
}

Write-Log "TeamPresence production startup started"

docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Log "Docker Engine is not responding. Running safe repair."
    & (Join-Path $PSScriptRoot "TeamPresence-Docker-Repair.ps1") -LogDir $LogDir
}

Push-Location $DockerDir
try {
    docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d 2>&1 | ForEach-Object { Write-Log $_ }

    foreach ($container in @("oem_mysql", "oem_api", "oem_frontend", "oem_nginx")) {
        if (-not (Wait-ServiceHealthy -ContainerName $container -TimeoutSeconds $HealthTimeoutSeconds)) {
            docker logs --tail 120 $container 2>&1 | ForEach-Object { Write-Log $_ }
            throw "$container did not become healthy within $HealthTimeoutSeconds seconds."
        }
        Write-Log "$container is healthy."
    }

    docker compose -f docker-compose.yml -f docker-compose.prod.yml ps 2>&1 | ForEach-Object { Write-Log $_ }
} finally {
    Pop-Location
}

Write-Log "TeamPresence production startup completed"
