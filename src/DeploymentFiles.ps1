# Portable deployment batches: write an index, then read only the files it lists.
# Common.ps1 supplies JSON readers, credential checks and the Azure deployment loop.

function Resolve-PhysicalPath([string] $Path) {
    # Resolve links in every existing ancestor, not just the final file.
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $current = [IO.Path]::GetPathRoot($fullPath)
    foreach ($part in $fullPath.Substring($current.Length).Split([IO.Path]::DirectorySeparatorChar)) {
        if (-not $part) { continue }
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.LinkType) {
                $target = $item.ResolveLinkTarget($true)
                if ($null -eq $target -or -not $target.Exists) { throw "Broken link: $current" }
                $current = Resolve-PhysicalPath $target.FullName
            }
        }
    }
    return $current
}

function Resolve-BatchPath([string] $Root, [string] $RelativePath) {
    # Paths are portable across Windows, Linux and macOS. Reject Windows device
    # names too, so a batch generated on macOS can be copied safely to Windows.
    $parts = $RelativePath.Replace('\', '/').Split('/')
    foreach ($part in $parts) {
        if (-not $part -or $part -in @('.', '..') -or $part -match '[<>:"|?*\x00-\x1f]' -or
            $part -match '[. ]$' -or $part -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            throw "Invalid relative batch path: $RelativePath"
        }
    }
    $path = $Root
    $prefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    foreach ($part in $parts) {
        $path = Join-Path $path $part
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path -Force
            if ($item.LinkType) {
                $target = $item.ResolveLinkTarget($true)
                if ($null -eq $target -or -not $target.Exists) { throw "Broken link: $path" }
                $path = Resolve-PhysicalPath $target.FullName
            }
        }
        if (-not $path.StartsWith($prefix, $comparison)) {
            throw "Batch path escapes the folder: $RelativePath"
        }
    }
    return $path
}

