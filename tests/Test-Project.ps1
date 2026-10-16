#Requires -Version 7.2
<# .SYNOPSIS
Run all offline checks in isolated PowerShell processes. No Azure login required.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$executable = (Get-Process -Id $PID).Path
foreach ($test in @('Test-Common.ps1', 'Test-DeployVnets.ps1', 'Test-DeployVms.ps1', 'Test-DeploymentFiles.ps1', 'Test-Repository.ps1')) {
    Write-Host "Running $test"
    & $executable -NoLogo -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot $test)
    if ($LASTEXITCODE -ne 0) { throw "$test failed with exit code $LASTEXITCODE." }
}
Write-Host 'All offline checks passed.'
