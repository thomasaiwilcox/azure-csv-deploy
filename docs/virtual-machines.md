# Deploy Azure VMs from CSV

[Back to the project overview](../README.md) · [Virtual networks](virtual-networks.md)

`Deploy-Vms.ps1` deploys one Windows or Linux VM per CSV row, selecting the row's
subscription before each Azure operation. It uses `templates/vm.json` to create
the VM, its managed disks, an optional new primary NIC and Standard public IP, and
optional VM extensions. It can also attach existing NICs and data disks.

- `examples/vms.csv`: all 79 supported columns, with Windows and Linux examples.
- `examples/vms-minimal.csv`: the same examples with only the necessary columns.
- `examples/parameters/vm-linux-dev.parameters.json` and
  `examples/parameters/vm-win-dev.parameters.json`: standalone ARM parameter examples.

## Before deploying

See the [quick start](../README.md#get-started) for installation and commands.
Replace the Linux SSH placeholder with your own `.pub` file contents. For Windows,
provide an existing Key Vault secret reference (see the credentials table below).
`Generate` accepts the SSH placeholder for inspecting examples; Azure actions
require a valid public key.

VMs use existing subnets. Deploy the VNet CSV first if you want to use the example
networks. Other resources referenced by ID must also exist, including NSGs,
identities, additional NICs and attached disks. Register `Microsoft.Compute` and
`Microsoft.Network` in each target subscription. Azure validation checks regional
availability, quota, image compatibility and permissions.

Default paths are relative to the script; paths you supply are relative to your
current directory. `-OutputDirectory` changes the generated file location, and
`-TemplateFile` selects a compatible alternative template. Reruns overwrite files
with the same row number and resource name.

## Field conventions

Only the seven fields marked required below must appear as CSV columns. Other
columns may be omitted or left blank. Booleans use `true`/`false`; list fields use
semicolons; JSON cells use standard CSV escaping. Field names are case insensitive.
Unknown/duplicate columns, missing or extra cells, malformed quoting and duplicate
JSON keys (including casing differences) are rejected to catch editing errors. Each row targets one subscription;
resource group and resource names may repeat across subscriptions.

### Target and image

| Column | Required / default | Meaning |
| --- | --- | --- |
| `SubscriptionId` | Required | Target subscription GUID |
| `ResourceGroupName` | Required | Target resource group |
| `Location` | Required | VM/NIC/public IP region, e.g. `uksouth` |
| `VmName` | Required | VM resource name, 1-64 characters |
| `VmSize` | Required | Azure size, e.g. `Standard_D2s_v5` |
| `OsType` | Required | `Linux` or `Windows` |
| `AdminUsername` | Required | Local administrator; Azure disallows some reserved names |
| `ResourceGroupLocation` | `Location` | Metadata region when creating a group; keep consistent within each subscription/group |
| `ComputerName` | `VmName` | Guest hostname; at most 15 characters on Windows, 64 on Linux; letters, digits and hyphens, not all numeric |
| `ImagePublisher` | Required for Marketplace | E.g. `Canonical` or `MicrosoftWindowsServer` |
| `ImageOffer` | Required for Marketplace | E.g. `ubuntu-24_04-lts` or `WindowsServer` |
| `ImageSku` | Required for Marketplace | E.g. `server` or `2022-datacenter-azure-edition` |
| `ImageVersion` | `latest` | Marketplace image version; pin a specific version for repeatable builds |
| `ImageId` | Blank | Full managed image ID or Compute Gallery image **version** ID; leave all Marketplace fields blank when using this |
| `PlanJson` | `{}` | Marketplace purchase plan object with `name`, `publisher`, `product`; accept applicable Marketplace terms separately |
| `TagsJson` | `{}` | Object of string-valued tags applied to new VM, NIC and public IP |

This workflow provisions a new guest from a Marketplace or generalized custom image.
Attaching a specialized OS disk and deploying VM scale sets require different
templates. A Linux guest can have a resource name longer than Windows' hostname
limit; set `ComputerName` explicitly when needed.

### Credentials and guest configuration

| Column | Default | Meaning |
| --- | --- | --- |
| `AuthenticationType` | `Ssh` for Linux, `Password` for Windows | Windows provisioning requires `Password` |
| `SshPublicKey` | Blank | RSA or Ed25519 public key contents; required for `Ssh`; never supply a private key |
| `AdminPasswordKeyVaultId` | Blank | Full existing vault resource ID; required for `Password` |
| `AdminPasswordSecretName` | Blank | Secret containing the administrator password; required for `Password` |
| `AdminPasswordSecretVersion` | Latest secret | Optional secret version |
| `CustomDataBase64` | Omitted | Base64 guest bootstrap/cloud-init content, at most 65535 decoded bytes |
| `ProvisionVmAgent` | `true` | Provision the Azure VM agent |
| `AllowExtensionOperations` | `true` | Allow extension management |
| `WindowsEnableAutomaticUpdates` | `true` | Windows only |
| `WindowsTimeZone` | Image default | Windows time zone ID, e.g. `GMT Standard Time` |
| `PatchMode` | Image/platform default | Windows: `Manual`, `AutomaticByOS`, `AutomaticByPlatform`; Linux: `ImageDefault`, `AutomaticByPlatform` |
| `AssessmentMode` | Image/platform default | `ImageDefault` or `AutomaticByPlatform` |
| `OsProfileJson` | `{}` | Extra OS profile settings; nested Windows/Linux settings are merged |

For password authentication, the script writes an ARM Key Vault `reference` to the
`securestring` parameter, without retrieving the password. Enable
`enabledForTemplateDeployment` on the vault and grant the deployment identity
`Microsoft.KeyVault/vaults/deploy/action`, as described in Microsoft's reference
below. The generated parameter file remains a secret reference, suitable for reuse.
There is no plaintext password column. For SSH authentication, leave password
reference columns blank; for password authentication, leave `SshPublicKey` blank.

Agent/patch settings must be compatible: Windows `Manual` patching requires
`WindowsEnableAutomaticUpdates=false`; platform-managed patching requires a
supported image and the VM agent, and Windows automatic updates must be enabled.
Extensions also require a functioning VM agent and extension operations enabled.

`OsProfileJson` supports additional unattend content, WinRM configuration,
`enableHotpatching`, and automatic patch scheduling options. Use dedicated columns
for credentials, hostname, agent flags, patch mode and assessment mode. For example:

```json
{"windowsConfiguration":{"patchSettings":{"enableHotpatching":true,"automaticByPlatformSettings":{"rebootSetting":"IfRequired"}}}}
```

Custom data, user data and ordinary extension settings are stored in parameter
files. Keep secrets in Key Vault rather than embedding them in those fields.

### Placement, billing and security

| Column | Default | Meaning |
| --- | --- | --- |
| `Zone` | Regional VM | One availability zone, e.g. `1`; also applies to a newly created public IP |
| `AvailabilitySetId` | Omitted | Existing availability set ID; cannot combine with `Zone` |
| `ProximityPlacementGroupId` | Omitted | Existing proximity placement group ID |
| `HostId` | Omitted | Existing dedicated host ID |
| `HostGroupId` | Omitted | Existing host group ID; cannot combine with `HostId` |
| `CapacityReservationGroupId` | Omitted | Existing capacity reservation group ID |
| `Priority` | `Regular` | `Regular` or `Spot` |
| `EvictionPolicy` | `Deallocate` for Spot | `Deallocate` or `Delete`; Spot only |
| `MaxPrice` | `-1` for Spot | Spot USD/hour ceiling, invariant decimal format; `-1` removes price-based eviction, capacity eviction still applies |
| `LicenseType` | Omitted | Applicable Azure Hybrid Benefit/BYOS license value, e.g. `Windows_Server`; confirm entitlement |
| `SecurityType` | `TrustedLaunch` | `Standard`, `TrustedLaunch`, `ConfidentialVM`; requires compatible image and size |
| `SecureBootEnabled` | `true` for trusted/confidential | Leave blank for `Standard` |
| `VTpmEnabled` | `true` for trusted/confidential | Leave blank for `Standard` |
| `EncryptionAtHost` | Platform default | Optional boolean; may require feature registration/SKU support |
| `SecurityProfileJson` | `{}` | Extra security properties; use dedicated fields for security type, UEFI flags and encryption at host |
| `IdentityType` | `None` | `None`, `SystemAssigned`, `UserAssigned`, or `SystemAssigned, UserAssigned` |
| `UserAssignedIdentityIds` | Empty list | Semicolon-separated existing identity IDs; required when identity type includes `UserAssigned` |

Trusted Launch requires a supported Generation 2 image and VM size. `Standard`
omits the `securityType` and UEFI fields for the pinned Compute API. Confidential
VMs can require additional OS disk/security configuration; the JSON fields allow
that configuration but do not make an incompatible image/SKU deployable.
Spot VMs cannot use availability sets or capacity reservations. Other combinations
of placement, security and disk features remain subject to Azure validation.

### Storage

| Column | Default | Meaning |
| --- | --- | --- |
| `OsDiskName` | `<VmName>-os` | Managed OS disk resource name |
| `OsDiskSizeGB` | Image size | Integer from 1 to 4095; cannot shrink below the image size |
| `OsDiskStorageAccountType` | `Premium_LRS` | `Standard_LRS`, `StandardSSD_LRS`, `Premium_LRS`, `StandardSSD_ZRS`, `Premium_ZRS` |
| `OsDiskCaching` | `ReadWrite` | `None`, `ReadOnly`, `ReadWrite` |
| `OsDiskDeleteOption` | `Detach` | Retain the disk when deleting the VM, or use `Delete` |
| `OsDiskEncryptionSetId` | Omitted | Existing disk encryption set ID |
| `OsDiskPropertiesJson` | `{}` | Extra OS disk properties, e.g. `diffDiskSettings` or nested managed-disk security settings |
| `DataDisksJson` | `[]` | ARM data disk array; unique integer LUNs from 0 to 63; actual disk count depends on VM size |

OS disks use `createOption: FromImage`. `DataDisksJson` supports new empty disks,
image data disks and existing managed disk attachments. Missing data disk
`deleteOption` defaults to `Detach`. New `Empty` disks require `diskSizeGB`;
`Attach` disks require `managedDisk.id`. Other ARM disk fields, such as caching,
IOPS, throughput, encryption sets and write acceleration, pass through unchanged:

```json
[
  {"lun":0,"name":"vm-data0","createOption":"Empty","diskSizeGB":128,"caching":"ReadOnly","deleteOption":"Detach","managedDisk":{"storageAccountType":"Premium_LRS"}},
  {"lun":1,"createOption":"Attach","managedDisk":{"id":"/subscriptions/.../resourceGroups/.../providers/Microsoft.Compute/disks/existing-data"}}
]
```

`AdditionalVmPropertiesJson` can enable Ultra Disk support through
`{"additionalCapabilities":{"ultraSSDEnabled":true}}`; the associated size, zone
and disk configuration must also support it. For ephemeral OS disks, use
`OsDiskPropertiesJson` for `diffDiskSettings` and choose compatible caching/storage
settings and image/size. Ephemeral data does not follow managed-disk retention.

### Networking

| Column | Default | Meaning |
| --- | --- | --- |
| `ExistingNicResourceId` | Blank | Attach an existing primary NIC instead of creating one |
| `NicName` | `<VmName>-nic` | New primary NIC name |
| `SubnetId` | Required for new NIC | Full existing subnet resource ID |
| `PrivateIpAddress` | Dynamic allocation | Static primary IPv4 address when supplied |
| `EnableAcceleratedNetworking` | `false` | Requires a compatible image and VM size |
| `EnableIpForwarding` | `false` | NIC IP forwarding |
| `NicDnsServers` | VNet DNS | Semicolon-separated DNS IP addresses |
| `NsgId` | No NIC NSG | Existing network security group ID; subnet NSGs still apply |
| `ApplicationSecurityGroupIds` | Empty list | Semicolon-separated ASG IDs for the primary IP configuration |
| `LoadBalancerBackendPoolIds` | Empty list | Semicolon-separated backend pool IDs for the primary IP configuration |
| `LoadBalancerInboundNatRuleIds` | Empty list | Semicolon-separated inbound NAT rule IDs |
| `NicDeleteOption` | `Detach` | Retain the primary NIC when deleting the VM, or use `Delete` |
| `AdditionalNetworkInterfacesJson` | `[]` | Existing secondary NIC references; missing delete option becomes `Detach` |
| `AdditionalIpConfigurationsJson` | `[]` | Extra ARM IP configurations on the new NIC, including IPv6/LB options; cannot be primary |
| `NicPropertiesJson` | `{}` | Extra NIC properties; nested `dnsSettings` supports extras such as `internalDnsNameLabel` |
| `CreatePublicIp` | `false` | Create and associate a Standard/Regional/static IPv4 public IP |
| `ExistingPublicIpId` | Blank | Associate an existing public IP with the new NIC instead |
| `PublicIpName` | `<VmName>-pip` | Name when creating a public IP |
| `PublicIpDnsLabel` | Omitted | Optional regional public DNS label |
| `PublicIpIdleTimeoutMinutes` | `4` | Integer from 4 to 30 for a new public IP |
| `PublicIpPropertiesJson` | `{}` | Extra properties for a newly created public IP |

When using `ExistingNicResourceId`, leave NIC creation/configuration fields blank
and `CreatePublicIp` blank/false. Existing primary and secondary NICs must already
have the desired subnet, NSG and IP configuration; the template does not modify
them. `CreatePublicIp` and `ExistingPublicIpId` are mutually exclusive. Public IP
creation settings require `CreatePublicIp=true`.

The script does not add inbound RDP/SSH rules or create NSGs. The examples have no
public IP. Use your chosen management path (for example Bastion, VPN or private
connectivity), and configure explicit outbound connectivity where the subnet
requires it. A Standard public IP alone does not open RDP/SSH through NSGs.

Examples of secondary NIC references and extra IP configurations:

```json
[{"id":"/subscriptions/.../resourceGroups/.../providers/Microsoft.Network/networkInterfaces/nic-secondary","properties":{"deleteOption":"Detach"}}]
```

```json
[{"name":"ipconfig2","properties":{"privateIPAllocationMethod":"Dynamic","privateIPAddressVersion":"IPv4","subnet":{"id":"/subscriptions/.../resourceGroups/.../providers/Microsoft.Network/virtualNetworks/my-vnet/subnets/my-subnet"}}}]
```

### Diagnostics, extensions and advanced properties

| Column | Default | Meaning |
| --- | --- | --- |
| `BootDiagnosticsEnabled` | `true` | Enable boot diagnostics |
| `BootDiagnosticsStorageUri` | Managed boot diagnostics | Optional HTTPS custom storage endpoint; requires enabled diagnostics |
| `ExtensionsJson` | `[]` | Extension objects containing `name` and ARM `properties`; installed serially in array order |
| `AdditionalVmPropertiesJson` | `{}` | Other writable Compute VM properties, including `additionalCapabilities`, `applicationProfile`, `userData` and extra `hardwareProfile` settings |

Each extension needs `publisher`, `type`, and `typeHandlerVersion`. Extra fields
such as `settings`, `autoUpgradeMinorVersion`, and `enableAutomaticUpgrade` pass
through. Use `protectedSettingsFromKeyVault` for secret configuration; plaintext
`protectedSettings` is rejected. Install monitoring, login or domain-join extensions
using this field with their publisher's supported settings. For example:

```json
[{"name":"AzureMonitorLinuxAgent","properties":{"publisher":"Microsoft.Azure.Monitor","type":"AzureMonitorLinuxAgent","typeHandlerVersion":"1.0","autoUpgradeMinorVersion":true,"enableAutomaticUpgrade":true}}]
```

Data collection rules/associations, backup vault protection, scheduled shutdown,
RBAC assignments and other service resources require their own deployments; they
are not VM properties. JSON fields accept writable properties for the pinned
Compute `2025-04-01` and Network `2025-07-01` APIs. Read-only fields and fields
belonging to different resource types should not be supplied. Fields managed by
dedicated columns cannot be overridden through JSON; the script reports these
conflicts rather than silently changing the requested configuration.

## Editing CSV without manual JSON escaping

Use `Import-Csv`/`Export-Csv` or a CSV-aware editor. For example, update the Linux
key and add another disk while preserving all other columns:

```powershell
$vms = @(Import-Csv ./examples/vms.csv)
$vms[0].SshPublicKey = (Get-Content ~/.ssh/id_rsa.pub -Raw).Trim()
$vms[0].SubscriptionId = 'YOUR-SUBSCRIPTION-GUID'
$vms[0].DataDisksJson = ConvertTo-Json -Depth 20 -Compress -InputObject @(
    @{ lun = 0; createOption = 'Empty'; diskSizeGB = 256; managedDisk = @{ storageAccountType = 'Premium_LRS' } }
)
# Set the other rows' subscription IDs, subnet IDs and Key Vault references too.
$vms | Export-Csv ./my-vms.csv -NoTypeInformation -Encoding utf8
```

## Reruns and standalone ARM deployments

Deployments use incremental mode. Supply the full desired disks, NIC references,
tags, identity and configuration on each rerun. Some changes require deallocation
or VM recreation, and guest provisioning settings cannot generally be changed in
place. Inspect `-Action WhatIf` before changing existing VMs. Parameter generation
overwrites matching files, but failed Azure rows do not roll back earlier successful
rows or partially created resources. A new public IP remains an independent
resource; delete it separately when no longer needed.

For direct ARM deployment, select the subscription explicitly (subscription and
resource group are deployment scope, not template parameters):

```powershell
$context = Set-AzContext -SubscriptionId '11111111-1111-1111-1111-111111111111'
New-AzResourceGroupDeployment -Name vm-linux-dev -ResourceGroupName rg-vms-dev `
    -TemplateFile ./templates/vm.json `
    -TemplateParameterFile ./examples/parameters/vm-linux-dev.parameters.json `
    -Mode Incremental -DefaultProfile $context
```

The generated NIC/public IP IDs include the row's subscription and resource group;
deploy a parameter file at its intended scope, or regenerate it from the corrected
CSV. Replace the example SSH key and IDs before using standalone examples.

## Microsoft references

- [Compute VM template reference](https://learn.microsoft.com/en-us/azure/templates/microsoft.compute/2025-04-01/virtualmachines)
- [VM extension template reference](https://learn.microsoft.com/en-us/azure/templates/microsoft.compute/2025-04-01/virtualmachines/extensions)
- [NIC template reference](https://learn.microsoft.com/en-us/azure/templates/microsoft.network/2025-07-01/networkinterfaces)
- [Public IP template reference](https://learn.microsoft.com/en-us/azure/templates/microsoft.network/2025-07-01/publicipaddresses)
- [Key Vault secret references and deployment permissions](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/key-vault-parameter)
