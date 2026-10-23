# setup-production.ps1 - Automated Setup for RMM Platform on Windows

$BaseDir = "C:\docker\oem"
$EdgeUploads = "C:\edge\uploads"
$UploadSubDirs = @(
    "$EdgeUploads\tenant_logo"
)
$Dirs = @(
    "$BaseDir\mysql\data",
    "$BaseDir\mysql\backups",
    "$BaseDir\logs",
    "$BaseDir\certs",
    "$BaseDir\domain-ssl-backups",
    $EdgeUploads
) + $UploadSubDirs

$EnvFileRoot = Join-Path $PSScriptRoot "..\.env"
$EnvFileDocker = Join-Path $PSScriptRoot "..\..\docker\.env"
$EnvExample = Join-Path $PSScriptRoot "..\..\docker\.env.example"
$AuthFile = Join-Path $PSScriptRoot "..\..\docker\watchtower-auth.json"

function Write-Info([string]$Message) {
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Success([string]$Message) {
    Write-Host "[SUCCESS] $Message" -ForegroundColor Green
}

# 1. Ensure Directories
Write-Info "Ensuring directories exist in $BaseDir..."
foreach ($dir in $Dirs) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# 2. Check for Docker
function Install-Docker {
    Write-Host "[WARNING] Docker not found on this system!" -ForegroundColor Yellow
    $choice = Read-Host "Would you like to attempt to install Docker Desktop automatically and restart? (y/n)"
    if ($choice -eq 'y') {
        Write-Info "Ensuring WSL is up to date..."
        wsl --update
        
        Write-Info "Attempting to install Docker Desktop via winget..."
        if (Get-Command "winget" -ErrorAction SilentlyContinue) {
            Start-Process winget -ArgumentList "install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements" -Wait
            Write-Success "Docker Desktop installation finished."
            
            $batPath = Join-Path $PSScriptRoot "run-setup.bat"
            Write-Info "Setting up auto-resume for: $batPath"
            
            $registryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
            $resumeCommand = "cmd.exe /c `"$batPath`""
            Set-ItemProperty -Path $registryPath -Name "RMMSetupResume" -Value $resumeCommand
            
            Write-Host "`n[IMPORTANT] The computer will RESTART in 10 seconds." -ForegroundColor Red
            Write-Host "After you log back in, the setup will continue automatically.`n" -ForegroundColor Cyan
            
            for ($i = 10; $i -gt 0; $i--) {
                Write-Host "Restarting in $i... " -NoNewline
                Start-Sleep -Seconds 1
            }
            
            Restart-Computer -Force
            exit 0
        } else {
            Write-Error "Winget not found. Please install Docker Desktop manually."
        }
    } else {
        Write-Error "Docker is required. Please install it and try again."
    }
    exit 1
}

Write-Info "Checking for Docker..."
if (-not (Get-Command "docker" -ErrorAction SilentlyContinue)) {
    Install-Docker
}

Write-Info "Checking if Docker daemon is running..."
$dockerRunning = $false
try {
    & docker version --format '{{.Server.Version}}' 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $dockerRunning = $true }
} catch { }

if (-not $dockerRunning) {
    Write-Host "[WARNING] Docker daemon is not running!" -ForegroundColor Yellow
    Write-Info "Attempting to start Docker Desktop..."
    $dockerPath = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    if (Test-Path $dockerPath) {
        Start-Process $dockerPath
        Write-Info "Waiting for Docker daemon to initialize (this may take a minute)..."
        $retryCount = 0
        while (-not $dockerRunning -and $retryCount -lt 20) {
            Write-Host "." -NoNewline
            Start-Sleep -Seconds 5
            try {
                & docker version --format '{{.Server.Version}}' 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) { $dockerRunning = $true }
            } catch { }
            $retryCount++
        }
        Write-Host ""
    } else {
        Write-Error "Docker Desktop not found at $dockerPath. Please start it manually."
        exit 1
    }
}

# 3. Handle .env file
if (Test-Path $EnvFileRoot) {
    Write-Info "Moving .env from root to docker folder..."
    Copy-Item $EnvFileRoot $EnvFileDocker -Force
}

if (-not (Test-Path $EnvFileDocker)) {
    Write-Info "Creating .env file from example..."
    Copy-Item $EnvExample $EnvFileDocker
    Write-Host "[ACTION REQUIRED] Please edit $EnvFileDocker with your production values." -ForegroundColor Yellow
}

# Auto-fix DATABASE_HOST for Docker if it's set to localhost
$envContent = Get-Content $EnvFileDocker
if ($envContent -match "DATABASE_HOST\s*=\s*localhost") {
    Write-Info "Updating DATABASE_HOST from localhost to mysql..."
    $envContent = $envContent -replace "DATABASE_HOST\s*=\s*localhost", "DATABASE_HOST=mysql"
    $envContent | Set-Content $EnvFileDocker
}

# Ensure DOMAIN exists
if ($envContent -notmatch "DOMAIN=") {
    $currentIp = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -like "*Wi-Fi*" -or $_.InterfaceAlias -like "*Ethernet*" } | Select-Object -First 1).IPAddress
    Write-Info "Adding default DOMAIN=$currentIp to .env"
    Add-Content $EnvFileDocker "`nDOMAIN=$currentIp"
    Add-Content $EnvFileDocker "`nALLOWED_ORIGINS=https://$currentIp,http://$currentIp,https://localhost,http://localhost"
}

