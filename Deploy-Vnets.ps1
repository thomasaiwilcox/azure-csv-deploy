#Requires -Version 7.2
<#
.SYNOPSIS
Generate ARM parameter files or sequentially validate, preview, or deploy VNets from CSV.
.EXAMPLE
./Deploy-Vnets.ps1 -CsvPath ./examples/vnets.csv -Action Generate
.EXAMPLE
./Deploy-Vnets.ps1 -CsvPath ./examples/vnets.csv -CreateResourceGroups
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $CsvPath,
    [ValidateSet('Generate', 'Validate', 'WhatIf', 'Deploy')][string] $Action = 'Deploy',
    [string] $TemplateFile = (Join-Path $PSScriptRoot 'templates/vnet.json'),
    [string] $OutputDirectory = (Join-Path $PSScriptRoot 'generated'),
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
$requiredColumns = @('SubscriptionId', 'ResourceGroupName', 'Location', 'VnetName', 'AddressPrefixes')
$optionalColumns = @('ResourceGroupLocation', 'DnsServers', 'SubnetsJson', 'TagsJson', 'AdditionalPropertiesJson')
$rows = @(Import-DeploymentCsv -Path $CsvPath -RequiredColumns $requiredColumns -OptionalColumns $optionalColumns)

# Validate every row before generating files or making any Azure calls.
$seen = @{}
$groupLocations = @{}
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
                if ([string]::IsNullOrWhiteSpace($row[$column])) {
                    throw "${column} is required."
                }
            }
            $subscriptionGuid = [guid]::Empty
            if (-not [guid]::TryParseExact($row.SubscriptionId, 'D', [ref]$subscriptionGuid)) {
                throw 'SubscriptionId must be a subscription GUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx).'
            }
            $row.SubscriptionId = $subscriptionGuid.ToString('D')
            if ($row.VnetName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}[a-zA-Z0-9_]$') {
                throw 'VnetName must be 2-64 characters, start with an alphanumeric, and end with an alphanumeric or underscore.'
            }
            if ($row.ResourceGroupName.Length -gt 90 -or
                $row.ResourceGroupName -notmatch '^[\p{L}\p{N}_().-]+$' -or
                $row.ResourceGroupName.EndsWith('.')) {
                throw 'Invalid ResourceGroupName.'
            }
            $groupKey = "$($row.SubscriptionId)/$($row.ResourceGroupName)"
            $key = "$groupKey/$($row.VnetName)"
            if ($seen.ContainsKey($key)) {
                throw "Duplicate VNet target: $key"
            }
            $seen[$key] = $true

            # Read semicolon-separated address spaces and DNS server lists.
            $prefixes = Read-ListCell $row.AddressPrefixes
            foreach ($prefix in $prefixes) {
                $parts = $prefix.Split('/')
                $ip = $null
                $length = 0
                if ($parts.Count -ne 2 -or -not [System.Net.IPAddress]::TryParse($parts[0], [ref]$ip) -or
                        -not [int]::TryParse($parts[1], [ref]$length)) {
                    throw "Invalid CIDR prefix: $prefix"
                }
                Assert-IpAddress $parts[0] 'AddressPrefixes'
                $maxLength = if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { 32 } else { 128 }
                if ($length -lt 0 -or $length -gt $maxLength) {
                    throw "Invalid CIDR prefix: $prefix"
                }
            }
            if ($prefixes.Count -eq 0) {
                throw 'At least one address prefix is required.'
            }
            $dns = Read-ListCell $row.DnsServers
            foreach ($server in $dns) {
                Assert-IpAddress $server 'DnsServers'
            }

            # Nested subnet settings are supplied as a JSON array in the CSV.
            $subnets = Read-JsonCell $row.SubnetsJson 'SubnetsJson' ([array]) @()
            $subnetNames = @{}
            foreach ($subnet in $subnets) {
                if ($subnet -isnot [System.Collections.IDictionary] -or
                        -not $subnet.Contains('name') -or $subnet.name -isnot [string] -or
                        [string]::IsNullOrWhiteSpace($subnet.name) -or -not $subnet.Contains('properties') -or
                        $subnet.properties -isnot [System.Collections.IDictionary]) {
                    throw 'Each subnet needs a name and a properties object.'
                }
                if ($subnetNames.ContainsKey($subnet.name)) {
                    throw "Duplicate subnet: $($subnet.name)"
                }
                $subnetNames[$subnet.name] = $true
            }
            $tags = Read-JsonCell $row.TagsJson 'TagsJson' ([System.Collections.IDictionary]) @{}
            foreach ($value in $tags.psbase.Values) {
                if ($value -isnot [string]) {
                    throw 'Tag values must be strings.'
                }
            }
            $additional = Read-JsonCell $row.AdditionalPropertiesJson 'AdditionalPropertiesJson' ([System.Collections.IDictionary]) @{}
            foreach ($reserved in @('addressSpace', 'dhcpOptions', 'subnets')) {
                if ($additional.Contains($reserved)) {
                    throw "Use dedicated CSV columns instead of AdditionalPropertiesJson.$reserved"
                }
            }
            $groupLocation = if ($row.ResourceGroupLocation) { $row.ResourceGroupLocation } else { $row.Location }
            if ($CreateResourceGroups -and $groupLocations.ContainsKey($groupKey) -and
                    $groupLocations[$groupKey] -ne $groupLocation) {
                throw 'Conflicting resource group locations; set ResourceGroupLocation consistently within each subscription.'
            }
            $groupLocations[$groupKey] = $groupLocation

            # Map the completed settings to the ARM template parameters.
            $parameters = [ordered]@{
                vnetName             = @{ value = $row.VnetName }
                location             = @{ value = $row.Location }
                addressPrefixes      = @{ value = $prefixes }
                dnsServers           = @{ value = $dns }
                subnets              = @{ value = $subnets }
                tags                 = @{ value = $tags }
                additionalProperties = @{ value = $additional }
            }
            [pscustomobject]@{
                Row = $index + 2
                SubscriptionId = $row.SubscriptionId
                ResourceGroupName = $row.ResourceGroupName
                ResourceGroupLocation = $groupLocation
                VnetName = $row.VnetName
                Parameters = $parameters
            }
        }
        catch {
            throw "CSV row $($index + 2): $($_.Exception.Message)"
        }
    }
)

# Write one ARM parameter file per row. Generate stops here; other actions use Azure.
Write-DeploymentParameterFile -Plans $plans -OutputDirectory $OutputDirectory -NameProperty VnetName
if ($Action -eq 'Generate') {
    $plans | Select-Object SubscriptionId, ResourceGroupName, VnetName, ParameterFile
    return
}
Invoke-DeploymentPlan -Plans $plans -TemplateFile $TemplateFile -Action $Action `
    -NameProperty VnetName -ResourceLabel VNet `
    -CreateResourceGroups:$CreateResourceGroups -ContinueOnError:$ContinueOnError
