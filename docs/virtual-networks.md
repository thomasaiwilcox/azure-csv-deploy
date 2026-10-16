# Deploy Azure virtual networks from CSV

[Back to the project overview](../README.md) · [Virtual machines](virtual-machines.md)

`Deploy-Vnets.ps1` reads one VNet per CSV row and deploys them sequentially using
`templates/vnet.json`. Each row generates its own ARM parameter file in `generated/vnets/`.
Two standalone example parameter files are also supplied in `examples/parameters/`.
Each row specifies its own `SubscriptionId`, so one CSV can target multiple
subscriptions. Replace the example subscription GUIDs with your actual IDs.

See the [quick start](../README.md#get-started) for installation and commands.
Your account needs deployment permissions in each target subscription; register
`Microsoft.Network` there if it is not already registered.

`SubscriptionId` selects the deployment scope; it is not an ARM template parameter.
Default paths are relative to the script. Paths you supply are relative to your
current directory. `-OutputDirectory` changes the generated file location, and
`-TemplateFile` selects a compatible alternative template. Reruns overwrite files
for the same subscription, resource group and resource name, including manual edits.
Generated filenames no longer include CSV row numbers. See the
[batch guide](deployment-batches.md) to deploy generated files separately.

## CSV columns

| Column | Required | Format |
| --- | --- | --- |
| `SubscriptionId` | Yes | Target subscription GUID, e.g. `11111111-1111-1111-1111-111111111111` |
| `ResourceGroupName` | Yes | Target resource group |
| `Location` | Yes | VNet region, e.g. `uksouth` |
| `VnetName` | Yes | Unique within its resource group |
| `AddressPrefixes` | Yes | CIDRs separated by semicolons, e.g. `10.10.0.0/16;10.11.0.0/16` |
| `ResourceGroupLocation` | No | Metadata region for a new resource group; defaults to `Location`. Use the same value on all rows sharing a new group in the same subscription. Existing group metadata is unchanged. |
| `DnsServers` | No | IP addresses separated by semicolons. Blank uses Azure-provided DNS. |
| `SubnetsJson` | No | JSON array of ARM subnet objects; blank means `[]` |
| `TagsJson` | No | JSON object with string values; blank means `{}` |
| `AdditionalPropertiesJson` | No | Additional writable VNet properties; blank means `{}` |

Optional columns can be omitted entirely. Unknown columns, duplicate VNet targets,
malformed JSON, invalid subscription GUIDs, invalid basic CIDR/IP syntax, and missing required values are
rejected before any Azure calls. Azure validation checks service-specific rules
such as subnet containment, overlap, delegation compatibility, and linked resource
permissions. Local generation alone does not establish Azure validity.

JSON inside CSV must follow standard CSV escaping: enclose the cell in double
quotes and double every embedded double quote. For example, the JSON
`{"Environment":"dev"}` is stored as `"{""Environment"":""dev""}"`.
Use a CSV-aware editor or `Export-Csv` to avoid manual escaping:

```powershell
$subnets = @(
    @{
        name = 'snet-app'
        properties = @{
            addressPrefix = '10.30.1.0/24'
            defaultOutboundAccess = $false
            # Optional: associate an existing NSG using its full resource ID.
            # networkSecurityGroup = @{ id = '/subscriptions/.../resourceGroups/.../providers/Microsoft.Network/networkSecurityGroups/my-nsg' }
            # routeTable = @{ id = '/subscriptions/.../resourceGroups/.../providers/Microsoft.Network/routeTables/my-routes' }
            # natGateway = @{ id = '/subscriptions/.../resourceGroups/.../providers/Microsoft.Network/natGateways/my-nat' }
            # delegations = @(@{ name = 'web'; properties = @{ serviceName = 'Microsoft.Web/serverFarms' } })
            # privateEndpointNetworkPolicies = 'Disabled'
        }
    }
)
[pscustomobject]@{
    SubscriptionId = '11111111-1111-1111-1111-111111111111' # Replace with your subscription ID.
    ResourceGroupName = 'rg-network-dev'
    ResourceGroupLocation = 'uksouth'
    Location = 'uksouth'
    VnetName = 'vnet-custom-dev'
    AddressPrefixes = '10.30.0.0/16'
    DnsServers = ''
    SubnetsJson = ConvertTo-Json -InputObject $subnets -Depth 30 -Compress
    TagsJson = @{ Environment = 'dev' } | ConvertTo-Json -Compress
    AdditionalPropertiesJson = '{}'
} | Export-Csv ./my-vnets.csv -NoTypeInformation -Encoding utf8
```

`SubnetsJson` passes subnet properties through to ARM, allowing address prefixes,
existing NSG/route table/NAT gateway associations, service endpoints, delegations,
and network policies. `AdditionalPropertiesJson` similarly accepts writable
VNet properties supported by the pinned `2025-07-01` API, for example:

```json
{"enableDdosProtection":true,"ddosProtectionPlan":{"id":"/subscriptions/.../resourceGroups/.../providers/Microsoft.Network/ddosProtectionPlans/my-plan"}}
```

Use the dedicated columns for `addressSpace`, `dhcpOptions`, and `subnets`;
the script rejects those keys in `AdditionalPropertiesJson`. Read-only properties
and peerings should not be supplied there. The template creates VNets and their
subnets; referenced NSGs, route tables, NAT gateways, and DDoS plans must already
exist. Peerings and other resource types require separate templates.

## Updating existing networks

Deployments use incremental mode, but a VNet resource is still applied as a whole.
Supply the full intended subnet list, DNS settings, tags, and advanced properties
on every deployment. Omitting an existing subnet or resetting a property can remove
or reset configuration, or fail if resources depend on it. Review `-Action WhatIf`
before updating existing networks. Completed rows are not rolled back if a later
row fails; by default the script stops at that failure and throws a terminating
error. `-ContinueOnError` attempts the remaining rows and then throws if any failed.

The examples use private subnets (`defaultOutboundAccess: false`). Workloads that
need outbound internet access need an explicit outbound method, such as a NAT
gateway association. The examples do not create a NAT gateway or firewall.

## Standalone ARM deployment

The supplied parameter files can also be used without the CSV script:

```powershell
$context = Set-AzContext -SubscriptionId '11111111-1111-1111-1111-111111111111'
New-AzResourceGroupDeployment -Name vnet-app-dev `
    -ResourceGroupName rg-network-dev `
    -TemplateFile ./templates/vnet.json `
    -TemplateParameterFile ./examples/parameters/vnet-app-dev.parameters.json `
    -Mode Incremental -DefaultProfile $context
```

## Microsoft references

- [VNet ARM API and writable properties](https://learn.microsoft.com/en-us/azure/templates/microsoft.network/2025-07-01/virtualnetworks)
- [New-AzResourceGroupDeployment](https://learn.microsoft.com/en-us/powershell/module/az.resources/new-azresourcegroupdeployment)
- [Incremental deployment behavior](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deployment-modes)