# CLEANUP: Remove spaces around '=' in .env (Docker requirement)
Write-Info "Cleaning up .env formatting..."
$envContent = Get-Content $EnvFileDocker
$envContent = $envContent -replace '\s*=\s*', '='
$envContent | Set-Content $EnvFileDocker

# The on-premise API reads this public verification key from a read-only mount.
# It is safe to distribute, but the matching private signing key must remain
# only on the cloud license-signing service.
$LicensePublicKeyFile = Join-Path $PSScriptRoot "..\..\docker\public_key.pem"
if (-not (Test-Path -LiteralPath $LicensePublicKeyFile -PathType Leaf) -or (Get-Item -LiteralPath $LicensePublicKeyFile).Length -eq 0) {
    throw "License public key file is missing or empty: $LicensePublicKeyFile. Add the cloud public key before starting Docker Compose."
}

# 3.5 Generate Secrets if missing
$SecretDir = Join-Path $PSScriptRoot "..\..\security\secrets"
if (-not (Test-Path $SecretDir)) {
    New-Item -ItemType Directory -Path $SecretDir -Force | Out-Null
}

$Secrets = @("mysql_root_password", "mysql_app_password", "jwt_secret_key", "encryption_key")
foreach ($s in $Secrets) {
    $sPath = Join-Path $SecretDir $s
    if (-not (Test-Path $sPath)) {
        Write-Info "Generating secret: $s"
        $val = [System.IO.Path]::GetRandomFileName() + [System.IO.Path]::GetRandomFileName()
        # Use ASCII encoding without BOM or Newline for MySQL compatibility
        [System.IO.File]::WriteAllText($sPath, $val, [System.Text.Encoding]::ASCII)
    }
}

# 4. GitHub Auth (Watchtower)
Write-Info "Configuring GitHub Container Registry Authentication..."
$User = if ($env:GHCR_USERNAME) { $env:GHCR_USERNAME } else { "teampresence-production" }
$Token = $env:GHCR_TOKEN
$env:REGISTRY = "ghcr.io"
$env:IMAGE_BASE = "teampresence-production/ramp_linux"

if (-not $Token -and (Test-Path $EnvFileDocker)) {
    $envLines = Get-Content $EnvFileDocker
    foreach ($line in $envLines) {
        if ($line -match "^GHCR_TOKEN=(.*)") {
            $Token = $matches[1].Trim()
            break
        }
    }
}

if (-not $Token) {
    $Token = Read-Host "Enter GHCR token with package read access"
}

Write-Info "Logging into GHCR for host Docker daemon..."
echo $Token | docker login ghcr.io -u $User --password-stdin | Out-Null

# Create Watchtower auth file
$Auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${User}:${Token}"))
$Config = @{ auths = @{ "ghcr.io" = @{ auth = $Auth } } }
$Config | ConvertTo-Json | Out-File -FilePath $AuthFile -Encoding ascii
Write-Success "Authentication configured in $AuthFile"

# 5. Start Deployment
Write-Info "Starting production deployment..."
Set-Location "$PSScriptRoot\..\..\docker"

# Docker requires this source to be a file. If it is missing, Docker Desktop
# creates a directory at that path and the nginx container cannot be started.
$NginxConfig = Join-Path $PSScriptRoot "..\..\nginx\nginx.conf"
if (-not (Test-Path -LiteralPath $NginxConfig -PathType Leaf)) {
    throw "Nginx configuration file is missing or is a directory: $NginxConfig. Restore nginx\\nginx.conf before starting Docker Compose."
}

# Set environment variables for the current session
$env:WATCHTOWER_AUTH_FILE = $AuthFile
$LicensePublicKeyFile = Join-Path $PSScriptRoot "..\..\docker\public_key.pem"
if (Test-Path -LiteralPath $LicensePublicKeyFile -PathType Leaf) {
    $env:LICENSE_PUBLIC_KEY = (Get-Content -LiteralPath $LicensePublicKeyFile -Raw).Trim()
    Write-Info "Loaded license public key from $LicensePublicKeyFile"
} else {
    Write-Warning "License public key file not found: $LicensePublicKeyFile"
}

# Generate temporary SSL certificates to prevent Nginx from crashing on first run
Write-Info "Checking for SSL certificates..."
$CertDir = Join-Path $BaseDir "certs"
New-Item -ItemType Directory -Path $CertDir -Force | Out-Null
docker run --rm -v "${CertDir}:/certs" alpine sh -ec "if [ ! -f /certs/fullchain.pem ] || [ ! -f /certs/privkey.pem ]; then echo 'Generating temporary SSL certificates...'; apk add --no-cache openssl; openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /certs/privkey.pem -out /certs/fullchain.pem -subj '/CN=localhost'; fi"
if ($LASTEXITCODE -ne 0) { throw "Unable to generate the first-run SSL certificate in $CertDir." }

docker compose -f docker-compose.yml pull api frontend nginx watchtower
docker compose -f docker-compose.yml up -d --force-recreate api frontend nginx mysql watchtower

Write-Success "RMM Platform is starting in HTTP first-run mode."
$LaunchUrl = "http://localhost:3010"
Write-Info "Opening browser at $LaunchUrl..."
Write-Info "After login, TeamCore can configure custom Domain & SSL from Settings."
Start-Sleep -Seconds 5
Start-Process $LaunchUrl
