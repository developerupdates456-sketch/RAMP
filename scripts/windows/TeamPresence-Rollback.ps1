param(
    [string[]]$Services = @("api", "frontend"),
    [string]$StateFile = "C:\docker\oem\last-good-images.json",
    [string]$LogDir = "C:\docker\oem\logs"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$DockerDir = Join-Path $RepoRoot "docker"
$Date = Get-Date -Format "yyyy-MM-dd"
$LogFile = Join-Path $LogDir "docker-rollback-$Date.log"

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Write-Log([string]$Message) {
    $line = "{0} {1}" -f (Get-Date -Format "s"), $Message
    Add-Content -LiteralPath $LogFile -Value $line
    Write-Host $line
}

if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
    throw "Rollback state file not found: $StateFile"
}

$state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json

Push-Location $DockerDir
try {
    foreach ($service in $Services) {
        $entry = $state.$service
        if (-not $entry -or -not $entry.ImageRef -or -not $entry.ImageId) {
            Write-Log "No rollback image recorded for $service; skipping."
            continue
        }

        Write-Log "Restoring $service to image id $($entry.ImageId)."
        docker image inspect $entry.ImageId *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "Previous image for $service is no longer present locally: $($entry.ImageId)"
        }

        docker tag $entry.ImageId $entry.ImageRef
        docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --no-deps $service
    }

    docker compose -f docker-compose.yml -f docker-compose.prod.yml ps
} finally {
    Pop-Location
}

Write-Log "Rollback completed"
