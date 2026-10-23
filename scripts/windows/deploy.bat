@echo off
REM ============================================================================
REM Production Deployment Script (Windows)
REM ============================================================================

echo ========================================
echo OEM Integration - Deployment
echo ========================================
echo.

cd /d "%~dp0\..\docker"

REM Point Docker Compose at the new GHCR image namespace
set "REGISTRY=ghcr.io"
set "IMAGE_BASE=teampresence-production/ramp_linux"

REM Pull GitHub Actions-built images and start containers
echo Pulling latest production images...
docker compose pull api frontend nginx

if %errorlevel% neq 0 (
    echo ERROR: Failed to pull production images
    exit /b 1
)

echo Starting containers...
docker compose up -d --force-recreate api frontend nginx mysql

if %errorlevel% neq 0 (
    echo ERROR: Failed to start containers
    exit /b 1
)

echo.
echo Waiting for services to be healthy...
timeout /t 30 /nobreak > nul

REM Check service status
echo.
echo Service Status:
docker compose ps

echo.
echo ========================================
echo Deployment Complete!
echo ========================================
echo.
echo Access your application at:
echo   - First run: http://localhost:3010
echo   - HTTPS/custom domain: configure from TeamCore Settings ^> Domain ^& SSL
echo.
echo Logs:
echo   docker compose logs -f nginx
echo   docker compose logs -f api
echo   docker compose logs -f mysql
echo.
