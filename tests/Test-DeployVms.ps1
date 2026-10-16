#Requires -Version 7.2
# Offline integration tests: run in a fresh process; mocks shadow Az commands.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scriptFile = Join-Path $root 'Deploy-Vms.ps1'
$exampleCsv = Join-Path $root 'examples/vms.csv'
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('vm-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temp
$csv = Join-Path $temp 'vms.csv'
$fixtureRows = @(Import-Csv $exampleCsv)
$fixtureRows[0].SshPublicKey = (Get-Content (Join-Path $PSScriptRoot 'fixtures/ssh-test.pub') -Raw).Trim()
$fixtureRows | Export-Csv $csv -NoTypeInformation
function Assert([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock] $Body, [string] $Pattern) {
    $caught = $null
    try { & $Body | Out-Null } catch { $caught = $_.Exception.Message }
    Assert ($null -ne $caught -and $caught -like $Pattern) "Expected error '$Pattern'; received '$caught'."
}
function Get-Parameters($Item) { (Get-Content -LiteralPath $Item.ParameterFile -Raw | ConvertFrom-Json -AsHashtable).parameters }
function Generate-Variant([hashtable] $Changes) {
    $row = (Import-Csv $csv)[0]
    foreach ($key in $Changes.Keys) { $row.$key = $Changes[$key] }
    $row | Export-Csv (Join-Path $temp 'variant.csv') -NoTypeInformation
    & $scriptFile -CsvPath (Join-Path $temp 'variant.csv') -Action Generate -OutputDirectory (Join-Path $temp 'variant')
}
$global:VmTestState = @{
    Calls                = [System.Collections.Generic.List[object]]::new()
    Selections           = [System.Collections.Generic.List[string]]::new()
    Lookups              = [System.Collections.Generic.List[string]]::new()
    Groups               = @()
    FailSubscription     = ''
    MismatchSubscription = ''
    FailVm               = ''
    ValidationError      = $false
}
function Get-AzContext { @{ Account = 'offline' } }
function Set-AzContext {
    param($SubscriptionId, $Scope, $ErrorAction)
    Assert ($Scope -eq 'Process') 'Subscription changes must be process-scoped.'
    $global:VmTestState.Selections.Add($SubscriptionId)
    if ($SubscriptionId -eq $global:VmTestState.FailSubscription) { throw 'Mock inaccessible subscription' }
    @{ Subscription = @{ Id = $(if ($SubscriptionId -eq $global:VmTestState.MismatchSubscription) { 'wrong' } else { $SubscriptionId }) } }
}
function Get-AzResourceGroup {
    param($DefaultProfile, $ErrorAction)
    $global:VmTestState.Lookups.Add($DefaultProfile.Subscription.Id)
    $global:VmTestState.Groups | Where-Object SubscriptionId -EQ $DefaultProfile.Subscription.Id
}
function New-AzResourceGroup {
    param($Name, $Location, $DefaultProfile, $ErrorAction)
    $global:VmTestState.Calls.Add(@{ Kind = 'Group'; Context = $DefaultProfile })
    $global:VmTestState.Groups += [pscustomobject]@{ SubscriptionId = $DefaultProfile.Subscription.Id; ResourceGroupName = $Name }
}
function Test-AzResourceGroupDeployment {
    param($ResourceGroupName, $TemplateFile, $TemplateParameterFile, $Mode, $DefaultProfile, $ErrorAction)
    $global:VmTestState.Calls.Add(@{ Kind = 'Validate'; Context = $DefaultProfile })
    if ($global:VmTestState.ValidationError) { @{ Code = 'InvalidTemplate' } }
}
function New-AzResourceGroupDeployment {
    param($ResourceGroupName, $TemplateFile, $TemplateParameterFile, $Mode, $DefaultProfile, $ErrorAction, $Name, [switch] $WhatIf)
    $p = (Get-Content -LiteralPath $TemplateParameterFile -Raw | ConvertFrom-Json -AsHashtable).parameters
    $global:VmTestState.Calls.Add(@{ Kind = 'Deployment'; Vm = $p.vmName.value; Context = $DefaultProfile; Mode = $Mode; Preview = [bool]$WhatIf })
    if ($p.vmName.value -eq $global:VmTestState.FailVm) { throw 'Mock deployment failure' }
    @{ ProvisioningState = 'Succeeded' }
}

try {
    $rows = @(Import-Csv $csv)
    $subscriptions = @($rows.SubscriptionId)
    $output = @(& $scriptFile -CsvPath $csv -Action Generate -OutputDirectory $temp)
    Assert ($output.Count -eq 2) 'Expected Windows and Linux parameter files.'
    $linux = Get-Parameters $output[0]
    $windows = Get-Parameters $output[1]
    Assert ($linux.osProfile.value.linuxConfiguration.disablePasswordAuthentication -eq $true) 'Linux must use SSH provisioning.'
    Assert ($linux.osProfile.value.linuxConfiguration.ssh.publicKeys.Count -eq 1) 'SSH keys must remain an array.'
    Assert (-not $linux.Contains('adminPassword')) 'SSH provisioning must not generate a password.'
    Assert ($windows.adminPassword.reference.secretName -eq 'vm-win-dev-admin-password' -and -not $windows.adminPassword.Contains('value')) 'Password must remain a Key Vault reference.'
    Assert (-not $windows.osProfile.value.Contains('adminPassword')) 'OS profile must not contain a password.'
    Assert ($windows.osProfile.value.windowsConfiguration.timeZone -eq 'GMT Standard Time') 'Windows settings lost.'
    Assert ($linux.zones.value -is [array] -and $linux.zones.value.Count -eq 0) 'Empty zones must remain an array.'
    Assert ($linux.vmProperties.value.storageProfile.dataDisks -is [array] -and $linux.vmProperties.value.storageProfile.dataDisks.Count -eq 1) 'Single data disk must remain an array.'
    Assert ($windows.vmProperties.value.storageProfile.dataDisks -is [array] -and $windows.vmProperties.value.storageProfile.dataDisks.Count -eq 0) 'Empty disk list must remain an array.'
    Assert ($linux.createNic.value -and -not $linux.createPublicIp.value) 'Default networking should create a private NIC.'
    Assert ($linux.nicProperties.value.ipConfigurations[0].properties.subnet.id -eq $rows[0].SubnetId) 'Subnet ID was not forwarded.'
    Assert ($linux.vmProperties.value.storageProfile.osDisk.deleteOption -eq 'Detach') 'Default disks should be retained.'
    Assert ($linux.vmProperties.value.securityProfile.uefiSettings.secureBootEnabled) 'Trusted Launch secure boot missing.'
    Assert ($linux.vmProperties.value.diagnosticsProfile.bootDiagnostics.enabled -and -not $linux.vmProperties.value.diagnosticsProfile.bootDiagnostics.Contains('storageUri')) 'Managed boot diagnostics expected.'
    $template = Get-Content (Join-Path $root 'templates/vm.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($template.parameters.adminPassword.type -eq 'securestring') 'Template password must be securestring.'
    foreach ($item in $output) {
        $parameters = Get-Parameters $item
        foreach ($key in $parameters.Keys) { Assert ($template.parameters.Contains($key)) "Unknown template parameter: $key" }
        foreach ($key in $template.parameters.Keys) { Assert ($template.parameters[$key].Contains('defaultValue') -or $parameters.Contains($key)) "Missing template parameter: $key" }
    }
    $null = & $scriptFile -CsvPath (Join-Path $root 'examples/vms-minimal.csv') -Action Generate -OutputDirectory (Join-Path $temp 'minimal')

    $variant = Get-Parameters (Generate-Variant @{ Zone = '1'; CreatePublicIp = 'true'; PublicIpDnsLabel = 'example-vm'; PrivateIpAddress = '10.10.1.10'; Priority = 'Spot'; MaxPrice = '0.15'; NicPropertiesJson = '{"dnsSettings":{"internalDnsNameLabel":"linux"}}' })
    Assert ($variant.zones.value -is [array] -and $variant.zones.value[0] -eq '1') 'Single zone must remain an array.'
    Assert ($variant.publicIpProperties.value.publicIPAllocationMethod -eq 'Static' -and $variant.createPublicIp.value) 'Public IP settings missing.'
    Assert ($variant.nicProperties.value.ipConfigurations[0].properties.privateIPAllocationMethod -eq 'Static') 'Static private IP setting missing.'
    Assert ($variant.nicProperties.value.dnsSettings.internalDnsNameLabel -eq 'linux') 'Advanced NIC DNS settings lost.'
    Assert ($variant.vmProperties.value.billingProfile.maxPrice -eq 0.15 -and $variant.vmProperties.value.evictionPolicy -eq 'Deallocate') 'Spot price settings lost.'
    $scope = "/subscriptions/$($subscriptions[0])/resourceGroups/rg-vms-dev/providers"
    $variant = Get-Parameters (Generate-Variant @{ ExistingNicResourceId = "$scope/Microsoft.Network/networkInterfaces/existing"; SubnetId = ''; AdditionalVmPropertiesJson = ''; DataDisksJson = '[]' })
    Assert (-not $variant.createNic.value -and $variant.nicProperties.value.Count -eq 0) 'Existing NIC must not be redeployed.'
    Assert ($variant.vmProperties.value.networkProfile.networkInterfaces[0].id -like '*/existing') 'Existing NIC ID lost.'
    $variant = Get-Parameters (Generate-Variant @{ ImagePublisher = ''; ImageOffer = ''; ImageSku = ''; ImageVersion = ''; ImageId = "$scope/Microsoft.Compute/galleries/images/images/linux/versions/1.0.0"; SecurityType = 'Standard'; OsProfileJson = '{"linuxConfiguration":{"patchSettings":{"automaticByPlatformSettings":{"rebootSetting":"IfRequired"}}}}'; PatchMode = 'AutomaticByPlatform'; AdditionalNetworkInterfacesJson = "[{`"id`":`"$scope/Microsoft.Network/networkInterfaces/secondary`"}]"; DataDisksJson = "[{`"lun`":1,`"createOption`":`"Attach`",`"managedDisk`":{`"id`":`"$scope/Microsoft.Compute/disks/existing`"}}]" })
    Assert ($variant.vmProperties.value.storageProfile.imageReference.Contains('id')) 'Custom image ID missing.'
    Assert (-not $variant.vmProperties.value.Contains('securityProfile')) 'Standard VM should omit the Trusted Launch security profile.'
    Assert ($variant.osProfile.value.linuxConfiguration.patchSettings.patchMode -eq 'AutomaticByPlatform') 'Advanced OS settings must preserve dedicated patch mode.'
    Assert ($variant.vmProperties.value.networkProfile.networkInterfaces.Count -eq 2 -and -not $variant.vmProperties.value.networkProfile.networkInterfaces[1].properties.primary) 'Additional NIC settings incorrect.'
    Assert ($variant.vmProperties.value.storageProfile.dataDisks[0].deleteOption -eq 'Detach') 'Attached data disk should default to retention.'
    $null = Generate-Variant @{ IdentityType = 'SystemAssigned, UserAssigned'; UserAssignedIdentityIds = "$scope/Microsoft.ManagedIdentity/userAssignedIdentities/vm-identity"; ExtensionsJson = '[{"name":"agent","properties":{"publisher":"example","type":"Agent","typeHandlerVersion":"1.0","settings":{}}}]' }

    foreach ($case in @(
            @{ Changes = @{ SubscriptionId = 'invalid' }; Error = '*SubscriptionId must be*' },
            @{ Changes = @{ CreatePublicIp = 'yes' }; Error = '*use true or false*' },
            @{ Changes = @{ AuthenticationType = 'Password' }; Error = '*SshPublicKey must be blank*' },
            @{ Changes = @{ AuthenticationType = 'Password'; SshPublicKey = '' }; Error = '*requires AdminPasswordKeyVaultId*' },
            @{ Changes = @{ SshPublicKey = 'not-a-key' }; Error = '*SshPublicKey must*' },
            @{ Changes = @{ ImageId = "$scope/Microsoft.Compute/images/custom" }; Error = '*Use ImageId or Marketplace*' },
            @{ Changes = @{ OsProfileJson = '{"adminPassword":"do-not-serialize"}' }; Error = '*managed by dedicated CSV columns*' },
            @{ Changes = @{ AdditionalVmPropertiesJson = '{"osProfile":{}}' }; Error = '*managed by dedicated CSV columns*' },
            @{ Changes = @{ DataDisksJson = '[{"lun":0,"createOption":"Empty","diskSizeGB":10},{"lun":0,"createOption":"Empty","diskSizeGB":20}]' }; Error = '*LUNs must be unique*' },
            @{ Changes = @{ DataDisksJson = '[{"lun":0,"createOption":"Attach"}]' }; Error = '*managedDisk.id*' },
            @{ Changes = @{ Zone = '1'; AvailabilitySetId = "$scope/Microsoft.Compute/availabilitySets/shared" }; Error = '*mutually exclusive*' },
            @{ Changes = @{ MaxPrice = '0.3' }; Error = '*require Priority=Spot*' },
            @{ Changes = @{ IdentityType = 'UserAssigned' }; Error = '*requires UserAssignedIdentityIds*' },
            @{ Changes = @{ CreatePublicIp = 'true'; ExistingPublicIpId = "$scope/Microsoft.Network/publicIPAddresses/existing" }; Error = '*mutually exclusive*' },
            @{ Changes = @{ CustomDataBase64 = 'bad-base64' }; Error = '*valid base64*' },
            @{ Changes = @{ NicName = 'parent/child' }; Error = '*NicName*use 1-80*' },
            @{ Changes = @{ OsDiskName = 'parent/child' }; Error = '*OsDiskName*use 1-80*' },
            @{ Changes = @{ OsProfileJson = '{"ADMINPASSWORD":"do-not-serialize"}' }; Error = '*managed by dedicated*' },
            @{ Changes = @{ TagsJson = '{"Values":"dev","Other":123}' }; Error = '*Tag values must be strings*' },
            @{ Changes = @{ PrivateIpAddress = '10.1' }; Error = '*canonical*' },
            @{ Changes = @{ ProvisionVmAgent = 'false'; PatchMode = 'AutomaticByPlatform' }; Error = '*requires ProvisionVmAgent=true*' },
            @{ Changes = @{ DataDisksJson = '[{"lun":0,"createOption":""}]' }; Error = '*integer lun and createOption*' },
            @{ Changes = @{ AllowExtensionOperations = 'false'; ExtensionsJson = '[{"name":"agent","properties":{"publisher":"example","type":"Agent","typeHandlerVersion":"1.0"}}]' }; Error = '*Extensions require*' },
            @{ Changes = @{ ExtensionsJson = '[{"name":"agent","properties":{"protectedSettings":{"secret":"do-not-serialize"}}}]' }; Error = '*protectedSettingsFromKeyVault*' }
        )) { Assert-Throws { Generate-Variant $case.Changes } $case.Error }
    $bad = Join-Path $temp 'bad.csv'
    @($rows[0], $rows[0]) | Export-Csv $bad -NoTypeInformation
    Assert-Throws { & $scriptFile -CsvPath $bad -Action Generate -OutputDirectory $temp } '*Duplicate resource target*'
    Assert ($global:VmTestState.Calls.Count -eq 0 -and $global:VmTestState.Selections.Count -eq 0) 'Generate/local validation must not call Azure.'
    Assert-Throws { & $scriptFile -CsvPath $exampleCsv -Action Validate -OutputDirectory $temp } '*SshPublicKey must contain a valid*'
    Assert ($global:VmTestState.Selections.Count -eq 0) 'Example SSH placeholders must fail before Azure operations.'

    $common = @{ CsvPath = $csv; OutputDirectory = $temp }
    $results = @(& $scriptFile @common -CreateResourceGroups)
    Assert ($results.Count -eq 2 -and ($results.SubscriptionId -join ',') -eq ($subscriptions -join ',')) 'Deployment results must identify both subscriptions.'
    Assert (@($global:VmTestState.Calls | Where-Object Kind -EQ 'Group').Count -eq 2) 'Create groups separately per subscription.'
    Assert (($global:VmTestState.Selections -join ',') -eq ($subscriptions -join ',')) 'Subscription selection order incorrect.'
    Assert (($global:VmTestState.Lookups -join ',') -eq ($subscriptions -join ',')) 'Group lookups must use each row context.'
    $deployments = @($global:VmTestState.Calls | Where-Object Kind -EQ 'Deployment')
    Assert (($deployments.Vm -join ',') -eq 'vm-linux-dev,vm-win-dev') 'VM deployment order incorrect.'
    Assert (($deployments.Context.Subscription.Id -join ',') -eq ($subscriptions -join ',')) 'Deployment contexts incorrect.'
    Assert (@($deployments | Where-Object Mode -NE 'Incremental').Count -eq 0) 'Incremental deployment required.'
    $global:VmTestState.Calls.Clear()
    $null = & $scriptFile @common -Action WhatIf
    Assert (@($global:VmTestState.Calls | Where-Object { $_.Kind -eq 'Deployment' -and $_.Preview }).Count -eq 2) 'What-if not forwarded.'
    $global:VmTestState.Calls.Clear()
    $null = & $scriptFile @common -Action Validate
    Assert (@($global:VmTestState.Calls | Where-Object Kind -EQ 'Validate').Count -eq 2) 'Validate must process both rows.'
    $global:VmTestState.Calls.Clear()
    $global:VmTestState.ValidationError = $true
    Assert-Throws { & $scriptFile @common -Action Validate -WarningAction SilentlyContinue } '*VM operations failed*'
    Assert ($global:VmTestState.Calls.Count -eq 1) 'Validation should stop on first failure.'
    $global:VmTestState.ValidationError = $false
    $global:VmTestState.FailVm = 'vm-linux-dev'
    $global:VmTestState.Calls.Clear()
    Assert-Throws { & $scriptFile @common -WarningAction SilentlyContinue } '*VM operations failed*'
    Assert ($global:VmTestState.Calls.Count -eq 1) 'Stop on first failure by default.'
    $global:VmTestState.Calls.Clear()
    Assert-Throws { & $scriptFile @common -ContinueOnError -WarningAction SilentlyContinue } '*VM operations failed*'
    Assert ($global:VmTestState.Calls.Count -eq 2) 'ContinueOnError should attempt both VMs.'
    $global:VmTestState.FailVm = ''
    foreach ($failure in @('FailSubscription', 'MismatchSubscription')) {
        $global:VmTestState.Calls.Clear()
        $global:VmTestState.Lookups.Clear()
        $global:VmTestState[$failure] = $subscriptions[0]
        Assert-Throws { & $scriptFile @common -ContinueOnError -WarningAction SilentlyContinue } '*VM operations failed*'
        Assert ($global:VmTestState.Calls.Count -eq 1 -and $global:VmTestState.Calls[0].Context.Subscription.Id -eq $subscriptions[1]) 'Failed context must never use another subscription.'
        Assert (($global:VmTestState.Lookups -join ',') -eq $subscriptions[1]) 'Failed context must not perform resource lookups.'
        $global:VmTestState[$failure] = ''
    }
    $global:VmTestState.Groups = @()
    $global:VmTestState.Calls.Clear()
    Assert-Throws { & $scriptFile @common -Action WhatIf -CreateResourceGroups -WarningAction SilentlyContinue } '*VM operations failed*'
    Assert ($global:VmTestState.Calls.Count -eq 0) 'What-if must not create resource groups.'
    Write-Host 'All VM offline integration checks passed.'
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
    Remove-Variable VmTestState -Scope Global
}
