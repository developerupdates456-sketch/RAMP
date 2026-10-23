@echo off
REM ============================================================================
REM Backup Script (Windows)
REM ============================================================================

setlocal

set BACKUP_DIR=C:\docker\oem\mysql\backups
set DB_NAME=oem_integration
set TIMESTAMP=%date:~-4%%date:~3,2%%date:~0,2%_%time:~0,2%%time:~3,2%%time:~6,2%
set TIMESTAMP=%TIMESTAMP: =0%
set BACKUP_FILE=%BACKUP_DIR%\oem_backup_%TIMESTAMP%.sql.zip
set SECRET_FILE=%~dp0..\..\security\secrets\mysql_root_password

echo ========================================
echo OEM Integration - Database Backup
echo ========================================
echo.

REM Get MySQL container ID
for /f "delims=" %%i in ('docker ps -qf "name=oem_mysql"') do set MYSQL_CONTAINER=%%i

if "%MYSQL_CONTAINER%"=="" (
    echo ERROR: MySQL container not running
    exit /b 1
)

echo Creating backup: %BACKUP_FILE%

if not exist "%SECRET_FILE%" (
    echo ERROR: Secret file not found: %SECRET_FILE%
    exit /b 1
)

for /f "usebackq delims=" %%p in ("%SECRET_FILE%") do set MYSQL_ROOT_PASSWORD=%%p

REM Run backup. PowerShell gzip keeps this Windows-compatible.
docker exec %MYSQL_CONTAINER% mysqldump -u root -p%MYSQL_ROOT_PASSWORD% %DB_NAME% > "%BACKUP_DIR%\oem_backup_%TIMESTAMP%.sql"

if %errorlevel% neq 0 (
    echo ERROR: Backup failed
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "Compress-Archive -Path '%BACKUP_DIR%\oem_backup_%TIMESTAMP%.sql' -DestinationPath '%BACKUP_FILE%' -Force; Remove-Item -LiteralPath '%BACKUP_DIR%\oem_backup_%TIMESTAMP%.sql' -Force"

if %errorlevel% neq 0 (
    echo ERROR: Backup compression failed
    exit /b 1
)

echo [OK] Backup created: %BACKUP_FILE%

REM Clean up old backups (keep last 7 days)
echo.
echo Cleaning up old backups...
forfiles /p "%BACKUP_DIR%" /s /m *.zip /d -7 /c "cmd /c del @path"

echo.
echo Backup Complete!
echo.

endlocal
