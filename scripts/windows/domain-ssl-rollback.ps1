param(
  [Parameter(Mandatory = $true)]
  [string]$BackupDir,
  [string]$Root = "C:\docker\oem",
  [string]$RepoRoot = "$PSScriptRoot\.."
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $BackupDir)) {
  throw "Backup directory not found: $BackupDir"
}

$targets = @(
  @{ Source = "fullchain.pem"; Target = Join-Path $Root "certs\fullchain.pem" },
  @{ Source = "privkey.pem"; Target = Join-Path $Root "certs\privkey.pem" },
  @{ Source = "proxy.conf"; Target = Join-Path $RepoRoot "nginx\conf.d\proxy.conf" },
  @{ Source = ".env"; Target = Join-Path $RepoRoot "docker\.env" }
)

foreach ($item in $targets) {
  $source = Join-Path $BackupDir $item.Source
  if (Test-Path $source) {
    Copy-Item -LiteralPath $source -Destination $item.Target -Force
  }
}

& "$PSScriptRoot\domain-ssl-reload.ps1" -ComposeDir (Join-Path $RepoRoot "docker")
Write-Host "Rollback restored from $BackupDir"
