@echo off
REM ============================================================================
REM Production Deployment Setup Script (Windows)
REM ============================================================================

echo ========================================
echo OEM Integration - Production Setup
echo ========================================
echo.

REM Check if Docker is installed
docker --version >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: Docker is not installed. Please install Docker Desktop first.
    exit /b 1
)

REM Check if Docker Compose is installed
docker compose version >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: Docker Compose is not installed.
    exit /b 1
)

echo [OK] Docker is installed

REM Configure the GHCR image namespace for this deployment
set "REGISTRY=ghcr.io"
set "IMAGE_BASE=teampresence-production/ramp_linux"

echo [OK] Using image namespace: ghcr.io/teampresence-production/ramp_linux

REM Create required directories
echo.
echo Creating directories...

if not exist "C:\docker\oem\mysql\data" mkdir "C:\docker\oem\mysql\data"
if not exist "C:\docker\oem\mysql\backups" mkdir "C:\docker\oem\mysql\backups"
if not exist "C:\docker\oem\logs" mkdir "C:\docker\oem\logs"
if not exist "C:\docker\oem\certs" mkdir "C:\docker\oem\certs"

echo [OK] Directories created

REM Copy env file if not exists
if not exist "docker\.env" (
    echo.
    echo Creating .env file from template...
    copy docker\.env.example docker\.env
    echo [OK] .env file created
    echo WARNING: Please edit docker\.env and set secure passwords!
) else (
    echo [OK] .env file already exists
)

REM Generate secrets if not exist
echo.
echo Checking secrets...

if not exist "security\secrets\mysql_root_password" (
    powershell -Command "[System.IO.File]::WriteAllText('security\secrets\mysql_root_password', [System.IO.Path]::GetRandomFileName() + [System.IO.Path]::GetRandomFileName())"
    echo [OK] Generated mysql_root_password
)

if not exist "security\secrets\mysql_app_password" (
    powershell -Command "[System.IO.File]::WriteAllText('security\secrets\mysql_app_password', [System.IO.Path]::GetRandomFileName() + [System.IO.Path]::GetRandomFileName())"
    echo [OK] Generated mysql_app_password
)

if not exist "security\secrets\jwt_secret_key" (
    powershell -Command "[System.IO.File]::WriteAllText('security\secrets\jwt_secret_key', [System.IO.Path]::GetRandomFileName() + [System.IO.Path]::GetRandomFileName() + [System.IO.Path]::GetRandomFileName() + [System.IO.Path]::GetRandomFileName())"
    echo [OK] Generated jwt_secret_key
)

if not exist "security\secrets\encryption_key" (
    powershell -Command "[System.IO.File]::WriteAllText('security\secrets\encryption_key', [System.IO.Path]::GetRandomFileName() + [System.IO.Path]::GetRandomFileName() + [System.IO.Path]::GetRandomFileName() + [System.IO.Path]::GetRandomFileName())"
    echo [OK] Generated encryption_key
)

REM Update MySQL user password
echo.
echo Note: Update the password in mysql\init\02-create-users.sql to match the generated mysql_app_password

echo.
echo ========================================
echo Setup Complete!
echo ========================================
echo.
echo Next steps:
echo 1. Edit docker\.env with your domain and settings
echo 2. Run: cd docker
echo 3. Run: docker compose pull api frontend nginx
echo 4. Run: docker compose up -d --force-recreate api frontend nginx mysql
echo 5. Check logs: docker compose logs -f
echo.
