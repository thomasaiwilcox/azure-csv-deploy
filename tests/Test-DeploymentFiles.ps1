#Requires -Version 7.2
# Exercise portable, editable batches with mocked Azure commands.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/Common.ps1')
$runner = Join-Path $root 'Deploy-FromFiles.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('batch-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory $temp
function Assert([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock] $Body, [string] $Pattern) {
    $caught = ''
    try { & $Body | Out-Null } catch { $caught = $_.Exception.Message }
    Assert ($caught -like $Pattern) "Expected '$Pattern'; received '$caught'."
}
$global:BatchTest = @{ Calls = @(); Selections = @(); Groups = @(); Fail = $false; Invalid = $false }
function Get-AzContext { @{ Account = 'offline' } }
function Set-AzContext {
    param($SubscriptionId, $Scope, $ErrorAction)
    Assert ($Scope -eq 'Process') 'Subscription selection must be process-scoped.'
    $global:BatchTest.Selections += $SubscriptionId
    @{ Subscription = @{ Id = $SubscriptionId } }
}
function Get-AzResourceGroup {
    param($Name, $DefaultProfile, $ErrorAction)
    if (-not $Name) { throw 'Subscription-wide enumeration is forbidden.' }
    $group = $global:BatchTest.Groups | Where-Object {
        $_.SubscriptionId -eq $DefaultProfile.Subscription.Id -and $_.ResourceGroupName -eq $Name
    }
    if ($null -eq $group) { throw 'Resource group does not exist.' }
    $group
}
function Invoke-AzRestMethod {
    param($Path, $Method, $DefaultProfile, $ErrorAction)
    Assert ($Method -eq 'GET' -and $Path -like "/subscriptions/$($DefaultProfile.Subscription.Id)/resourcegroups/*?api-version=2021-04-01") 'Fallback must GET the target group in the explicit context.'
    @{ StatusCode = 404; Content = '{"error":{"code":"ResourceGroupNotFound"}}' }
}
function New-AzResourceGroup {
    param($Name, $Location, $DefaultProfile, $ErrorAction)
    $global:BatchTest.Groups += @{ ResourceGroupName = $Name; Location = $Location; SubscriptionId = $DefaultProfile.Subscription.Id }
}
function Test-AzResourceGroupDeployment {
    param($ResourceGroupName, $TemplateFile, $TemplateParameterFile, $Mode, $DefaultProfile, $ErrorAction)
    $global:BatchTest.Calls += @{ Action = 'Validate'; Subscription = $DefaultProfile.Subscription.Id }
    if ($global:BatchTest.Invalid) { @{ Code = 'MockValidationFailure' } }
}
function New-AzResourceGroupDeployment {
    param($ResourceGroupName, $TemplateFile, $TemplateParameterFile, $Mode, $DefaultProfile, $ErrorAction, $Name, [switch] $WhatIf)
    Assert ($Mode -eq 'Incremental') 'Deployment mode must remain Incremental.'
    $global:BatchTest.Calls += @{
        Action = if ($WhatIf) { 'WhatIf' } else { 'Deploy' }
        Parameters = Read-BatchJson $TemplateParameterFile
        Template = Read-BatchJson $TemplateFile
        Subscription = $DefaultProfile.Subscription.Id
    }
    if ($global:BatchTest.Fail -and $global:BatchTest.Calls.Count -eq 1) { throw 'Mock failure' }
    @{ ProvisioningState = 'Succeeded' }
}
try {
    $batch = Join-Path $temp 'networks'
    $csv = Join-Path $temp 'networks.csv'
    $rows = @(Import-Csv (Join-Path $root 'examples/vnets.csv'))
    # The same name in different subscriptions must get distinct filenames/paths.
    $rows[1].VnetName = $rows[0].VnetName
    $rows | Export-Csv $csv -NoTypeInformation
    $sourceTemplate = Join-Path $temp 'custom-template.json'
    Copy-Item (Join-Path $root 'templates/vnet.json') $sourceTemplate
    Push-Location $temp
    try {
        $plans = @(& (Join-Path $root 'Deploy-Vnets.ps1') -CsvPath $csv -TemplateFile $sourceTemplate -Action Generate -OutputDirectory './networks')
    }
    finally { Pop-Location }
    Assert (Test-Path (Join-Path $batch 'deployments.json')) 'Relative output must use the PowerShell working directory.'
    Assert ($plans.Count -eq 2 -and $plans[0].ParameterFile -ne $plans[1].ParameterFile) 'Scopes must have separate paths.'
    Assert ((Split-Path $plans[0].ParameterFile -Leaf) -eq 'vnet-app-dev.parameters.json') 'Filename must be the resource name.'
    $index = Read-BatchJson (Join-Path $batch 'deployments.json')
    Assert ($index.deployments[0].subscriptionId -eq $rows[0].SubscriptionId) 'Index must preserve CSV order.'
    $originalPath = $index.deployments[0].parameterFile
    @($rows[1], $rows[0]) | Export-Csv $csv -NoTypeInformation
    $null = & (Join-Path $root 'Deploy-Vnets.ps1') -CsvPath $csv -TemplateFile $sourceTemplate -Action Generate -OutputDirectory $batch
    $index = Read-BatchJson (Join-Path $batch 'deployments.json')
    Assert ($index.deployments[1].parameterFile -ceq $originalPath) 'Reordering must not rename parameter files.'

    # A copied batch no longer needs the CSV or the source template.
    $moved = Join-Path $temp 'moved'
    Move-Item $batch $moved
    Remove-Item $csv, $sourceTemplate
    Push-Location $temp
    try { $verified = @(& $runner -Path './moved' -Action Verify) } finally { Pop-Location }
    Assert ($verified.Count -eq 2 -and $global:BatchTest.Selections.Count -eq 0) 'Verify must be offline.'
    $parameterPath = $verified[0].ParameterFile
    $parameter = Read-BatchJson $parameterPath
    $parameter.parameters.tags.value = @{ edited = 'yes' }
    Write-BatchJson $parameter $parameterPath
    $template = Read-BatchJson $verified[0].TemplateFile
    $template.contentVersion = '1.0.0.1'
    Write-BatchJson $template $verified[0].TemplateFile
    Set-Content (Join-Path $moved 'stale.parameters.json') 'not even JSON'
    $result = @(& $runner -Path $moved -CreateResourceGroups)
    Assert ($result.Count -eq 2 -and $global:BatchTest.Groups.Count -eq 2) 'Deploy must create requested groups and return two results.'
    Assert ($global:BatchTest.Calls[0].Parameters.parameters.tags.value.edited -eq 'yes') 'Deploy must use edited parameters.'
    Assert ($global:BatchTest.Calls[0].Template.contentVersion -eq '1.0.0.1') 'Deploy must use the edited bundled template.'
    Assert (($global:BatchTest.Selections -join ',') -eq ($index.deployments.subscriptionId -join ',')) 'Subscription/order must come from the index.'
    foreach ($action in @('Validate', 'WhatIf')) {
        $global:BatchTest.Calls = @()
        $null = & $runner -Path $moved -Action $action
        Assert ($global:BatchTest.Calls.Count -eq 2 -and $global:BatchTest.Calls[0].Action -eq $action) "Wrong action: $action"
    }
    $global:BatchTest.Calls = @(); $global:BatchTest.Fail = $true
    Assert-Throws { & $runner -Path $moved } '*operations failed*'
    Assert ($global:BatchTest.Calls.Count -eq 1) 'Default must stop at first Azure failure.'
    $global:BatchTest.Calls = @()
    Assert-Throws { & $runner -Path $moved -ContinueOnError } '*operations failed*'
    Assert ($global:BatchTest.Calls.Count -eq 2) 'ContinueOnError must attempt remaining entries.'
    $global:BatchTest.Fail = $false; $global:BatchTest.Invalid = $true
    Assert-Throws { & $runner -Path $moved -Action Validate } '*operations failed*'
    $global:BatchTest.Invalid = $false
    $global:BatchTest.Groups = @()
    Assert-Throws { & $runner -Path $moved -Action WhatIf -CreateResourceGroups } '*operations failed*'
    Assert ($global:BatchTest.Groups.Count -eq 0) 'Preview must not create groups.'

    # Invalid later entries must fail before even selecting the first subscription.
    $global:BatchTest.Selections = @()
    $indexPath = Join-Path $moved 'deployments.json'
    $savedIndex = [IO.File]::ReadAllText($indexPath)
    foreach ($case in @(
        @{ Edit = { param($i) $i.deployments[1].Remove('resourceGroupLocation') }; Pattern = '*requires a nonempty string*' },
        @{ Edit = { param($i) $i.formatVersion = 2 }; Pattern = '*formatVersion*' },
        @{ Edit = { param($i) $i.deployments = @() }; Pattern = '*nonempty deployments*' },
        @{ Edit = { param($i) $i.deployments[1].subscriptionId = 'invalid' }; Pattern = '*GUID*' },
        @{ Edit = { param($i) $i.deployments += $i.deployments[0] }; Pattern = '*Duplicate deployment target*' },
        @{ Edit = { param($i) $i.deployments[1].parameterFile = '../outside.json' }; Pattern = '*Invalid relative batch path*' },
        @{ Edit = { param($i) $i.deployments[1].templateFile = '/tmp/template.json' }; Pattern = '*Invalid relative batch path*' },
        @{ Edit = { param($i) $i.deployments[1].parameterFile = 'missing/vnet-app-dev.parameters.json' }; Pattern = '*file not found*' },
        @{ Edit = { param($i) $i.deployments[1].resourceName = 'renamed' }; Pattern = '*filename must match*' },
        @{ Edit = { param($i) $i.deployments[1].resourceType = 'Microsoft.Compute/virtualMachines' }; Pattern = '*separate folders*' }
    )) {
        $changed = Read-JsonCell $savedIndex 'test index' ([Collections.IDictionary]) $null
        & $case.Edit $changed
        Write-BatchJson $changed $indexPath
        Assert-Throws { & $runner -Path $moved -Action Validate } $case.Pattern
    }
    [IO.File]::WriteAllText($indexPath, $savedIndex)
    $savedParameter = [IO.File]::ReadAllText($parameterPath)
    Set-Content $parameterPath '{'
    Assert-Throws { & $runner -Path $moved } '*invalid JSON*'
    $parameter.parameters.vnetName.value = 'wrong-name'
    Write-BatchJson $parameter $parameterPath
    Assert-Throws { & $runner -Path $moved } '*does not match ARM parameter*'
    [IO.File]::WriteAllText($parameterPath, $savedParameter)
    foreach ($case in @(
        @{ Edit = { param($p) $p.parameters.location.value = $false }; Pattern = '*wrong type*' },
        @{ Edit = { param($p) $p.parameters.Remove('location') }; Pattern = '*Missing required ARM parameter*' },
        @{ Edit = { param($p) $p.parameters.location = @{ reference = @{} } }; Pattern = '*Invalid Key Vault*' },
        @{ Edit = { param($p) $p.parameters.location.reference = @{} }; Pattern = '*contain value or reference*' },
        @{ Edit = { param($p) $p.contentVersion = 'bad-version' }; Pattern = '*ARM files require*' }
    )) {
        $changed = Read-JsonCell $savedParameter 'test parameters' ([Collections.IDictionary]) $null
        & $case.Edit $changed
        Write-BatchJson $changed $parameterPath
        Assert-Throws { & $runner -Path $moved } $case.Pattern
    }
    [IO.File]::WriteAllText($parameterPath, $savedParameter)
    $savedTemplate = [IO.File]::ReadAllText($verified[0].TemplateFile)
    Set-Content $verified[0].TemplateFile '{'
    Assert-Throws { & $runner -Path $moved } '*invalid JSON*'
    [IO.File]::WriteAllText($verified[0].TemplateFile, $savedTemplate)
    Assert ($global:BatchTest.Selections.Count -eq 0) 'All local errors must precede Azure calls.'

    # Resolve symbolic links in parent directories too, not only the referenced file.
    $outside = Join-Path $temp 'outside'
    $null = New-Item -ItemType Directory $outside
    Copy-Item $verified[0].TemplateFile (Join-Path $outside 'vnet.json')
    $link = Join-Path $moved 'linked'
    $null = New-Item -ItemType SymbolicLink -Path $link -Target $outside
    $changed = Read-JsonCell $savedIndex 'test index' ([Collections.IDictionary]) $null
    $changed.deployments[1].templateFile = 'linked/vnet.json'
    Write-BatchJson $changed $indexPath
    Assert-Throws { & $runner -Path $moved -Action Verify } '*escapes the folder*'
    [IO.File]::WriteAllText($indexPath, $savedIndex)

    # Regenerate with fewer rows: replace the index, but retain unlisted files.
    $rows[0] | Export-Csv $csv -NoTypeInformation
    $null = & (Join-Path $root 'Deploy-Vnets.ps1') -CsvPath $csv -Action Generate -OutputDirectory $moved
    $remaining = @(& $runner -Path $moved -Action Verify)
    Assert ($remaining.Count -eq 1 -and (Test-Path $parameterPath)) 'Regeneration must remove obsolete entries, not old files.'
    Assert-Throws {
        & (Join-Path $root 'Deploy-Vms.ps1') -CsvPath (Join-Path $root 'examples/vms.csv') -Action Generate -OutputDirectory $moved
    } '*separate folders*'

    # Different logical paths can resolve to the same file through directory links.
    $collisionBatch = Join-Path $temp 'collision-batch'
    $firstGroup = Join-Path $collisionBatch "parameters/$($rows[0].SubscriptionId)/$($rows[0].ResourceGroupName)"
    $secondSubscription = Join-Path $collisionBatch "parameters/$($rows[1].SubscriptionId)"
    $null = New-Item -ItemType Directory $firstGroup, $secondSubscription -Force
    $null = New-Item -ItemType SymbolicLink -Path (Join-Path $secondSubscription $rows[1].ResourceGroupName) -Target $firstGroup
    $rows | Export-Csv $csv -NoTypeInformation
    Assert-Throws { & (Join-Path $root 'Deploy-Vnets.ps1') -CsvPath $csv -Action Generate -OutputDirectory $collisionBatch } '*paths collide*'
    Assert (-not (Test-Path (Join-Path $collisionBatch 'templates'))) 'Collisions must fail before any batch files are written.'

    # Generation must also reject output links that point outside the batch.
    $escapeBatch = Join-Path $temp 'escape-batch'
    $null = New-Item -ItemType Directory $escapeBatch
    $null = New-Item -ItemType SymbolicLink -Path (Join-Path $escapeBatch 'templates') -Target $outside
    Assert-Throws { & (Join-Path $root 'Deploy-Vnets.ps1') -CsvPath $csv -Action Generate -OutputDirectory $escapeBatch } '*escapes the folder*'

    # Generation must catch nonportable filenames before writing anything.
    $rows[0].VnetName = 'CON'
    $rows[0] | Export-Csv $csv -NoTypeInformation
    $invalidOutput = Join-Path $temp 'invalid-output'
    Assert-Throws { & (Join-Path $root 'Deploy-Vnets.ps1') -CsvPath $csv -Action Generate -OutputDirectory $invalidOutput } '*Invalid relative batch path*'
    Assert (-not (Test-Path $invalidOutput)) 'Invalid output paths must fail before creating files.'

    $vmBatch = Join-Path $temp 'machines'
    $null = & (Join-Path $root 'Deploy-Vms.ps1') -CsvPath (Join-Path $root 'examples/vms.csv') -Action Generate -OutputDirectory $vmBatch
    Assert-Throws { & $runner -Path $vmBatch -Action Verify } '*SSH placeholder*'
    $vmRows = @(Import-Csv (Join-Path $root 'examples/vms.csv'))
    $vmRows[0].SshPublicKey = (Get-Content (Join-Path $root 'tests/fixtures/ssh-test.pub') -Raw).Trim()
    $vmRows | Export-Csv $csv -NoTypeInformation
    $null = & (Join-Path $root 'Deploy-Vms.ps1') -CsvPath $csv -Action Generate -OutputDirectory $vmBatch
    $vmPlans = @(& $runner -Path $vmBatch -Action Verify)
    Assert ($vmPlans.Count -eq 2) 'Both Linux and Windows parameter files must verify.'
    $global:BatchTest.Calls = @()
    $null = & $runner -Path $vmBatch -CreateResourceGroups
    Assert ($global:BatchTest.Calls.Count -eq 2) 'VM batches must deploy both rows.'
    Assert ($global:BatchTest.Calls[1].Parameters.parameters.adminPassword.Contains('reference')) 'Windows must retain its Key Vault reference.'
    Write-Host 'All deployment batch checks passed.'
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force }
