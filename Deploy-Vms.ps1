#Requires -Version 7.2
<#
.SYNOPSIS
Deploy Windows/Linux VMs sequentially from CSV, selecting each row's subscription.
.EXAMPLE
./Deploy-Vms.ps1 -CsvPath ./examples/vms.csv -Action Generate
.EXAMPLE
./Deploy-Vms.ps1 -CsvPath ./examples/vms.csv -CreateResourceGroups
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $CsvPath,
    [ValidateSet('Generate', 'Validate', 'WhatIf', 'Deploy')][string] $Action = 'Deploy',
    [string] $TemplateFile = (Join-Path $PSScriptRoot 'templates/vm.json'),
    [string] $OutputDirectory = (Join-Path $PSScriptRoot 'generated/vms'),
    [switch] $CreateResourceGroups,
    [switch] $ContinueOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Load the shared CSV readers and Azure deployment loop.
. (Join-Path $PSScriptRoot 'src/Common.ps1')

if (-not (Test-Path -LiteralPath $TemplateFile -PathType Leaf)) {
    throw "Template not found: $TemplateFile"
}
$TemplateFile = (Resolve-Path -LiteralPath $TemplateFile).Path
$null = Get-Content -LiteralPath $TemplateFile -Raw | ConvertFrom-Json -Depth 100

# Only these columns must be present. Missing optional columns use defaults below.
$requiredColumns = @('SubscriptionId', 'ResourceGroupName', 'Location', 'VmName', 'VmSize', 'OsType', 'AdminUsername')
$optionalColumns = @(
    'ResourceGroupLocation', 'ComputerName', 'ImagePublisher', 'ImageOffer', 'ImageSku', 'ImageVersion', 'ImageId', 'PlanJson',
    'AuthenticationType', 'SshPublicKey', 'AdminPasswordKeyVaultId', 'AdminPasswordSecretName', 'AdminPasswordSecretVersion', 'CustomDataBase64',
    'Zone', 'AvailabilitySetId', 'ProximityPlacementGroupId', 'HostId', 'HostGroupId', 'CapacityReservationGroupId',
    'Priority', 'EvictionPolicy', 'MaxPrice', 'LicenseType', 'SecurityType', 'SecureBootEnabled', 'VTpmEnabled', 'EncryptionAtHost',
    'IdentityType', 'UserAssignedIdentityIds', 'OsDiskName', 'OsDiskSizeGB', 'OsDiskStorageAccountType', 'OsDiskCaching',
    'OsDiskDeleteOption', 'OsDiskEncryptionSetId', 'OsDiskPropertiesJson', 'DataDisksJson',
    'ExistingNicResourceId', 'NicName', 'SubnetId', 'PrivateIpAddress', 'EnableAcceleratedNetworking', 'EnableIpForwarding',
    'NicDnsServers', 'NsgId', 'ApplicationSecurityGroupIds', 'LoadBalancerBackendPoolIds', 'LoadBalancerInboundNatRuleIds',
    'NicDeleteOption', 'AdditionalNetworkInterfacesJson', 'AdditionalIpConfigurationsJson', 'NicPropertiesJson',
    'CreatePublicIp', 'ExistingPublicIpId', 'PublicIpName', 'PublicIpDnsLabel', 'PublicIpIdleTimeoutMinutes', 'PublicIpPropertiesJson',
    'BootDiagnosticsEnabled', 'BootDiagnosticsStorageUri', 'ProvisionVmAgent', 'AllowExtensionOperations',
    'WindowsEnableAutomaticUpdates', 'WindowsTimeZone', 'PatchMode', 'AssessmentMode', 'OsProfileJson',
    'SecurityProfileJson', 'AdditionalVmPropertiesJson', 'ExtensionsJson', 'TagsJson'
)
$rows = @(Import-DeploymentCsv -Path $CsvPath -RequiredColumns $requiredColumns -OptionalColumns $optionalColumns)

