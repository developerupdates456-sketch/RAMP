@echo off
REM run-setup.bat - Automated setup/startup for TeamPresence production
setlocal
cd /d "%~dp0"

REM -------------------------------------------------
REM Register a scheduled task to run this script at every system boot.
REM It is created only if it does not already exist.
schtasks /Query /TN "RMM_Prod_Bootstrap" >nul 2>&1
if %errorlevel% neq 0 (
    schtasks /Create /TN "RMM_Prod_Bootstrap" /TR "%~dp0run-setup.bat" /SC ONSTART /RL HIGHEST /F
    echo [INFO] Created scheduled task "RMM_Prod_Bootstrap" to run at boot.
) else (
    echo [INFO] Scheduled task "RMM_Prod_Bootstrap" already exists.
)

REM -------------------------------------------------
REM Verify Docker is installed; if missing, download and install Docker Desktop.
where docker >nul 2>&1
if %errorlevel% equ 0 goto DOCKER_FOUND

echo [WARN] Docker not found. Attempting automatic Docker Desktop installation...
powershell -NoProfile -Command "$url = 'https://desktop.docker.com/win/stable/Docker%%20Desktop%%20Installer.exe'; $dest = \"$env:TEMP\DockerDesktopInstaller.exe\"; if (-Not (Test-Path $dest)) { Invoke-WebRequest -Uri $url -OutFile $dest }; Write-Host 'Downloaded Docker Desktop installer to' $dest; Start-Process -FilePath $dest -ArgumentList 'install', '--quiet' -Wait; Remove-Item $dest -Force;"

echo [INFO] Docker Desktop installation finished. Verifying installation...
where docker >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Docker still not found after installation. Please install Docker Desktop manually.
    pause
    exit /b 1
)

echo [INFO] Starting Docker Desktop for the first time...
start "" "C:\Program Files\Docker\Docker\Docker Desktop.exe"

:DOCKER_FOUND

REM -------------------------------------------------
REM Wait for Docker daemon to be ready.
echo [INFO] Waiting for Docker daemon...
:DOCKER_WAIT_LOOP
docker info >nul 2>&1
if %errorlevel% neq 0 (
  timeout /t 3 /nobreak >nul
  goto DOCKER_WAIT_LOOP
)

REM Do not run "wsl --update" here. WSL updates can require admin rights,
REM network access, or a reboot and should be handled as planned maintenance.

if exist "..\docker\.env" (
    echo [START] Existing deployment detected. Starting TeamPresence safely...
    powershell -NoProfile -ExecutionPolicy Bypass -File ".\Start-TeamPresence-Production.ps1"
    goto FINISH
)

echo [START] First-time deployment detected. Launching Production Setup...
echo.
echo Waiting 20 seconds for services to settle...
timeout /t 20 /nobreak >nul

powershell -NoProfile -ExecutionPolicy Bypass -File ".\setup-production.ps1"

:FINISH
echo.
echo [FINISH] Startup/setup process complete.
pause
