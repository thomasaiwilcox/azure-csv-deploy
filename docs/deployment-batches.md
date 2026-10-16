# Deployment batches

[Back to the quick start](../README.md)

A batch lets you prepare and review a deployment separately from running it.
Generate one batch per VNet or VM CSV. Use separate folders for networks and VMs;
run the network batch first when VMs depend on its subnets.

## Generate and move a batch

```powershell
./Deploy-Vms.ps1 -CsvPath ./local/vms.csv -Action Generate -OutputDirectory ./generated/vm-batch
```

The output contains everything needed to describe the deployment:

```text
vm-batch/
  deployments.json
  templates/
    vm.json
  parameters/
    <subscription-id>/
      <resource-group>/
        virtual-machines/
          vm-linux-dev.parameters.json
```

VNet batches use `templates/vnet.json` and `virtual-networks/` instead. The default
output folders are `generated/vnets/` and `generated/vms/`. Every CSV action writes
a batch; `Generate` stops before contacting Azure.

Filenames use the resource name, without a CSV row number. Subscription and
resource group folders allow the same resource name in different scopes. Reordering
CSV rows changes deployment order but not filenames. Names must also be valid
portable filenames; for example, Windows device names such as `CON` are rejected.

The template is copied from the source selected by `-TemplateFile`. Move or copy
the whole batch folder, then use `Deploy-FromFiles.ps1` from this repository with
its `src/` folder. The original CSV and original template are no longer needed.

## Edit and verify

Edit generated parameter values or the bundled template directly. Files remain
standard ARM JSON, so they can also be used with Azure's normal deployment tools.
The runner does not rebuild them or compare them against generation-time hashes.

```powershell
./Deploy-FromFiles.ps1 -Path ./generated/vm-batch -Action Verify
```

`Verify` checks the complete batch locally without Azure modules or a login. It
checks JSON structure, required fields and parameters, basic parameter types,
duplicate targets, matching names and file references. Relative references must
stay within the batch folder, including symbolic links. Example SSH placeholders
must be replaced before any folder-runner action, including `Verify`.

This is a consistency check, not a full ARM expression evaluator or a check of
Azure availability, quota or permissions. Keep password credentials as Key Vault
references, just as in the CSV examples.

To rename a resource, update its parameter filename, its name parameter (`vmName`
or `vnetName`), and its index entry. If changing subscription or resource group,
review embedded resource IDs too; the runner does not rewrite those IDs for you.

Regenerating from CSV replaces the index with the current rows and overwrites the
corresponding parameters and template. This overwrites manual edits. Files no
longer listed in the index are left on disk but are not deployed. Unrelated JSON
files are ignored. Use a new output folder if you need to keep a reviewed batch.

## Validate, preview and deploy

Sign in with access to every indexed subscription:

```powershell
Connect-AzAccount
./Deploy-FromFiles.ps1 -Path ./generated/vm-batch -Action Validate
./Deploy-FromFiles.ps1 -Path ./generated/vm-batch -Action WhatIf
./Deploy-FromFiles.ps1 -Path ./generated/vm-batch -Action Deploy -CreateResourceGroups
```

`Deploy` is the default action. `Validate` and `WhatIf` require existing resource
groups and never create them. `-CreateResourceGroups` applies only to deployment.
Each action first verifies every entry locally, then performs Azure operations
sequentially in index order, explicitly selecting each subscription.

`-ContinueOnError` attempts remaining entries after an Azure failure, then reports
an overall error. Without it, the first Azure failure stops the loop. Local
verification failures always stop the whole batch before Azure is contacted.
Completed deployments are not rolled back.

## Index format

The index uses format version `1`. The `deployments` array determines order:

```json
{
  "formatVersion": 1,
  "deployments": [
    {
      "resourceType": "Microsoft.Compute/virtualMachines",
      "resourceName": "vm-linux-dev",
      "subscriptionId": "11111111-1111-1111-1111-111111111111",
      "resourceGroupName": "rg-vms-dev",
      "resourceGroupLocation": "uksouth",
      "templateFile": "templates/vm.json",
      "parameterFile": "parameters/11111111-1111-1111-1111-111111111111/rg-vms-dev/virtual-machines/vm-linux-dev.parameters.json"
    }
  ]
}
```

The other supported resource type is `Microsoft.Network/virtualNetworks`.
`resourceGroupLocation` is used only when creating a missing group. Resource
location remains in the ARM parameters. Paths are relative to the batch folder;
there are no absolute machine-specific paths in the generated index.

Old row-prefixed parameter files remain usable with normal ARM tools. Regenerate
from CSV to obtain the new layout and index required by the folder runner.