function Read-BatchJson([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Batch file not found: $Path" }
    return Read-JsonCell ([IO.File]::ReadAllText($Path)) $Path ([System.Collections.IDictionary]) $null
}

function Write-BatchJson($Document, [string] $Path) {
    $json = ConvertTo-OrderedValue $Document | ConvertTo-Json -Depth 100 -WarningAction Stop
    [IO.File]::WriteAllText($Path, ($json.Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
}

function Read-DeploymentIndex([string] $Root) {
    $index = Read-BatchJson (Resolve-BatchPath $Root 'deployments.json')
    if ($null -eq $index -or -not $index.Contains('formatVersion') -or
        $index.formatVersion -isnot [long] -or $index.formatVersion -ne 1) {
        throw 'deployments.json requires formatVersion 1.'
    }
    if (-not $index.Contains('deployments') -or $index.deployments -isnot [array] -or $index.deployments.Count -eq 0) {
        throw 'deployments.json must contain a nonempty deployments array.'
    }
    $type = ''
    $targets = @{}
    foreach ($entry in $index.deployments) {
        if ($entry -isnot [System.Collections.IDictionary]) { throw 'Each deployment index entry must be an object.' }
        foreach ($field in @('resourceType', 'resourceName', 'subscriptionId', 'resourceGroupName',
                'resourceGroupLocation', 'templateFile', 'parameterFile')) {
            if (-not $entry.Contains($field) -or $entry[$field] -isnot [string] -or
                [string]::IsNullOrWhiteSpace($entry[$field])) {
                throw "Deployment index entry requires a nonempty string: $field"
            }
        }
        if ($entry.resourceType -notin @('Microsoft.Compute/virtualMachines', 'Microsoft.Network/virtualNetworks')) {
            throw "Unsupported batch resource type: $($entry.resourceType)"
        }
        if ($type -and $type -ne $entry.resourceType) { throw 'Use separate folders for VM and VNet batches.' }
        $type = $entry.resourceType
        $subscription = [guid]::Empty
        if (-not [guid]::TryParseExact($entry.subscriptionId, 'D', [ref]$subscription)) {
            throw 'Deployment subscriptionId must be a GUID.'
        }
        $group = $entry.resourceGroupName
        if ($group.Length -gt 90 -or $group -notmatch '^[\p{L}\p{N}_().-]+$' -or $group.EndsWith('.')) {
            throw 'Invalid deployment resourceGroupName.'
        }
        $name = $entry.resourceName
        if ($name -notmatch '^[a-zA-Z0-9](?:[a-zA-Z0-9_.-]{0,62}[a-zA-Z0-9_])?$' -or
            ($type -eq 'Microsoft.Network/virtualNetworks' -and $name.Length -lt 2)) {
            throw 'Invalid deployment resourceName.'
        }
        $target = "$($subscription.ToString('D'))/$group/$type/$name"
        if ($targets.ContainsKey($target)) { throw "Duplicate deployment target: $target" }
        $targets[$target] = $true
    }
    return $index
}

function Write-DeploymentBatch {
    param([object[]] $Plans, [string] $OutputDirectory, [string] $NameProperty, [string] $TemplateFile)
    $root = Resolve-PhysicalPath $OutputDirectory
    $isVm = $NameProperty -eq 'VmName'
    $resourceType = if ($isVm) { 'Microsoft.Compute/virtualMachines' } else { 'Microsoft.Network/virtualNetworks' }
    $folder = if ($isVm) { 'virtual-machines' } else { 'virtual-networks' }
    $templateRelative = if ($isVm) { 'templates/vm.json' } else { 'templates/vnet.json' }
    $indexPath = Resolve-BatchPath $root 'deployments.json'
    if (Test-Path -LiteralPath $indexPath) {
        $previous = Read-DeploymentIndex $root
        if ($previous.deployments[0].resourceType -ne $resourceType) {
            throw 'Use separate folders for VM and VNet batches.'
        }
    }

    # Resolve every destination before writing: catch collisions and escaping links
    # without partially rewriting a previous batch on an ordinary input error.
    $templatePath = Resolve-BatchPath $root $templateRelative
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $null = $paths.Add($indexPath.Normalize())
    if (-not $paths.Add($templatePath.Normalize())) { throw 'Batch template and index paths collide.' }
    $entries = @(
        foreach ($plan in $Plans) {
            $name = $plan.$NameProperty
            $relative = "parameters/$($plan.SubscriptionId)/$($plan.ResourceGroupName)/$folder/$name.parameters.json"
            $path = Resolve-BatchPath $root $relative
            if (-not $paths.Add($path.Normalize())) { throw "Batch file paths collide: $relative" }
            $plan | Add-Member -NotePropertyName ParameterFile -NotePropertyValue $path
            $plan | Add-Member -NotePropertyName TemplateFile -NotePropertyValue $templatePath
            [ordered]@{
                resourceType = $resourceType
                resourceName = $name
                subscriptionId = $plan.SubscriptionId
                resourceGroupName = $plan.ResourceGroupName
                resourceGroupLocation = $plan.ResourceGroupLocation
                templateFile = $templateRelative
                parameterFile = $relative
            }
        }
    )
    $templateText = [IO.File]::ReadAllText($TemplateFile)
    $null = [IO.Directory]::CreateDirectory((Split-Path $templatePath -Parent))
    [IO.File]::WriteAllText($templatePath, $templateText, [Text.UTF8Encoding]::new($false))
    foreach ($plan in $Plans) {
        $null = [IO.Directory]::CreateDirectory((Split-Path $plan.ParameterFile -Parent))
        Write-BatchJson ([ordered]@{
            '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
            contentVersion = '1.0.0.0'
            parameters = $plan.Parameters
        }) $plan.ParameterFile
    }
    # The current CSV is the complete batch. Old, unlisted files are left alone.
    Write-BatchJson ([ordered]@{ formatVersion = 1; deployments = $entries }) $indexPath
}

function Read-DeploymentBatch {
    param([string] $Path, [switch] $CreateResourceGroups)
    $root = Resolve-PhysicalPath $Path
    $index = Read-DeploymentIndex $root
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $groupLocations = @{}
    $position = 0
    foreach ($entry in $index.deployments) {
        $position++
        $parameterPath = Resolve-BatchPath $root $entry.parameterFile
        $templatePath = Resolve-BatchPath $root $entry.templateFile
        if (-not $paths.Add($parameterPath.Normalize())) { throw 'Duplicate parameter file in deployment index.' }
        $fileName = ($entry.parameterFile.Replace('\', '/').Split('/'))[-1]
        if ($fileName -cne "$($entry.resourceName).parameters.json") {
            throw 'Parameter filename must match the indexed resourceName.'
        }
        $parameters = Read-BatchJson $parameterPath
        $template = Read-BatchJson $templatePath
        foreach ($document in @($parameters, $template)) {
            if ($null -eq $document -or -not $document.Contains('$schema') -or
                -not $document.Contains('contentVersion') -or $document.contentVersion -isnot [string] -or
                $document.contentVersion -notmatch '^\d+\.\d+\.\d+\.\d+$' -or
                -not $document.Contains('parameters') -or $document.parameters -isnot [Collections.IDictionary]) {
                throw 'ARM files require $schema, contentVersion and a parameters object.'
            }
        }
        if ($parameters['$schema'] -ne 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#' -or
            $template['$schema'] -ne 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#' -or
            -not $template.Contains('resources') -or $template.resources -isnot [array]) {
            throw 'Expected resource-group ARM template and deployment parameter documents.'
        }
        foreach ($key in $template.parameters.psbase.Keys) {
            $definition = $template.parameters[$key]
            if ($definition -isnot [Collections.IDictionary] -or -not $definition.Contains('type')) {
                throw "Invalid template parameter definition: $key"
            }
            if ($definition.type -notin @('string', 'securestring', 'int', 'bool', 'array', 'object', 'secureobject')) {
                throw "Unsupported ARM parameter type: $key"
            }
            if (-not $definition.Contains('defaultValue') -and -not $parameters.parameters.Contains($key)) {
                throw "Missing required ARM parameter: $key"
            }
        }
        foreach ($key in $parameters.parameters.psbase.Keys) {
            $value = $parameters.parameters[$key]
            if (-not $template.parameters.Contains($key) -or $value -isnot [Collections.IDictionary] -or
                ($value.Contains('value') -eq $value.Contains('reference'))) {
                throw "ARM parameter must be declared by the template and contain value or reference: $key"
            }
            if ($value.Contains('reference')) {
                $reference = $value.reference
                if ($reference -isnot [Collections.IDictionary] -or -not $reference.Contains('keyVault') -or
                    $reference.keyVault -isnot [Collections.IDictionary] -or -not $reference.keyVault.Contains('id') -or
                    -not $reference.Contains('secretName') -or $reference.secretName -isnot [string] -or
                    [string]::IsNullOrWhiteSpace($reference.secretName)) {
                    throw "Invalid Key Vault parameter reference: $key"
                }
                Assert-ResourceId $reference.keyVault.id 'Microsoft.KeyVault/vaults/[^/]+' $key
            }
            else {
                $validType = switch ($template.parameters[$key].type) {
                    { $_ -in @('string', 'securestring') } { $value.value -is [string] }
                    { $_ -in @('object', 'secureobject') } { $value.value -is [Collections.IDictionary] }
                    'array' { $value.value -is [array] }
                    'int' { $value.value -is [long] -or $value.value -is [int] }
                    'bool' { $value.value -is [bool] }
                }
                if (-not $validType) { throw "ARM parameter value has the wrong type: $key" }
            }
        }
        $nameParameter = if ($entry.resourceType -eq 'Microsoft.Compute/virtualMachines') { 'vmName' } else { 'vnetName' }
        if (-not $parameters.parameters.Contains($nameParameter) -or
            -not $parameters.parameters[$nameParameter].Contains('value') -or
            $parameters.parameters[$nameParameter].value -cne $entry.resourceName) {
            throw "Indexed resourceName does not match ARM parameter $nameParameter."
        }
        if ([IO.File]::ReadAllText($parameterPath).Contains('REPLACE_WITH_YOUR_SSH_PUBLIC_KEY') -or
            [IO.File]::ReadAllText($templatePath).Contains('REPLACE_WITH_YOUR_SSH_PUBLIC_KEY')) {
            throw 'Replace the example SSH placeholder before verifying or deploying a batch.'
        }
        $groupKey = "$($entry.subscriptionId)/$($entry.resourceGroupName)"
        if ($CreateResourceGroups -and $groupLocations.ContainsKey($groupKey) -and
            $groupLocations[$groupKey] -ne $entry.resourceGroupLocation) {
            throw 'Conflicting resource group locations within a subscription.'
        }
        $groupLocations[$groupKey] = $entry.resourceGroupLocation
        [pscustomobject]@{
            Row = $position
            SubscriptionId = $entry.subscriptionId
            ResourceGroupName = $entry.resourceGroupName
            ResourceGroupLocation = $entry.resourceGroupLocation
            ResourceName = $entry.resourceName
            ResourceType = $entry.resourceType
            TemplateFile = $templatePath
            ParameterFile = $parameterPath
        }
    }
}
