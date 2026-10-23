[CmdletBinding()]
param(
    [string]$Registry = "ghcr.io",
    [string]$ImageBase = "teampresence-production/ramp_linux",
    [string]$Tag = "latest",
    [switch]$Push
)

$ErrorActionPreference = "Stop"

$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$ApiImage = "$Registry/$ImageBase-api`:$Tag"
$FrontendImage = "$Registry/$ImageBase-frontend`:$Tag"

function Write-Info([string]$Message) {
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker is required to build the production images."
}

Write-Info "Building API image: $ApiImage"
Write-Info "The API Dockerfile compiles backend/app.py into a Nuitka one-file binary."
& docker build --file (Join-Path $RepositoryRoot "docker\Dockerfile.prod") --tag $ApiImage $RepositoryRoot
if ($LASTEXITCODE -ne 0) { throw "API image build failed." }

Write-Info "Building frontend image: $FrontendImage"
& docker build --file (Join-Path $RepositoryRoot "docker\Dockerfile.prod.frontend") --tag $FrontendImage (Join-Path $RepositoryRoot "frontend")
if ($LASTEXITCODE -ne 0) { throw "Frontend image build failed." }

if ($Push) {
    Write-Info "Pushing production images to $Registry..."
    & docker push $ApiImage
    if ($LASTEXITCODE -ne 0) { throw "API image push failed." }
    & docker push $FrontendImage
    if ($LASTEXITCODE -ne 0) { throw "Frontend image push failed." }
}

Write-Host "[SUCCESS] Built API and frontend images with tag '$Tag'." -ForegroundColor Green
