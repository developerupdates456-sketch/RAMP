@echo off
REM ============================================================================
REM Health Check Script (Windows)
REM ============================================================================

echo ========================================
echo OEM Integration - Health Check
echo ========================================
echo.

set FAILED=0
set DOMAIN=localhost
pushd "%~dp0..\..\docker" >nul

if exist ".env" (
    for /f "tokens=1,* delims==" %%a in ('findstr /b "DOMAIN=" ".env"') do set DOMAIN=%%b
)

REM Check Nginx
echo Checking Nginx...
docker exec oem_nginx nginx -t >nul 2>&1
if %errorlevel% neq 0 (
    echo [FAIL] Nginx configuration error
    set FAILED=1
) else (
    echo [OK] Nginx
)

REM Check API health endpoint
echo Checking API...
curl -s -o nul -w "%%{http_code}" http://localhost:5000/health > temp_health.txt 2>nul
set /p API_STATUS=<temp_health.txt
del temp_health.txt >nul 2>&1
if "%API_STATUS%"=="200" (
    echo [OK] API is healthy
) else (
    echo [FAIL] API returned: %API_STATUS%
    set FAILED=1
)

REM Check HTTP first-run endpoint through Nginx
echo Checking HTTP first-run endpoint...
curl -s -o nul -w "%%{http_code}" http://localhost/health > temp_nginx_health.txt 2>nul
set /p NGINX_HTTP_STATUS=<temp_nginx_health.txt
del temp_nginx_health.txt >nul 2>&1
if "%NGINX_HTTP_STATUS%"=="200" (
    echo [OK] HTTP first-run endpoint is healthy
) else (
    echo [FAIL] HTTP first-run endpoint returned: %NGINX_HTTP_STATUS%
    set FAILED=1
)

REM HTTPS is expected only after TeamCore applies Domain & SSL.
if not "%DOMAIN%"=="localhost" (
    echo Checking optional HTTPS endpoint...
    curl -k -s -o nul -w "%%{http_code}" https://%DOMAIN%/health > temp_https_health.txt 2>nul
    set /p HTTPS_STATUS=<temp_https_health.txt
    del temp_https_health.txt >nul 2>&1
    if "%HTTPS_STATUS%"=="200" (
        echo [OK] HTTPS is healthy
    ) else (
        echo [INFO] HTTPS not active yet. Configure it from TeamCore Settings.
    )
)

REM Check MySQL
echo Checking MySQL...
docker exec oem_mysql mysqladmin ping -h localhost >nul 2>&1
if %errorlevel% neq 0 (
    echo [FAIL] MySQL not responding
    set FAILED=1
) else (
    echo [OK] MySQL
)

REM Check container status
echo.
echo Container Status:
docker compose ps

echo.
if %FAILED% equ 0 (
    echo ========================================
    echo [OK] All checks passed!
    echo ========================================
    popd >nul
    exit /b 0
) else (
    echo ========================================
    echo [FAIL] Some checks failed!
    echo ========================================
    popd >nul
    exit /b 1
)
