#Requires -Version 7.2
<#
.SYNOPSIS
Verify, validate, preview or deploy an editable batch without its original CSV.
.EXAMPLE
./Deploy-FromFiles.ps1 -Path ./generated/vms -Action Verify
.EXAMPLE
./Deploy-FromFiles.ps1 -Path ./generated/vms -CreateResourceGroups
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Path,
    [ValidateSet('Verify', 'Validate', 'WhatIf', 'Deploy')][string] $Action = 'Deploy',
    [switch] $CreateResourceGroups,
    [switch] $ContinueOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'src/Common.ps1')

# Load and check the entire batch before making any Azure calls.
$plans = @(Read-DeploymentBatch -Path $Path -CreateResourceGroups:$CreateResourceGroups)
if ($Action -eq 'Verify') {
    $plans | Select-Object SubscriptionId, ResourceGroupName, ResourceType, ResourceName, TemplateFile, ParameterFile
    return
}
Invoke-DeploymentPlan -Plans $plans -Action $Action -NameProperty ResourceName -ResourceLabel Resource `
    -CreateResourceGroups:$CreateResourceGroups -ContinueOnError:$ContinueOnError
