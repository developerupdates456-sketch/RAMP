param(
    [string[]]$Services = @("api", "frontend"),
    [string]$LockFile = "C:\docker\oem\update.lock",
    [string]$StateFile = "C:\docker\oem\last-good-images.json",
    [string]$LogDir = "C:\docker\oem\logs",
    [int]$LockTtlMinutes = 60,
    [int]$HealthTimeoutSeconds = 240
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$DockerDir = Join-Path $RepoRoot "docker"
$Date = Get-Date -Format "yyyy-MM-dd"
$LogFile = Join-Path $LogDir "docker-update-$Date.log"

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path $LockFile -Parent) -Force | Out-Null

function Write-Log([string]$Message) {
    $line = "{0} {1}" -f (Get-Date -Format "s"), $Message
    Add-Content -LiteralPath $LogFile -Value $line
    Write-Host $line
}

function Acquire-Lock {
    if (Test-Path -LiteralPath $LockFile) {
        $lock = Get-Item -LiteralPath $LockFile
        if ($lock.LastWriteTime -gt (Get-Date).AddMinutes(-$LockTtlMinutes)) {
            throw "Another update appears to be active. Lock file: $LockFile"
        }
        Write-Log "Removing stale update lock: $LockFile"
        Remove-Item -LiteralPath $LockFile -Force
    }
    Set-Content -LiteralPath $LockFile -Value ("pid={0}; started={1}" -f $PID, (Get-Date -Format "s")) -Encoding ASCII
}

function Release-Lock {
    if (Test-Path -LiteralPath $LockFile) {
        Remove-Item -LiteralPath $LockFile -Force
    }
}

function Get-ContainerImageId([string]$ContainerName) {
    $id = docker inspect -f "{{.Image}}" $ContainerName 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return $id.Trim()
}

function Get-ServiceImageRef([string]$Service) {
    $config = docker compose -f docker-compose.yml -f docker-compose.prod.yml config --format json | ConvertFrom-Json
    return $config.services.$Service.image
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

function Save-CurrentImages {
    $state = [ordered]@{}
    foreach ($service in $Services) {
        $container = "oem_$service"
        $imageId = Get-ContainerImageId $container
        $imageRef = Get-ServiceImageRef $service
        if ($imageId -and $imageRef) {
            $state[$service] = [ordered]@{
                Container = $container
                ImageRef = $imageRef
                ImageId = $imageId
                CapturedAt = (Get-Date -Format "s")
            }
        }
    }
    $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StateFile -Encoding ASCII
}

function Rollback-Service([string]$Service) {
    Write-Log "Rolling back $Service."
    & (Join-Path $PSScriptRoot "TeamPresence-Rollback.ps1") -Services @($Service) -StateFile $StateFile -LogDir $LogDir
}

Write-Log "TeamPresence safe update started"
Acquire-Lock

Push-Location $DockerDir
try {
    docker info *> $null
    if ($LASTEXITCODE -ne 0) { throw "Docker Engine is not responding." }

    $watchtowerWasRunning = $false
    $watchtowerState = docker inspect -f "{{.State.Running}}" oem_watchtower 2>$null
    if ($LASTEXITCODE -eq 0 -and $watchtowerState.Trim() -eq "true") {
        $watchtowerWasRunning = $true
        Write-Log "Pausing Watchtower to prevent concurrent container updates."
        docker stop oem_watchtower 2>&1 | ForEach-Object { Write-Log $_ }
    }

    Save-CurrentImages
    Write-Log "Recorded current image IDs in $StateFile"

    foreach ($service in $Services) {
        Write-Log "Pulling image for $service."
        docker compose -f docker-compose.yml -f docker-compose.prod.yml pull $service 2>&1 | ForEach-Object { Write-Log $_ }

        Write-Log "Recreating $service without touching dependencies."
        docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --no-deps $service 2>&1 | ForEach-Object { Write-Log $_ }

        $container = "oem_$service"
        if (-not (Wait-ServiceHealthy -ContainerName $container -TimeoutSeconds $HealthTimeoutSeconds)) {
            Write-Log "$service did not become healthy. Capturing logs before rollback."
            docker logs --tail 200 $container 2>&1 | ForEach-Object { Write-Log $_ }
            Rollback-Service $service
            if (-not (Wait-ServiceHealthy -ContainerName $container -TimeoutSeconds $HealthTimeoutSeconds)) {
                throw "$service rollback did not become healthy."
            }
            throw "$service update failed and was rolled back."
        }

        Write-Log "$service is healthy after update."
    }

    Write-Log "Refreshing nginx after app updates without forcing image update."
    docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --no-deps nginx 2>&1 | ForEach-Object { Write-Log $_ }
    docker compose -f docker-compose.yml -f docker-compose.prod.yml ps 2>&1 | ForEach-Object { Write-Log $_ }
} finally {
    if ($watchtowerWasRunning) {
        Write-Log "Resuming Watchtower."
        docker start oem_watchtower 2>&1 | ForEach-Object { Write-Log $_ }
    }
    Pop-Location
    Release-Lock
}

Write-Log "TeamPresence safe update completed"
