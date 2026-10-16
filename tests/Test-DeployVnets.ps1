#Requires -Version 7.2
# Offline integration checks; no Az modules or Azure account required.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scriptFile = Join-Path $root 'Deploy-Vnets.ps1'
$csv = Join-Path $root 'examples/vnets.csv'
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('vnet-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temp
function Assert([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock] $Body, [string] $Pattern) {
    $caught = $null
    try { & $Body | Out-Null } catch { $caught = $_.Exception.Message }
    Assert ($null -ne $caught -and $caught -like $Pattern) "Expected error '$Pattern'; received '$caught'."
}

# Functions shadow Az cmdlets in this process. Capture inputs to verify behavior.
$global:VnetTestState = @{
    Calls                = [System.Collections.Generic.List[object]]::new()
    Selections           = [System.Collections.Generic.List[string]]::new()
    Lookups              = [System.Collections.Generic.List[string]]::new()
    Groups               = @()
    FailFirst            = $false
    ValidationError      = $false
    FailSubscription     = ''
    MismatchSubscription = ''
}
function Get-AzContext { @{ Account = 'offline' } }
function Set-AzContext {
    param($SubscriptionId, $Scope, $ErrorAction)
    Assert ($Scope -eq 'Process') 'Subscription changes must be process-scoped.'
    $global:VnetTestState.Selections.Add($SubscriptionId)
    if ($SubscriptionId -eq $global:VnetTestState.FailSubscription) { throw 'Mock inaccessible subscription' }
    $id = if ($SubscriptionId -eq $global:VnetTestState.MismatchSubscription) { 'wrong-subscription' } else { $SubscriptionId }
    @{ Subscription = @{ Id = $id } }
}
function Get-AzResourceGroup {
    param($DefaultProfile, $ErrorAction)
    $global:VnetTestState.Lookups.Add($DefaultProfile.Subscription.Id)
    $global:VnetTestState.Groups | Where-Object SubscriptionId -EQ $DefaultProfile.Subscription.Id
}
function New-AzResourceGroup {
    param($Name, $Location, $DefaultProfile, $ErrorAction)
    $global:VnetTestState.Calls.Add(@{ Kind = 'Group'; Name = $Name; Location = $Location; Context = $DefaultProfile })
    $global:VnetTestState.Groups += [pscustomobject]@{ ResourceGroupName = $Name; SubscriptionId = $DefaultProfile.Subscription.Id }
}
function Test-AzResourceGroupDeployment {
    param($ResourceGroupName, $TemplateFile, $TemplateParameterFile, $Mode, $DefaultProfile, $ErrorAction)
    $global:VnetTestState.Calls.Add(@{ Kind = 'Validate'; Context = $DefaultProfile })
    if ($global:VnetTestState.ValidationError) { [pscustomobject]@{ Code = 'InvalidTemplate'; Message = 'Mock validation error' } }
}
function New-AzResourceGroupDeployment {
    param($ResourceGroupName, $TemplateFile, $TemplateParameterFile, $Mode, $DefaultProfile, $ErrorAction, $Name, [switch] $WhatIf)
    $p = Get-Content -LiteralPath $TemplateParameterFile -Raw | ConvertFrom-Json
    $global:VnetTestState.Calls.Add(@{ Kind = 'Deployment'; Vnet = $p.parameters.vnetName.value; Mode = $Mode; Context = $DefaultProfile; Preview = [bool]$WhatIf })
    if ($global:VnetTestState.FailFirst -and $p.parameters.vnetName.value -eq 'vnet-app-dev') { throw 'Mock deployment failure' }
    [pscustomobject]@{ ProvisioningState = 'Succeeded' }
}

try {
    $subscriptions = @((Import-Csv $csv).SubscriptionId)
    $output = @(& $scriptFile -CsvPath $csv -Action Generate -OutputDirectory $temp)
    Assert ($output.Count -eq 2) 'Expected two parameter files.'
    Assert (($output.SubscriptionId -join ',') -eq ($subscriptions -join ',')) 'Generated plan must identify each subscription.'
    foreach ($item in $output) {
        $actual = Get-Content -LiteralPath $item.ParameterFile -Raw | ConvertFrom-Json -AsHashtable
        $expected = Get-Content -LiteralPath (Join-Path $root "examples/parameters/$($item.VnetName).parameters.json") -Raw | ConvertFrom-Json -AsHashtable
        Assert (($actual | ConvertTo-Json -Depth 100 -Compress) -eq ($expected | ConvertTo-Json -Depth 100 -Compress)) 'Generated parameters differ from standalone example.'
        Assert ($actual.parameters.dnsServers.value -is [array]) 'Empty DNS list must stay an array.'
    }
    $rows = @(Import-Csv $csv)
    $bad = Join-Path $temp 'bad.csv'
    $rows[1].SubnetsJson = '{}'
    $rows | Export-Csv $bad -NoTypeInformation
    Assert-Throws { & $scriptFile -CsvPath $bad -Action Generate -OutputDirectory $temp } '*CSV row 3*SubnetsJson*'
    $rows = @(Import-Csv $csv)
    @($rows[0], $rows[0]) | Export-Csv $bad -NoTypeInformation
    Assert-Throws { & $scriptFile -CsvPath $bad -Action Generate -OutputDirectory $temp } '*Duplicate VNet target*'
    $rows[0].AdditionalPropertiesJson = '{"subnets":[]}'
    $rows | Export-Csv $bad -NoTypeInformation
    Assert-Throws { & $scriptFile -CsvPath $bad -Action Generate -OutputDirectory $temp } '*dedicated CSV columns*'
    $rows = @(Import-Csv $csv)
    $rows | Select-Object * -ExcludeProperty SubscriptionId | Export-Csv $bad -NoTypeInformation
    Assert-Throws { & $scriptFile -CsvPath $bad -Action Generate -OutputDirectory $temp } '*Missing required CSV column: SubscriptionId*'
    $rows[1].SubscriptionId = ''
    $rows | Export-Csv $bad -NoTypeInformation
    Assert-Throws { & $scriptFile -CsvPath $bad -Action Generate -OutputDirectory $temp } '*CSV row 3*SubscriptionId is required*'
    $rows[1].SubscriptionId = 'not-a-subscription-guid'
    $rows | Export-Csv $bad -NoTypeInformation
    Assert-Throws { & $scriptFile -CsvPath $bad -Action Generate -OutputDirectory $temp } '*CSV row 3*SubscriptionId must be*'
    Assert ($global:VnetTestState.Calls.Count -eq 0) 'Local validation must not call Azure.'
    Assert ($global:VnetTestState.Selections.Count -eq 0) 'Local validation must not select an Azure subscription.'

    $common = @{ CsvPath = $csv; OutputDirectory = $temp }
    $result = @(& $scriptFile @common -CreateResourceGroups)
    Assert ($result.Count -eq 2) 'Expected two successful deployment results.'
    Assert (($result.SubscriptionId -join ',') -eq ($subscriptions -join ',')) 'Results must identify each subscription.'
    Assert (@($global:VnetTestState.Calls | Where-Object Kind -EQ 'Group').Count -eq 2) 'Same group name must be created separately in each subscription.'
    $deployments = @($global:VnetTestState.Calls | Where-Object Kind -EQ 'Deployment')
    Assert (($deployments.Vnet -join ',') -eq 'vnet-app-dev,vnet-shared-dev') 'Incorrect deployment order.'
    for ($index = 0; $index -lt $deployments.Count; $index++) {
        $call = $deployments[$index]
        Assert ($call.Mode -eq 'Incremental' -and $call.Context.Subscription.Id -eq $subscriptions[$index]) 'Deployment mode/context mismatch.'
    }
    Assert (($global:VnetTestState.Selections -join ',') -eq ($subscriptions -join ',')) 'Select the CSV subscription for every row.'
    Assert (($global:VnetTestState.Lookups -join ',') -eq ($subscriptions -join ',')) 'Group lookups must use the CSV subscription.'
    $global:VnetTestState.Calls.Clear()
    $null = & $scriptFile @common -Action WhatIf
    Assert (@($global:VnetTestState.Calls | Where-Object { $_.Kind -eq 'Deployment' -and $_.Preview }).Count -eq 2) 'What-if not forwarded.'
    $global:VnetTestState.Calls.Clear()
    $null = & $scriptFile @common -Action Validate
    $validations = @($global:VnetTestState.Calls | Where-Object Kind -EQ 'Validate')
    Assert (($validations.Context.Subscription.Id -join ',') -eq ($subscriptions -join ',')) 'Validation must use each row subscription.'
    $global:VnetTestState.Calls.Clear()
    $global:VnetTestState.ValidationError = $true
    Assert-Throws { & $scriptFile @common -Action Validate -WarningAction SilentlyContinue } '*operations failed*'
    Assert ($global:VnetTestState.Calls.Count -eq 1) 'Validation should stop on the first invalid row.'
    $global:VnetTestState.ValidationError = $false
    $global:VnetTestState.Groups = @()
    $global:VnetTestState.Calls.Clear()
    Assert-Throws { & $scriptFile @common -Action WhatIf -CreateResourceGroups -WarningAction SilentlyContinue } '*operations failed*'
    Assert ($global:VnetTestState.Calls.Count -eq 0) 'What-if must not create resource groups.'
    $global:VnetTestState.Groups = @($subscriptions | ForEach-Object { [pscustomobject]@{ ResourceGroupName = 'rg-network-dev'; SubscriptionId = $_ } })
    $global:VnetTestState.FailFirst = $true
    Assert-Throws { & $scriptFile @common -WarningAction SilentlyContinue } '*operations failed*'
    Assert ($global:VnetTestState.Calls.Count -eq 1) 'Default behavior should stop at first failure.'
    $global:VnetTestState.Calls.Clear()
    Assert-Throws { & $scriptFile @common -ContinueOnError -WarningAction SilentlyContinue } '*operations failed*'
    Assert ($global:VnetTestState.Calls.Count -eq 2) 'ContinueOnError should attempt both rows.'

    # An inaccessible or mismatched subscription must never deploy using a previous context.
    $global:VnetTestState.FailFirst = $false
    foreach ($failure in @('FailSubscription', 'MismatchSubscription')) {
        $global:VnetTestState.Calls.Clear()
        $global:VnetTestState.Lookups.Clear()
        $global:VnetTestState[$failure] = $subscriptions[0]
        Assert-Throws { & $scriptFile @common -ContinueOnError -WarningAction SilentlyContinue } '*operations failed*'
        Assert ($global:VnetTestState.Calls.Count -eq 1 -and $global:VnetTestState.Calls[0].Context.Subscription.Id -eq $subscriptions[1]) 'Failed subscription selection must skip that row and allow the next subscription.'
        Assert (($global:VnetTestState.Lookups -join ',') -eq $subscriptions[1]) 'Do not look up groups in a failed or mismatched context.'
        $global:VnetTestState[$failure] = ''
    }

    # Identical resource names in different subscriptions are separate targets.
    $rows = @(Import-Csv $csv)
    $rows[1].VnetName = $rows[0].VnetName
    $rows[1].ResourceGroupLocation = 'ukwest'
    $rows | Export-Csv $bad -NoTypeInformation
    $global:VnetTestState.Groups = @()
    $global:VnetTestState.Calls.Clear()
    $result = @(& $scriptFile -CsvPath $bad -OutputDirectory $temp -CreateResourceGroups)
    Assert ($result.Count -eq 2) 'Same VNet name should be allowed in different subscriptions.'
    $groups = @($global:VnetTestState.Calls | Where-Object Kind -EQ 'Group')
    Assert (($groups.Location -join ',') -eq 'uksouth,ukwest') 'Resource group locations must be tracked per subscription.'
    $rows[1].SubscriptionId = $rows[0].SubscriptionId
    $rows | Export-Csv $bad -NoTypeInformation
    Assert-Throws { & $scriptFile -CsvPath $bad -Action Generate -OutputDirectory $temp } '*Duplicate VNet target*'

    # Distinct VNets in one subscription reuse the same group and enforce its location.
    $rows = @(Import-Csv $csv)
    $rows[1].SubscriptionId = $rows[0].SubscriptionId
    $rows | Export-Csv $bad -NoTypeInformation
    $global:VnetTestState.Groups = @()
    $global:VnetTestState.Calls.Clear()
    $null = & $scriptFile -CsvPath $bad -OutputDirectory $temp -CreateResourceGroups
    Assert (@($global:VnetTestState.Calls | Where-Object Kind -EQ 'Group').Count -eq 1) 'Shared group in one subscription should be created once.'
    $rows[1].ResourceGroupLocation = 'ukwest'
    $rows | Export-Csv $bad -NoTypeInformation
    Assert-Throws { & $scriptFile -CsvPath $bad -Action Generate -OutputDirectory $temp -CreateResourceGroups } '*Conflicting resource group locations*'
    Write-Host 'All offline integration checks passed.'
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
    Remove-Variable VnetTestState -Scope Global
}
