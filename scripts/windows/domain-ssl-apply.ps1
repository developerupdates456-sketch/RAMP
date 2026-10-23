param(
  [Parameter(Mandatory = $true)]
  [string]$Domain,
  [string]$RepoRoot = "$PSScriptRoot\.."
)

$ErrorActionPreference = "Stop"

if ($Domain -notmatch '^(?=.{1,253}$)(?!-)([A-Za-z0-9-]{1,63}\.)+[A-Za-z]{2,63}$') {
  throw "Invalid domain name: $Domain"
}

& "$PSScriptRoot\domain-ssl-backup.ps1" -RepoDockerDir (Join-Path $RepoRoot "docker")

$envFile = Join-Path $RepoRoot "docker\.env"
$updates = @{
  DOMAIN = $Domain
  REACT_APP_BASE_URL = "https://$Domain"
  FRONTEND_URL = "https://$Domain"
  ALLOWED_ORIGINS = "https://$Domain"
}

$lines = @()
if (Test-Path $envFile) {
  $lines = Get-Content -LiteralPath $envFile
}

$seen = @{}
$next = New-Object System.Collections.Generic.List[string]
foreach ($line in $lines) {
  if ($line -match '^\s*([^#=\s]+)\s*=') {
    $key = $Matches[1]
    if ($updates.ContainsKey($key)) {
      if (-not $seen.ContainsKey($key)) {
        $next.Add("$key=$($updates[$key])")
        $seen[$key] = $true
      }
      continue
    }
  }
  $next.Add($line)
}

foreach ($key in $updates.Keys) {
  if (-not $seen.ContainsKey($key)) {
    $next.Add("$key=$($updates[$key])")
  }
}

Set-Content -LiteralPath $envFile -Value $next -Encoding UTF8
& "$PSScriptRoot\domain-ssl-reload.ps1" -ComposeDir (Join-Path $RepoRoot "docker")
Write-Host "Domain SSL environment updated for $Domain"
