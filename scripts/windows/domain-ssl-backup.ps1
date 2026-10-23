param(
  [string]$Root = "C:\docker\oem",
  [string]$RepoDockerDir = "$PSScriptRoot\..\..\docker"
)

$ErrorActionPreference = "Stop"
$stamp = Get-Date -Format "yyyyMMddHHmmss"
$backupDir = Join-Path $Root "domain-ssl-backups\$stamp"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

$items = @(
  @{ Source = Join-Path $Root "certs\fullchain.pem"; Name = "fullchain.pem" },
  @{ Source = Join-Path $Root "certs\privkey.pem"; Name = "privkey.pem" },
  @{ Source = Join-Path $PSScriptRoot "..\..\nginx\conf.d\proxy.conf"; Name = "proxy.conf" },
  @{ Source = Join-Path $RepoDockerDir ".env"; Name = ".env" }
)

foreach ($item in $items) {
  if (Test-Path $item.Source) {
    Copy-Item -LiteralPath $item.Source -Destination (Join-Path $backupDir $item.Name) -Force
  }
}

Write-Host "Backup created at $backupDir"
