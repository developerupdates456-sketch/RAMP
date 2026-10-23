param(
    [string]$LogDir = "C:\docker\oem\logs"
)

$ErrorActionPreference = "Continue"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$DockerDir = Join-Path $RepoRoot "docker"
$Date = Get-Date -Format "yyyy-MM-dd"
$LogFile = Join-Path $LogDir "docker-health-$Date.log"

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Redact-Secrets([string]$Text) {
    if (-not $Text) { return $Text }
    $Text = $Text -replace '(?i)(password|token|secret|key)=([^ \r\n]+)', '$1=<redacted>'
    $Text = $Text -replace 'gh[pousr]_[A-Za-z0-9_]+', '<redacted-gh-token>'
    return $Text
}

function Write-Log([string]$Message) {
    $line = "{0} {1}" -f (Get-Date -Format "s"), (Redact-Secrets $Message)
    Add-Content -LiteralPath $LogFile -Value $line
    Write-Host $line
}

function Invoke-Logged([string]$Title, [scriptblock]$Command) {
    Write-Log ""
    Write-Log "===== $Title ====="
    try {
        $output = & $Command 2>&1 | Out-String
        if ($output.Trim()) {
            foreach ($line in ($output -split "`r?`n")) {
                if ($line.Trim()) { Write-Log $line }
            }
        } else {
            Write-Log "(no output)"
        }
    } catch {
        Write-Log "ERROR: $($_.Exception.Message)"
    }
}

Write-Log "TeamPresence Docker diagnostics started"
Write-Log "Repository: $RepoRoot"

Invoke-Logged "Windows version" { Get-ComputerInfo | Select-Object WindowsProductName, WindowsVersion, OsHardwareAbstractionLayer, OsArchitecture }
Invoke-Logged "Docker CLI version" { docker --version }
Invoke-Logged "Docker Compose version" { docker compose version }
Invoke-Logged "Docker Engine version" { docker version }
Invoke-Logged "Docker info" { docker info }
Invoke-Logged "Docker Desktop version" {
    $path = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    if (Test-Path -LiteralPath $path) {
        (Get-Item -LiteralPath $path).VersionInfo | Select-Object ProductVersion, FileVersion
    } else {
        "Docker Desktop executable not found at $path"
    }
}
Invoke-Logged "WSL status" { wsl --status }
Invoke-Logged "WSL version" { wsl --version }
Invoke-Logged "WSL distributions" { wsl --list --verbose }
Invoke-Logged "Compose service status" {
    Push-Location $DockerDir
    docker compose -f docker-compose.yml -f docker-compose.prod.yml ps
    Pop-Location
}
Invoke-Logged "Container health summary" {
    docker ps --filter "name=oem" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
}
Invoke-Logged "Recent Watchtower logs" {
    docker logs --tail 200 oem_watchtower
}
Invoke-Logged "Recent API logs" {
    docker logs --tail 120 oem_api
}

Write-Log "TeamPresence Docker diagnostics completed"
Write-Host "Diagnostics saved to $LogFile"
