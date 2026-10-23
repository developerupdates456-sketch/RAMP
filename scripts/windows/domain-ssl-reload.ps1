param(
  [string]$ComposeDir = "$PSScriptRoot\..\..\docker"
)

$ErrorActionPreference = "Stop"
Push-Location $ComposeDir
try {
  docker compose exec -T nginx nginx -t
  docker compose exec -T nginx nginx -s reload
  Write-Host "Nginx configuration validated and reloaded."
}
finally {
  Pop-Location
}
