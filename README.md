# Azure CSV Deploy

PowerShell scripts to save time deploying Azure virtual networks and VMs.
Put one resource on each CSV row, including its subscription ID, and the script
loops through the rows for you.

## Get started

Download the whole repository and open PowerShell 7.2 or newer in its folder.
Install the Azure modules once, then sign in:

```powershell
Install-Module Az.Accounts, Az.Resources -Scope CurrentUser -Repository PSGallery
Connect-AzAccount
```

Copy an example into `local/` (excluded from Git), then edit it with your details:

```powershell
New-Item -ItemType Directory -Path ./local -Force
Copy-Item ./examples/vnets.csv ./local/vnets.csv
Copy-Item ./examples/vms-minimal.csv ./local/vms.csv
```

- **VNets:** replace subscription IDs, resource groups, regions, names and address
  ranges. Only five fields are mandatory; [the minimal CSV](examples/vnets-minimal.csv)
  creates a VNet without subnets. Use [vnets.csv](examples/vnets.csv) to include subnets.
- **VMs:** keep the Linux or Windows rows you need. Set the subscription, resource
  group, region, name, size, image, username and existing subnet ID. Supply an SSH
  public key for Linux or a Key Vault password reference for Windows. The minimal
  examples need 12–13 populated fields; other settings have defaults.

Run either script after editing the CSV. Add `-CreateResourceGroups` to create
missing resource groups:

```powershell
./Deploy-Vnets.ps1 -CsvPath ./local/vnets.csv -CreateResourceGroups
./Deploy-Vms.ps1 -CsvPath ./local/vms.csv -CreateResourceGroups
```

Deploy the networks first if your VMs use their subnets. Your Azure login needs
access to every subscription in the CSV. The scripts select the subscription for
each row automatically.

## Optional commands

`Deploy` is the default action. To check the input and generate parameter files
locally, without an Azure login:

```powershell
./Deploy-Vms.ps1 -CsvPath ./local/vms.csv -Action Generate
```

For Azure validation or a preview of changes, use an **existing resource group**:

```powershell
./Deploy-Vms.ps1 -CsvPath ./local/vms.csv -Action Validate
./Deploy-Vms.ps1 -CsvPath ./local/vms.csv -Action WhatIf
```

These actions also work with `Deploy-Vnets.ps1`. Generated files go in `generated/vnets/`
(VNets) or `generated/vms/` (VMs); change this with `-OutputDirectory`.
The scripts stop on a deployment error unless you pass `-ContinueOnError`.
Successful rows stay deployed if a later row fails.

## Generate now, deploy later

Create a separate batch folder for each VNet or VM CSV:

```powershell
./Deploy-Vnets.ps1 -CsvPath ./local/vnets.csv -Action Generate -OutputDirectory ./generated/network-batch
./Deploy-Vms.ps1 -CsvPath ./local/vms.csv -Action Generate -OutputDirectory ./generated/vm-batch
```

Each folder contains a copy of the ARM template, resource-named parameter files
(such as `vm-linux-dev.parameters.json`), and a `deployments.json` index recording
subscriptions, resource groups, file paths and deployment order. You can move the
folder to another machine without the original CSV. Run it with this repository's
`Deploy-FromFiles.ps1` and `src/` helpers.

Edit the template or parameter files directly if needed, then review and deploy:

```powershell
# Local checks only; no Azure modules or login needed.
./Deploy-FromFiles.ps1 -Path ./generated/vm-batch -Action Verify

# Azure checks against existing resource groups.
./Deploy-FromFiles.ps1 -Path ./generated/vm-batch -Action Validate
./Deploy-FromFiles.ps1 -Path ./generated/vm-batch -Action WhatIf

# Deploy is the default; missing groups can be created here.
./Deploy-FromFiles.ps1 -Path ./generated/vm-batch -CreateResourceGroups
```

Deploy your network batch first when VMs depend on it. The runner uses the current
file contents, with no hash checks, and deploys only entries in the index. `Verify`
checks local structure and consistency; Azure validation checks service-specific
requirements. Neither is a guarantee that deployment will succeed.

Regenerating a batch overwrites generated files, including manual edits. See the
[batch guide](docs/deployment-batches.md) for folder layout and editing details.

## More settings

Optional CSV columns can be omitted or left blank. Use the references when you
need settings beyond the minimal examples:

- [VNet fields and examples](docs/virtual-networks.md)
- [VM fields and examples](docs/virtual-machines.md)
- [Standalone ARM parameter examples](examples/parameters/)

The scripts share helpers in `src/` and use ARM templates in `templates/`, so keep
those folders alongside them. When updating existing resources, include their
complete desired configuration and review `WhatIf` first. VM examples use private
networking and keep disks when the VM is deleted.

If you change the scripts, run `pwsh -NoProfile -File ./tests/Test-Project.ps1`.
These checks run locally with mocked Azure commands; live Azure deployments have
not been tested. There is no CI setup.

No license has been selected; the repository is currently unlicensed.