$seenResources = @{}
$groupLocations = @{}
# Build every plan before writing files or contacting Azure.
$plans = @(
    for ($index = 0; $index -lt $rows.Count; $index++) {
        try {
            # Treat omitted optional columns and empty cells the same way.
            $row = @{}
            foreach ($column in ($requiredColumns + $optionalColumns)) {
                $row[$column] = ''
            }
            foreach ($property in $rows[$index].PSObject.Properties) {
                $row[$property.Name] = ([string]$property.Value).Trim()
            }
            foreach ($column in $requiredColumns) {
                if (-not $row[$column]) {
                    throw "$column is required."
                }
            }
            $subscriptionGuid = [guid]::Empty
            if (-not [guid]::TryParseExact($row.SubscriptionId, 'D', [ref]$subscriptionGuid)) {
                throw 'SubscriptionId must be a subscription GUID.'
            }
            $row.SubscriptionId = $subscriptionGuid.ToString('D')
            if ($row.ResourceGroupName.Length -gt 90 -or
                $row.ResourceGroupName -notmatch '^[\p{L}\p{N}_().-]+$' -or
                $row.ResourceGroupName.EndsWith('.')) {
                throw 'Invalid ResourceGroupName.'
            }
            if ($row.VmName -notmatch '^[a-zA-Z0-9](?:[a-zA-Z0-9_.-]{0,62}[a-zA-Z0-9_])?$') {
                throw 'VmName must be 1-64 characters with a valid Azure resource name.'
            }

            # Check the deployment target and guest computer name.
            $scope = "/subscriptions/$($row.SubscriptionId)/resourceGroups/$($row.ResourceGroupName)/providers"
            $osType = Read-Choice $row.OsType 'OsType' @('Linux', 'Windows') ''
            $computerName = if ($row.ComputerName) { $row.ComputerName } else { $row.VmName }
            $maxComputerName = if ($osType -eq 'Windows') { 15 } else { 64 }
            if ($computerName.Length -gt $maxComputerName -or
                $computerName -notmatch '^[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?$' -or
                $computerName -match '^\d+$') {
                throw "ComputerName must be a nonnumeric hostname of at most $maxComputerName characters; set it separately from VmName if needed."
            }
            if ($row.AdminUsername -notmatch '^[a-zA-Z_][a-zA-Z0-9_-]{0,31}$' -or
                ($osType -eq 'Windows' -and
                $row.AdminUsername.Length -gt 20)) {
                throw 'AdminUsername must be a valid local account name (up to 20 characters on Windows, 32 on Linux).'
            }

            # Credentials: Linux defaults to SSH; Windows uses a Key Vault password reference.
            $defaultAuthentication = if ($osType -eq 'Linux') { 'Ssh' } else { 'Password' }
            $authenticationType = Read-Choice $row.AuthenticationType 'AuthenticationType' @('Ssh', 'Password') $defaultAuthentication
            $osProfile = @{
                computerName = $computerName
                adminUsername = $row.AdminUsername
                allowExtensionOperations = (Read-BoolCell $row.AllowExtensionOperations 'AllowExtensionOperations' $true)
            }
            $passwordParameter = $null
            if ($authenticationType -eq 'Ssh') {
                if ($osType -ne 'Linux') {
                    throw 'Ssh authentication is supported only for Linux provisioning.'
                }
                Assert-SshPublicKey $row.SshPublicKey $Action
                if ($row.AdminPasswordKeyVaultId -or $row.AdminPasswordSecretName -or $row.AdminPasswordSecretVersion) {
                    throw 'Password reference columns must be blank for Ssh authentication.'
                }
                $osProfile.linuxConfiguration = @{
                    disablePasswordAuthentication = $true
                    provisionVMAgent = (Read-BoolCell $row.ProvisionVmAgent 'ProvisionVmAgent' $true)
                    ssh = @{
                        publicKeys = @(
                            @{
                                path = "/home/$($row.AdminUsername)/.ssh/authorized_keys"
                                keyData = $row.SshPublicKey
                            }
                        )
                    }
                }
            }
            else {
                if ($row.SshPublicKey) {
                    throw 'SshPublicKey must be blank for Password authentication.'
                }
                if (-not $row.AdminPasswordKeyVaultId -or -not $row.AdminPasswordSecretName) {
                    throw 'Password authentication requires AdminPasswordKeyVaultId and AdminPasswordSecretName.'
                }
                Assert-ResourceId $row.AdminPasswordKeyVaultId 'Microsoft.KeyVault/vaults/[^/]+' 'AdminPasswordKeyVaultId'
                $reference = @{
                    keyVault = @{ id = $row.AdminPasswordKeyVaultId }
                    secretName = $row.AdminPasswordSecretName
                }
                if ($row.AdminPasswordSecretVersion) {
                    $reference.secretVersion = $row.AdminPasswordSecretVersion
                }
                $passwordParameter = @{ reference = $reference }
                if ($osType -eq 'Linux') {
                    $osProfile.linuxConfiguration = @{
                        disablePasswordAuthentication = $false
                        provisionVMAgent = (Read-BoolCell $row.ProvisionVmAgent 'ProvisionVmAgent' $true)
                    }
                }
                else {
                    $osProfile.windowsConfiguration = @{
                        provisionVMAgent = (Read-BoolCell $row.ProvisionVmAgent 'ProvisionVmAgent' $true)
                        enableAutomaticUpdates = (Read-BoolCell $row.WindowsEnableAutomaticUpdates 'WindowsEnableAutomaticUpdates' $true)
                    }
                }
            }

            # Guest settings: VM agent, updates, patching and optional startup data.
            $configuration = if ($osType -eq 'Windows') { $osProfile.windowsConfiguration } else { $osProfile.linuxConfiguration }
            if ($osType -eq 'Windows' -and $row.WindowsTimeZone) {
                $configuration.timeZone = $row.WindowsTimeZone
            }
            if ($osType -eq 'Linux' -and ($row.WindowsTimeZone -or $row.WindowsEnableAutomaticUpdates)) {
                throw 'Windows configuration columns must be blank for Linux.'
            }
            if ($row.PatchMode -or $row.AssessmentMode) {
                $configuration.patchSettings = @{}
                if ($row.PatchMode) {
                    $patchModes = if ($osType -eq 'Windows') {
                        @('Manual', 'AutomaticByOS', 'AutomaticByPlatform')
                    }
                    else {
                        @('ImageDefault', 'AutomaticByPlatform')
                    }
                    $configuration.patchSettings.patchMode = Read-Choice $row.PatchMode 'PatchMode' $patchModes ''
                }
                if ($row.AssessmentMode) {
                    $configuration.patchSettings.assessmentMode = Read-Choice $row.AssessmentMode 'AssessmentMode' @('ImageDefault', 'AutomaticByPlatform') ''
                }
            }
            if ($row.CustomDataBase64) {
                try {
                    $bytes = [Convert]::FromBase64String($row.CustomDataBase64)
                }
                catch {
                    throw 'CustomDataBase64 must be valid base64.'
                }
                if ($bytes.Length -gt 65535) {
                    throw 'CustomDataBase64 exceeds 65535 decoded bytes.'
                }
                $osProfile.customData = $row.CustomDataBase64
            }
            $extraOs = Read-JsonCell $row.OsProfileJson 'OsProfileJson' ([System.Collections.IDictionary]) @{}
            Assert-NoKey $extraOs @('adminPassword', 'adminUsername', 'computerName', 'customData', 'allowExtensionOperations') 'OsProfileJson'
            $wrongConfiguration = if ($osType -eq 'Windows') { 'linuxConfiguration' } else { 'windowsConfiguration' }
            Assert-NoKey $extraOs @($wrongConfiguration) 'OsProfileJson'
            $configurationName = if ($osType -eq 'Windows') { 'windowsConfiguration' } else { 'linuxConfiguration' }
            if ($extraOs.Contains($configurationName)) {
                if ($extraOs[$configurationName] -isnot [System.Collections.IDictionary]) {
                    throw 'OS configuration in OsProfileJson must be an object.'
                }
                Assert-NoKey $extraOs[$configurationName] @('disablePasswordAuthentication', 'ssh', 'provisionVMAgent', 'enableAutomaticUpdates', 'timeZone') 'OsProfileJson OS configuration'
                if ($extraOs[$configurationName].Contains('patchSettings')) {
                    if ($extraOs[$configurationName].patchSettings -isnot [System.Collections.IDictionary]) {
                        throw 'OsProfileJson patchSettings must be an object.'
                    }
                    Assert-NoKey $extraOs[$configurationName].patchSettings @('patchMode', 'assessmentMode') 'OsProfileJson patchSettings'
                }
            }
            $osProfile = Merge-JsonObject $osProfile $extraOs
            $configuration = $osProfile[$configurationName]
            if ($configuration.Contains('patchSettings')) {
                $patchSettings = $configuration.patchSettings
                if ((($patchSettings.Contains('patchMode') -and $patchSettings.patchMode -eq 'AutomaticByPlatform') -or
                            ($patchSettings.Contains('assessmentMode') -and $patchSettings.assessmentMode -eq 'AutomaticByPlatform')) -and
                        -not $configuration.provisionVMAgent) {
                    throw 'Platform patching or assessment requires ProvisionVmAgent=true.'
                }
                if ($osType -eq 'Windows' -and $patchSettings.Contains('patchMode')) {
                    if ($patchSettings.patchMode -eq 'Manual' -and $configuration.enableAutomaticUpdates) {
                        throw 'Windows Manual patching requires WindowsEnableAutomaticUpdates=false.'
                    }
                    if ($patchSettings.patchMode -ne 'Manual' -and -not $configuration.enableAutomaticUpdates) {
                        throw 'Windows automatic patching requires WindowsEnableAutomaticUpdates=true.'
                    }
                }
            }

            # Choose a custom image or a Marketplace image.
            if ($row.ImageId) {
                if ($row.ImagePublisher -or $row.ImageOffer -or $row.ImageSku -or $row.ImageVersion) {
                    throw 'Use ImageId or Marketplace image columns, not both.'
                }
                Assert-ResourceId $row.ImageId 'Microsoft.Compute/(images/[^/]+|galleries/[^/]+/images/[^/]+/versions/[^/]+)' 'ImageId'
                $image = @{ id = $row.ImageId }
            }
            else {
                if (-not $row.ImagePublisher -or -not $row.ImageOffer -or -not $row.ImageSku) {
                    throw 'Specify ImageId or all of ImagePublisher, ImageOffer and ImageSku.'
                }
                $image = @{
                    publisher = $row.ImagePublisher
                    offer = $row.ImageOffer
                    sku = $row.ImageSku
                    version = $(if ($row.ImageVersion) { $row.ImageVersion } else { 'latest' })
                }
            }

            # Build the OS disk and any extra data disks. Disks are kept by default on VM deletion.
            $osDisk = @{
                name = $(if ($row.OsDiskName) { $row.OsDiskName } else { "$($row.VmName)-os" })
                createOption = 'FromImage'
                osType = $osType
                caching = (Read-Choice $row.OsDiskCaching 'OsDiskCaching' @('None', 'ReadOnly', 'ReadWrite') 'ReadWrite')
                deleteOption = (Read-Choice $row.OsDiskDeleteOption 'OsDiskDeleteOption' @('Detach', 'Delete') 'Detach')
                managedDisk = @{ storageAccountType = (Read-Choice $row.OsDiskStorageAccountType 'OsDiskStorageAccountType' @('Standard_LRS', 'StandardSSD_LRS', 'Premium_LRS', 'StandardSSD_ZRS', 'Premium_ZRS') 'Premium_LRS') }
            }
            if ($row.OsDiskSizeGB) {
                $osDisk.diskSizeGB = Read-IntCell $row.OsDiskSizeGB 'OsDiskSizeGB' 1 4095
            }
            if ($row.OsDiskEncryptionSetId) {
                Assert-ResourceId $row.OsDiskEncryptionSetId 'Microsoft.Compute/diskEncryptionSets/[^/]+' 'OsDiskEncryptionSetId'
                $osDisk.managedDisk.diskEncryptionSet = @{ id = $row.OsDiskEncryptionSetId }
            }
            $extraDisk = Read-JsonCell $row.OsDiskPropertiesJson 'OsDiskPropertiesJson' ([System.Collections.IDictionary]) @{}
            Assert-NoKey $extraDisk @('name', 'createOption', 'osType', 'diskSizeGB', 'caching', 'deleteOption', 'image', 'vhd') 'OsDiskPropertiesJson'
            if ($extraDisk.Contains('managedDisk')) {
                if ($extraDisk.managedDisk -isnot [System.Collections.IDictionary]) {
                    throw 'OsDiskPropertiesJson.managedDisk must be an object.'
                }
                Assert-NoKey $extraDisk.managedDisk @('id', 'storageAccountType', 'diskEncryptionSet') 'OsDiskPropertiesJson.managedDisk'
            }
            $osDisk = Merge-JsonObject $osDisk $extraDisk
            Assert-ResourceName $osDisk.name 'OsDiskName'
            $dataDisks = Read-JsonCell $row.DataDisksJson 'DataDisksJson' ([array]) @()
            $luns = @{}
            foreach ($disk in $dataDisks) {
                if ($disk -isnot [System.Collections.IDictionary] -or -not $disk.Contains('lun') -or
                        ($disk.lun -isnot [long] -and $disk.lun -isnot [int]) -or -not $disk.Contains('createOption') -or
                        [string]::IsNullOrWhiteSpace($disk.createOption)) {
                    throw 'Each data disk needs an integer lun and createOption.'
                }
                if ($disk.Contains('name')) {
                    Assert-ResourceName $disk.name 'DataDisksJson.name'
                }
                if ($disk.lun -lt 0 -or $disk.lun -gt 63 -or $luns.ContainsKey([string]$disk.lun)) {
                    throw 'Data disk LUNs must be unique integers from 0 to 63.'
                }
                $luns[[string]$disk.lun] = $true
                $disk.createOption = Read-Choice $disk.createOption 'DataDisksJson.createOption' @('Empty', 'Attach', 'FromImage') ''
                if ($disk.createOption -eq 'Empty' -and
                    (-not $disk.Contains('diskSizeGB') -or
                    ($disk.diskSizeGB -isnot [long] -and
                    $disk.diskSizeGB -isnot [int]) -or
                    $disk.diskSizeGB -le 0)) {
                    throw 'An Empty data disk needs a positive integer diskSizeGB.'
                }
                if ($disk.createOption -eq 'Attach') {
                    if (-not $disk.Contains('managedDisk') -or
                        $disk.managedDisk -isnot [System.Collections.IDictionary] -or
                        -not $disk.managedDisk.Contains('id')) {
                        throw 'An Attach data disk needs managedDisk.id.'
                    }
                    Assert-ResourceId $disk.managedDisk.id 'Microsoft.Compute/disks/[^/]+' 'DataDisksJson.managedDisk.id'
                }
                $disk.deleteOption = Read-Choice $(if ($disk.Contains('deleteOption')) { $disk.deleteOption } else { '' }) 'DataDisksJson.deleteOption' @('Detach', 'Delete') 'Detach'
            }
            $properties = @{
                hardwareProfile = @{ vmSize = $row.VmSize }
                storageProfile = @{
                    imageReference = $image
                    osDisk = $osDisk
                    dataDisks = $dataDisks
                }
            }

            # Placement and Spot pricing are optional.
            $zones = @()
            if ($row.Zone) {
                $zones = @($row.Zone)
            }
            if ($row.Zone -and $row.AvailabilitySetId) {
                throw 'Zone and AvailabilitySetId are mutually exclusive.'
            }
            if ($row.HostId -and $row.HostGroupId) {
                throw 'HostId and HostGroupId are mutually exclusive.'
            }
            foreach ($entry in @(
                    @('AvailabilitySetId', 'availabilitySet', 'Microsoft.Compute/availabilitySets/[^/]+'),
                    @('ProximityPlacementGroupId', 'proximityPlacementGroup', 'Microsoft.Compute/proximityPlacementGroups/[^/]+'),
                    @('HostId', 'host', 'Microsoft.Compute/hostGroups/[^/]+/hosts/[^/]+'),
                    @('HostGroupId', 'hostGroup', 'Microsoft.Compute/hostGroups/[^/]+')
                )) {
                $columnName, $propertyName, $resourceType = $entry
                if ($row[$columnName]) {
                    Assert-ResourceId $row[$columnName] $resourceType $columnName
                    $properties[$propertyName] = @{ id = $row[$columnName] }
                }
            }
            if ($row.CapacityReservationGroupId) {
                Assert-ResourceId $row.CapacityReservationGroupId 'Microsoft.Compute/capacityReservationGroups/[^/]+' 'CapacityReservationGroupId'
                $properties.capacityReservation = @{ capacityReservationGroup = @{ id = $row.CapacityReservationGroupId } }
            }
            $properties.priority = Read-Choice $row.Priority 'Priority' @('Regular', 'Spot') 'Regular'
            if ($properties.priority -eq 'Spot') {
                if ($row.AvailabilitySetId -or $row.CapacityReservationGroupId) {
                    throw 'Spot VMs cannot use an availability set or capacity reservation group.'
                }
                $properties.evictionPolicy = Read-Choice $row.EvictionPolicy 'EvictionPolicy' @('Deallocate', 'Delete') 'Deallocate'
                $maxPrice = -1.0
                if ($row.MaxPrice) {
                    $validPrice = [double]::TryParse(
                        $row.MaxPrice,
                        [System.Globalization.NumberStyles]::Float,
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [ref]$maxPrice
                    )
                    if (-not $validPrice -or [double]::IsNaN($maxPrice) -or
                        [double]::IsInfinity($maxPrice) -or ($maxPrice -ne -1 -and $maxPrice -lt 0)) {
                        throw 'MaxPrice must be -1 or a nonnegative decimal (USD/hour).'
                    }
                }
                $properties.billingProfile = @{ maxPrice = $maxPrice }
            }
            elseif ($row.EvictionPolicy -or $row.MaxPrice) {
                throw 'EvictionPolicy and MaxPrice require Priority=Spot.'
            }
            if ($row.LicenseType) {
                $properties.licenseType = $row.LicenseType
            }

            # Trusted Launch is the default; choose Standard for an incompatible image or size.
            $securityType = Read-Choice $row.SecurityType 'SecurityType' @('Standard', 'TrustedLaunch', 'ConfidentialVM') 'TrustedLaunch'
            $security = Read-JsonCell $row.SecurityProfileJson 'SecurityProfileJson' ([System.Collections.IDictionary]) @{}
            Assert-NoKey $security @('securityType', 'encryptionAtHost', 'uefiSettings') 'SecurityProfileJson'
            if ($securityType -ne 'Standard') {
                $security.securityType = $securityType
                $security.uefiSettings = @{
                    secureBootEnabled = (Read-BoolCell $row.SecureBootEnabled 'SecureBootEnabled' $true)
                    vTpmEnabled = (Read-BoolCell $row.VTpmEnabled 'VTpmEnabled' $true)
                }
            }
            elseif ($row.SecureBootEnabled -or $row.VTpmEnabled) {
                throw 'SecureBootEnabled and VTpmEnabled require TrustedLaunch or ConfidentialVM.'
            }
            if ($row.EncryptionAtHost) {
                $security.encryptionAtHost = Read-BoolCell $row.EncryptionAtHost 'EncryptionAtHost' $false
            }
            if ($security.Count) {
                $properties.securityProfile = $security
            }

            # Managed identities allow the VM to access Azure services without stored credentials.
            $identity = @{ type = (Read-Choice $row.IdentityType 'IdentityType' @('None', 'SystemAssigned', 'UserAssigned', 'SystemAssigned, UserAssigned') 'None') }
            $identityIds = Read-ListCell $row.UserAssignedIdentityIds
            if ($identity.type -match 'UserAssigned') {
                if ($identityIds.Count -eq 0) {
                    throw 'UserAssigned identity requires UserAssignedIdentityIds.'
                }
                $identity.userAssignedIdentities = @{}
                foreach ($id in $identityIds) {
                    Assert-ResourceId $id 'Microsoft.ManagedIdentity/userAssignedIdentities/[^/]+' 'UserAssignedIdentityIds'
                    $identity.userAssignedIdentities[$id] = @{}
                }
            }
            elseif ($identityIds.Count) {
                throw 'UserAssignedIdentityIds requires a UserAssigned identity type.'
            }
            $boot = @{ enabled = (Read-BoolCell $row.BootDiagnosticsEnabled 'BootDiagnosticsEnabled' $true) }
            if ($row.BootDiagnosticsStorageUri) {
                if (-not $boot.enabled -or $row.BootDiagnosticsStorageUri -notmatch '^https://') {
                    throw 'BootDiagnosticsStorageUri requires enabled diagnostics and an HTTPS storage URI.'
                }
                $boot.storageUri = $row.BootDiagnosticsStorageUri
            }
            $properties.diagnosticsProfile = @{ bootDiagnostics = $boot }

            $nicName = if ($row.NicName) { $row.NicName } else { "$($row.VmName)-nic" }
            $publicIpName = if ($row.PublicIpName) { $row.PublicIpName } else { "$($row.VmName)-pip" }

            # Use an existing NIC or create one in an existing subnet. Public IPs are optional.
            $createNic = -not [bool]$row.ExistingNicResourceId
            $createPublicIp = Read-BoolCell $row.CreatePublicIp 'CreatePublicIp' $false
            $nicProperties = @{}
            $publicIpProperties = @{}
            if ($createNic) {
                Assert-ResourceName $nicName 'NicName'
                if (-not $row.SubnetId) {
                    throw 'SubnetId is required when creating a NIC.'
                }
                Assert-ResourceId $row.SubnetId 'Microsoft.Network/virtualNetworks/[^/]+/subnets/[^/]+' 'SubnetId'
                $nicId = "$scope/Microsoft.Network/networkInterfaces/$nicName"
                $nicProperties = Read-JsonCell $row.NicPropertiesJson 'NicPropertiesJson' ([System.Collections.IDictionary]) @{}
                Assert-NoKey $nicProperties @('ipConfigurations', 'enableAcceleratedNetworking', 'enableIPForwarding', 'networkSecurityGroup') 'NicPropertiesJson'
                $nicProperties.enableAcceleratedNetworking = Read-BoolCell $row.EnableAcceleratedNetworking 'EnableAcceleratedNetworking' $false
                $nicProperties.enableIPForwarding = Read-BoolCell $row.EnableIpForwarding 'EnableIpForwarding' $false
                if ($row.NsgId) {
                    Assert-ResourceId $row.NsgId 'Microsoft.Network/networkSecurityGroups/[^/]+' 'NsgId'
                    $nicProperties.networkSecurityGroup = @{ id = $row.NsgId }
                }
                $dns = Read-ListCell $row.NicDnsServers
                foreach ($server in $dns) {
                    Assert-IpAddress $server 'NicDnsServers'
                }
                if ($nicProperties.Contains('dnsSettings')) {
                    if ($nicProperties.dnsSettings -isnot [System.Collections.IDictionary]) {
                        throw 'NicPropertiesJson.dnsSettings must be an object.'
                    }
                    Assert-NoKey $nicProperties.dnsSettings @('dnsServers') 'NicPropertiesJson.dnsSettings'
                }
                else {
                    $nicProperties.dnsSettings = @{}
                }
                $nicProperties.dnsSettings.dnsServers = $dns
                $ipProperties = @{
                    primary = $true
                    privateIPAddressVersion = 'IPv4'
                    privateIPAllocationMethod = 'Dynamic'
                    subnet = @{ id = $row.SubnetId }
                }
                if ($row.PrivateIpAddress) {
                    Assert-IpAddress $row.PrivateIpAddress 'PrivateIpAddress' -IPv4Only
                    $ipProperties.privateIPAllocationMethod = 'Static'
                    $ipProperties.privateIPAddress = $row.PrivateIpAddress
                }
                foreach ($entry in @(
                        @('ApplicationSecurityGroupIds', 'applicationSecurityGroups', 'Microsoft.Network/applicationSecurityGroups/[^/]+'),
                        @('LoadBalancerBackendPoolIds', 'loadBalancerBackendAddressPools', 'Microsoft.Network/loadBalancers/[^/]+/backendAddressPools/[^/]+'),
                        @('LoadBalancerInboundNatRuleIds', 'loadBalancerInboundNatRules', 'Microsoft.Network/loadBalancers/[^/]+/inboundNatRules/[^/]+')
                    )) {
                    $columnName, $propertyName, $resourceType = $entry
                    $ids = Read-ListCell $row[$columnName]
                    if ($ids.Count) {
                        $ipProperties[$propertyName] = @(
                            foreach ($id in $ids) {
                                Assert-ResourceId $id $resourceType $columnName
                                @{ id = $id }
                            }
                        )
                    }
                }
                if ($createPublicIp -and $row.ExistingPublicIpId) {
                    throw 'CreatePublicIp and ExistingPublicIpId are mutually exclusive.'
                }
                if ($createPublicIp) {
                    Assert-ResourceName $publicIpName 'PublicIpName'
                    $publicIpProperties = Read-JsonCell $row.PublicIpPropertiesJson 'PublicIpPropertiesJson' ([System.Collections.IDictionary]) @{}
                    Assert-NoKey $publicIpProperties @('publicIPAllocationMethod', 'publicIPAddressVersion', 'idleTimeoutInMinutes', 'dnsSettings') 'PublicIpPropertiesJson'
                    $publicIpProperties.publicIPAllocationMethod = 'Static'
                    $publicIpProperties.publicIPAddressVersion = 'IPv4'
                    $publicIpProperties.idleTimeoutInMinutes = if ($row.PublicIpIdleTimeoutMinutes) { Read-IntCell $row.PublicIpIdleTimeoutMinutes 'PublicIpIdleTimeoutMinutes' 4 30 } else { 4 }
                    if ($row.PublicIpDnsLabel) {
                        $publicIpProperties.dnsSettings = @{ domainNameLabel = $row.PublicIpDnsLabel }
                    }
                    $ipProperties.publicIPAddress = @{ id = "$scope/Microsoft.Network/publicIPAddresses/$publicIpName" }
                }
                else {
                    if ($row.PublicIpName -or $row.PublicIpDnsLabel -or $row.PublicIpIdleTimeoutMinutes -or $row.PublicIpPropertiesJson) {
                        throw 'Public IP creation settings require CreatePublicIp=true.'
                    }
                    if ($row.ExistingPublicIpId) {
                        Assert-ResourceId $row.ExistingPublicIpId 'Microsoft.Network/publicIPAddresses/[^/]+' 'ExistingPublicIpId'
                        $ipProperties.publicIPAddress = @{ id = $row.ExistingPublicIpId }
                    }
                }
                $additionalIps = Read-JsonCell $row.AdditionalIpConfigurationsJson 'AdditionalIpConfigurationsJson' ([array]) @()
                $ipNames = @{ ipconfig1 = $true }
                foreach ($config in $additionalIps) {
                    if ($config -isnot [System.Collections.IDictionary] -or
                        -not $config.Contains('name') -or
                        -not $config.name -or
                        -not $config.Contains('properties') -or
                        $config.properties -isnot [System.Collections.IDictionary]) {
                        throw 'Each additional IP configuration needs name and properties.'
                    }
                    Assert-ResourceName $config.name 'AdditionalIpConfigurationsJson.name'
                    if ($ipNames.ContainsKey($config.name)) {
                        throw 'IP configuration names must be unique.'
                    }
                    $ipNames[$config.name] = $true
                    if ($config.properties.Contains('primary') -and
                        ($config.properties.primary -isnot [bool] -or
                        $config.properties.primary)) {
                        throw 'Additional IP configurations cannot be primary; use the JSON boolean false.'
                    }
                }
                $primaryIpConfiguration = @{
                    name = 'ipconfig1'
                    properties = $ipProperties
                }
                $nicProperties.ipConfigurations = @($primaryIpConfiguration) + $additionalIps
            }
            else {
                Assert-ResourceId $row.ExistingNicResourceId 'Microsoft.Network/networkInterfaces/[^/]+' 'ExistingNicResourceId'
                $nicId = $row.ExistingNicResourceId
                foreach ($column in @(
                    'NicName', 'SubnetId', 'PrivateIpAddress',
                    'EnableAcceleratedNetworking', 'EnableIpForwarding', 'NicDnsServers',
                    'NsgId', 'ApplicationSecurityGroupIds', 'LoadBalancerBackendPoolIds',
                    'LoadBalancerInboundNatRuleIds', 'AdditionalIpConfigurationsJson', 'NicPropertiesJson',
                    'ExistingPublicIpId', 'PublicIpName', 'PublicIpDnsLabel',
                    'PublicIpIdleTimeoutMinutes', 'PublicIpPropertiesJson'
                )) {
                    if ($row[$column]) {
                        throw "$column must be blank when using ExistingNicResourceId."
                    }
                }
                if ($createPublicIp) {
                    throw 'CreatePublicIp requires a new NIC.'
                }
            }

            # Attach the primary NIC and any additional existing NICs.
            $primaryNic = @{
                id = $nicId
                properties = @{
                    primary = $true
                    deleteOption = (Read-Choice $row.NicDeleteOption 'NicDeleteOption' @('Detach', 'Delete') 'Detach')
                }
            }
            $nicReferences = @($primaryNic)
            $additionalNics = Read-JsonCell $row.AdditionalNetworkInterfacesJson 'AdditionalNetworkInterfacesJson' ([array]) @()
            $nicIds = @{ $nicId = $true }
            foreach ($nic in $additionalNics) {
                if ($nic -isnot [System.Collections.IDictionary] -or -not $nic.Contains('id')) {
                    throw 'Each additional NIC needs an id.'
                }
                Assert-ResourceId $nic.id 'Microsoft.Network/networkInterfaces/[^/]+' 'AdditionalNetworkInterfacesJson.id'
                if ($nicIds.ContainsKey($nic.id)) {
                    throw 'NIC references must be unique.'
                }
                $nicIds[$nic.id] = $true
                if (-not $nic.Contains('properties')) {
                    $nic.properties = @{}
                }
                if ($nic.properties -isnot [System.Collections.IDictionary]) {
                    throw 'Additional NIC properties must be an object.'
                }
                if ($nic.properties.Contains('primary') -and ($nic.properties.primary -isnot [bool] -or $nic.properties.primary)) {
                    throw 'Additional NICs cannot be primary; use the JSON boolean false.'
                }
                $nic.properties.primary = $false
                $nic.properties.deleteOption = Read-Choice $(if ($nic.properties.Contains('deleteOption')) { $nic.properties.deleteOption } else { '' }) 'AdditionalNetworkInterfacesJson.deleteOption' @('Detach', 'Delete') 'Detach'
            }
            $properties.networkProfile = @{ networkInterfaces = $nicReferences + $additionalNics }

            # Merge advanced settings, then validate extensions and tags.
            $extraVm = Read-JsonCell $row.AdditionalVmPropertiesJson 'AdditionalVmPropertiesJson' ([System.Collections.IDictionary]) @{}
            Assert-NoKey $extraVm @(
                'osProfile', 'storageProfile', 'networkProfile',
                'securityProfile', 'availabilitySet', 'proximityPlacementGroup',
                'host', 'hostGroup', 'capacityReservation',
                'priority', 'evictionPolicy', 'billingProfile',
                'licenseType', 'diagnosticsProfile'
            ) 'AdditionalVmPropertiesJson'
            if ($extraVm.Contains('hardwareProfile')) {
                if ($extraVm.hardwareProfile -isnot [System.Collections.IDictionary]) {
                    throw 'AdditionalVmPropertiesJson.hardwareProfile must be an object.'
                }
                Assert-NoKey $extraVm.hardwareProfile @('vmSize') 'AdditionalVmPropertiesJson.hardwareProfile'
            }
            $properties = Merge-JsonObject $properties $extraVm
            $extensions = Read-JsonCell $row.ExtensionsJson 'ExtensionsJson' ([array]) @()
            if ($extensions.Count -and (-not $configuration.provisionVMAgent -or -not $osProfile.allowExtensionOperations)) {
                throw 'Extensions require ProvisionVmAgent=true and AllowExtensionOperations=true.'
            }
            $extensionNames = @{}
            foreach ($extension in $extensions) {
                if ($extension -isnot [System.Collections.IDictionary] -or
                    -not $extension.Contains('name') -or
                    -not $extension.name -or
                    -not $extension.Contains('properties') -or
                    $extension.properties -isnot [System.Collections.IDictionary]) {
                    throw 'Each extension needs name and properties.'
                }
                Assert-ResourceName $extension.name 'ExtensionsJson.name'
                if ($extensionNames.ContainsKey($extension.name)) {
                    throw 'Extension names must be unique.'
                }
                $extensionNames[$extension.name] = $true
                if ($extension.properties.Contains('protectedSettings')) {
                    throw 'Use protectedSettingsFromKeyVault instead of plaintext protectedSettings in ExtensionsJson.'
                }
                foreach ($key in @('publisher', 'type', 'typeHandlerVersion')) {
                    if (-not $extension.properties.Contains($key) -or -not $extension.properties[$key]) {
                        throw "Extension properties need $key."
                    }
                }
            }
            $tags = Read-JsonCell $row.TagsJson 'TagsJson' ([System.Collections.IDictionary]) @{}
            foreach ($value in $tags.psbase.Values) {
                if ($value -isnot [string]) {
                    throw 'Tag values must be strings.'
                }
            }
            $plan = Read-JsonCell $row.PlanJson 'PlanJson' ([System.Collections.IDictionary]) @{}
            if ($plan.Count) {
                foreach ($key in @('name', 'publisher', 'product')) {
                    if (-not $plan.Contains($key) -or -not $plan[$key]) {
                        throw "PlanJson requires $key."
                    }
                }
            }

            # Catch duplicate resource names across CSV rows before starting any deployment.
            $resourceIds = @("$scope/Microsoft.Compute/virtualMachines/$($row.VmName)", "$scope/Microsoft.Compute/disks/$($osDisk.name)")
            if ($createNic) {
                $resourceIds += $nicId
            }
            if ($createPublicIp) {
                $resourceIds += "$scope/Microsoft.Network/publicIPAddresses/$publicIpName"
            }
            foreach ($disk in $dataDisks) {
                if ($disk.createOption -ne 'Attach' -and $disk.Contains('name')) {
                    $resourceIds += "$scope/Microsoft.Compute/disks/$($disk.name)"
                }
            }
            foreach ($id in $resourceIds) {
                if ($seenResources.ContainsKey($id)) {
                    throw "Duplicate resource target: $id"
                }
                $seenResources[$id] = $true
            }
            $groupKey = "$($row.SubscriptionId)/$($row.ResourceGroupName)"
            $groupLocation = if ($row.ResourceGroupLocation) { $row.ResourceGroupLocation } else { $row.Location }
            if ($CreateResourceGroups -and $groupLocations.ContainsKey($groupKey) -and $groupLocations[$groupKey] -ne $groupLocation) {
                throw 'Conflicting resource group locations within a subscription.'
            }
            $groupLocations[$groupKey] = $groupLocation

            # Map the completed settings to the ARM template parameters.
            $parameters = [ordered]@{
                vmName = @{ value = $row.VmName }
                location = @{ value = $row.Location }
                tags = @{ value = $tags }
                zones = @{ value = $zones }
                identity = @{ value = $identity }
                plan = @{ value = $plan }
                vmProperties = @{ value = $properties }
                osProfile = @{ value = $osProfile }
                createNic = @{ value = $createNic }
                nicName = @{ value = $nicName }
                nicProperties = @{ value = $nicProperties }
                createPublicIp = @{ value = $createPublicIp }
                publicIpName = @{ value = $publicIpName }
                publicIpProperties = @{ value = $publicIpProperties }
                extensions = @{ value = $extensions }
            }
            if ($null -ne $passwordParameter) {
                $parameters.adminPassword = $passwordParameter
            }
            [pscustomobject]@{
                Row = $index + 2
                SubscriptionId = $row.SubscriptionId
                ResourceGroupName = $row.ResourceGroupName
                ResourceGroupLocation = $groupLocation
                VmName = $row.VmName
                Parameters = $parameters
            }
        }
        catch {
            throw "CSV row $($index + 2): $($_.Exception.Message)"
        }
    }
)

# Write one ARM parameter file per row. Generate stops here; other actions use Azure.
Write-DeploymentBatch -TemplateFile $TemplateFile -Plans $plans -OutputDirectory $OutputDirectory -NameProperty VmName
if ($Action -eq 'Generate') {
    $plans | Select-Object SubscriptionId, ResourceGroupName, VmName, ParameterFile
    return
}
Invoke-DeploymentPlan -Plans $plans -Action $Action `
    -NameProperty VmName -ResourceLabel VM `
    -CreateResourceGroups:$CreateResourceGroups -ContinueOnError:$ContinueOnError
