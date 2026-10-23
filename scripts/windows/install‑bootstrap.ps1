# -------------------------------------------------
# install‑bootstrap.ps1 – creates a scheduled task that
# runs run‑setup.bat automatically at user log‑on
# -------------------------------------------------

$taskName   = "RMM_Prod_Bootstrap"
$taskDesc   = "Runs the RMM production bootstrap (run-setup.bat) after Windows starts."
$scriptPath = Join-Path $PSScriptRoot "..\..\RMM-Prod-Deploy\run-setup.bat"

# Action: execute the batch file
$action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$scriptPath`""

# Trigger: at user log‑on (you can also use -AtStartup for system boot)
$trigger = New-ScheduledTaskTrigger -AtLogOn

# Run with highest privileges (required to call Docker/WSL)
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

# Register (creates or updates)
Register-ScheduledTask -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Description $taskDesc `
    -Force

Write-Host "✅ Created scheduled task '$taskName'. It will run run‑setup.bat automatically at log‑on."
