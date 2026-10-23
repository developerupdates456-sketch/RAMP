param(
  [string]$ComposeDir = "$PSScriptRoot\..\..\docker"
)

$ErrorActionPreference = "Stop"
Push-Location $ComposeDir
try {
  docker compose exec -T nginx nginx -t
}
finally {
  Pop-Location
}
