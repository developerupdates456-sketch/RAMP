# update-production.ps1 - Manual safe update for TeamPresence

function Write-Info([string]$Message) {
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Success([string]$Message) {
    Write-Host "[SUCCESS] $Message" -ForegroundColor Green
}

Write-Info "Checking for TeamPresence updates with rollback protection..."

# Set environment variables
$env:WATCHTOWER_AUTH_FILE = Join-Path $PSScriptRoot "..\..\docker\watchtower-auth.json"
$env:REGISTRY = "ghcr.io"
$env:IMAGE_BASE = "teampresence-production/ramp_linux"

& (Join-Path $PSScriptRoot "TeamPresence-Safe-Update.ps1")
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Safe update failed. Review C:\docker\oem\logs\docker-update-*.log" -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Success "Update process completed. Checking container status..."
docker ps --filter "name=oem" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
