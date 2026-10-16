# Shared CSV readers, validation and Azure loop for all three deployment scripts.
# Cell readers apply defaults and catch editing mistakes; the Azure loop is at the end.
Set-StrictMode -Version Latest

function Read-BoolCell([string] $Value, [string] $Column, [bool] $Default) {
    if (-not $Value) {
        return $Default
    }
    $parsed = $false
    if (-not [bool]::TryParse($Value, [ref]$parsed)) {
        throw "${Column}: use true or false."
    }
    return $parsed
}

function Read-IntCell([string] $Value, [string] $Column, [int] $Min, [int] $Max) {
    $parsed = 0
    if (-not [int]::TryParse($Value, [ref]$parsed) -or $parsed -lt $Min -or $parsed -gt $Max) {
        throw "${Column}: expected an integer from $Min to $Max."
    }
    return $parsed
}

function Read-Choice([string] $Value, [string] $Column, [string[]] $Choices, [string] $Default) {
    if (-not $Value) {
        return $Default
    }
    foreach ($choice in $Choices) {
        if ($Value -ieq $choice) {
            return $choice
        }
    }
    throw "${Column}: choose $($Choices -join ', ')."
}

function Assert-NoKey($Object, [string[]] $Keys, [string] $Column) {
    foreach ($key in $Keys) {
        if ($Object.Contains($key)) {
            throw "${Column}: '$key' is managed by dedicated CSV columns."
        }
    }
}

function Assert-ResourceId([string] $Id, [string] $Type, [string] $Column) {
    $guidPattern = '[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'
    $pattern = '^/subscriptions/' + $guidPattern + '/resourceGroups/[^/]+/providers/' + $Type.Replace('.', '\.') + '$'
    if ($Id -notmatch $pattern) {
        throw "${Column}: expected a full $Type resource ID."
    }
}

function Merge-JsonObject($Base, $Extra) {
    # Merge nested objects while keeping the explicit array from the extra object.
    $merged = @{}
    foreach ($key in $Base.psbase.Keys) {
        $merged[$key] = $Base[$key]
    }
    foreach ($key in $Extra.psbase.Keys) {
        if ($merged.ContainsKey($key) -and
            $merged[$key] -is [System.Collections.IDictionary] -and
            $Extra[$key] -is [System.Collections.IDictionary]) {
            $merged[$key] = Merge-JsonObject $merged[$key] $Extra[$key]
        }
        else {
            $merged[$key] = $Extra[$key]
        }
    }
    return , $merged
}

function ConvertTo-OrderedValue($Value) {
    # Stable files are easier to review, and case-insensitive lookup prevents JSON
    # casing from bypassing reserved-property checks. Arrays retain their order.
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::OrdinalIgnoreCase)
        $keys = [string[]]@($Value.psbase.Keys)
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        foreach ($key in $keys) {
            $result.Add($key, (ConvertTo-OrderedValue $Value[$key]))
        }
        return , $result
    }
    if ($Value -is [array]) {
        $result = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            $result.Add((ConvertTo-OrderedValue $item))
        }
        return , $result.ToArray()
    }
    return , $Value
}

function Assert-UniqueJsonKey([System.Text.Json.JsonElement] $Element) {
    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $seen.Add($property.Name)) {
                throw 'Duplicate JSON property names are not allowed (including casing differences).'
            }
            Assert-UniqueJsonKey $property.Value
        }
    }
    elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        foreach ($item in $Element.EnumerateArray()) {
            Assert-UniqueJsonKey $item
        }
    }
}

function Read-JsonCell {
    param([string] $Value, [string] $Column, [type] $Type, $Default)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return , $Default
    }
    $document = $null
    try {
        $document = [System.Text.Json.JsonDocument]::Parse($Value)
        Assert-UniqueJsonKey $document.RootElement
        $parsed = ConvertFrom-Json -InputObject $Value -AsHashtable -NoEnumerate -Depth 64
    }
    catch {
        throw "${Column}: invalid JSON, duplicate properties, or nesting deeper than 64 levels."
    }
    finally {
        if ($null -ne $document) {
            $document.Dispose()
        }
    }
    if ($null -eq $parsed -or $parsed -isnot $Type) {
        throw "${Column}: expected a JSON $($Type.Name)."
    }
    return , (ConvertTo-OrderedValue $parsed)
}

function Read-ListCell([string] $Value) {
    return , @($Value.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries) |
            ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Check row lengths as well as headers: Import-Csv can silently discard extra cells.
function Import-DeploymentCsv {
    param([string] $Path, [string[]] $RequiredColumns, [string[]] $OptionalColumns)
    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $parser = [Microsoft.VisualBasic.FileIO.TextFieldParser]::new($resolvedPath)
    try {
        $parser.SetDelimiters(',')
        $parser.HasFieldsEnclosedInQuotes = $true
        $parser.TrimWhiteSpace = $false
        if ($parser.EndOfData) {
            throw 'CSV must contain a header and at least one data row.'
        }
        $headers = $parser.ReadFields()
        $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($column in $headers) {
            if ([string]::IsNullOrWhiteSpace($column)) {
                throw 'CSV column names must not be blank.'
            }
            if (-not $seen.Add($column)) {
                throw "Duplicate CSV column: $column"
            }
            if ($column -notin ($RequiredColumns + $OptionalColumns)) {
                throw "Unknown CSV column: $column"
            }
        }
        foreach ($column in $RequiredColumns) {
            if ($column -notin $headers) {
                throw "Missing required CSV column: $column"
            }
        }
        $rowNumber = 1
        while (-not $parser.EndOfData) {
            $rowNumber++
            try {
                $fields = $parser.ReadFields()
            }
            catch {
                throw "CSV row ${rowNumber}: malformed quoting."
            }
            if ($fields.Count -ne $headers.Count) {
                throw "CSV row ${rowNumber}: expected $($headers.Count) fields, found $($fields.Count). Check commas and JSON quoting."
            }
            $row = [ordered]@{}
            for ($index = 0; $index -lt $headers.Count; $index++) {
                $row[$headers[$index]] = $fields[$index]
            }
            [pscustomobject]$row
        }
        if ($rowNumber -eq 1) {
            throw 'CSV must contain at least one data row.'
        }
    }
    finally {
        $parser.Dispose()
    }
}

function Assert-ResourceName([string] $Name, [string] $Column) {
    if ($Name -notmatch '^[a-zA-Z0-9_](?:[a-zA-Z0-9_.-]{0,78}[a-zA-Z0-9_])?$') {
        throw "${Column}: use 1-80 letters, digits, underscores, periods or hyphens; start and end with a letter, digit or underscore."
    }
}

function Assert-IpAddress([string] $Value, [string] $Column, [switch] $IPv4Only) {
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Value, [ref]$ip)) {
        throw "${Column}: invalid IP address."
    }
    if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        if ($ip.ToString() -cne $Value) {
            throw "${Column}: use a canonical dotted-decimal IPv4 address."
        }
    }
    elseif ($IPv4Only -or $Value.Contains('%')) {
        throw "${Column}: unsupported IP address family or scope."
    }
}

# Validate the public-key payload so a mistyped key fails before an Azure deployment.
function Assert-SshPublicKey([string] $Value, [string] $Action) {
    if ($Value -eq 'REPLACE_WITH_YOUR_SSH_PUBLIC_KEY' -and $Action -eq 'Generate') {
        return
    }
    try {
        $parts = $Value.Split([char[]]" `t", [StringSplitOptions]::RemoveEmptyEntries)
        if ($parts.Count -lt 2 -or $parts[0] -notin @('ssh-rsa', 'ssh-ed25519')) {
            throw 'Unsupported SSH key format.'
        }
        $bytes = [Convert]::FromBase64String($parts[1])
        $offset = 0
        $fields = [System.Collections.Generic.List[byte[]]]::new()
        while ($offset -lt $bytes.Length) {
            if ($bytes.Length - $offset -lt 4) {
                throw 'Truncated SSH key.'
            }
            $length = [uint32]$bytes[$offset] * 16777216L + [uint32]$bytes[$offset + 1] * 65536L +
                [uint32]$bytes[$offset + 2] * 256L + $bytes[$offset + 3]
            $offset += 4
            if ($length -eq 0 -or $length -gt $bytes.Length - $offset) {
                throw 'Invalid SSH key field.'
            }
            $fields.Add([byte[]]$bytes[$offset..($offset + $length - 1)])
            $offset += $length
        }
        if ($fields.Count -lt 2 -or [Text.Encoding]::ASCII.GetString($fields[0]) -cne $parts[0]) {
            throw 'SSH key type mismatch.'
        }
        if ($parts[0] -eq 'ssh-ed25519') {
            if ($fields.Count -ne 2 -or $fields[1].Length -ne 32) {
                throw 'Invalid Ed25519 key.'
            }
        }
        else {
            if ($fields.Count -ne 3) {
                throw 'Invalid RSA key.'
            }
            $modulus = [System.Numerics.BigInteger]::new($fields[2], $true, $true)
            # 2^2047 is the smallest modulus with a 2048-bit representation.
            if ($modulus -lt [System.Numerics.BigInteger]::Pow(2, 2047)) {
                throw 'RSA key must be at least 2048 bits.'
            }
        }
    }
    catch {
        throw 'SshPublicKey must contain a valid RSA (2048+ bit) or Ed25519 public key. Replace the example placeholder with your own .pub file contents.'
    }
}

. (Join-Path $PSScriptRoot 'DeploymentFiles.ps1')

# Work through the rows in order, selecting the subscription explicitly each time.
function Invoke-DeploymentPlan {
    param(
        [object[]] $Plans,
        [string] $Action,
        [string] $NameProperty,
        [string] $ResourceLabel,
        [switch] $CreateResourceGroups,
        [switch] $ContinueOnError
    )
    $requiredCommands = @(
        'Get-AzContext', 'Set-AzContext', 'Get-AzResourceGroup', 'New-AzResourceGroup', 'Invoke-AzRestMethod',
        'Test-AzResourceGroupDeployment', 'New-AzResourceGroupDeployment'
    )
    foreach ($command in $requiredCommands) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Missing $command. Install Az.Accounts and Az.Resources; see README.md."
        }
    }
    if ($null -eq (Get-AzContext)) {
        throw 'Sign in first using Connect-AzAccount.'
    }
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($plan in $Plans) {
        $status = 'Succeeded'
        $errorMessage = ''
        try {
            Write-Information "$Action $($plan.SubscriptionId)/$($plan.ResourceGroupName)/$($plan.$NameProperty)" -InformationAction Continue
            # Process scope avoids changing the saved subscription for future sessions.
            $context = Set-AzContext -SubscriptionId $plan.SubscriptionId -Scope Process -ErrorAction Stop
            if ($null -eq $context -or $context.Subscription.Id -ne $plan.SubscriptionId) {
                throw "Azure context does not match subscription '$($plan.SubscriptionId)'."
            }
            try {
                $group = Get-AzResourceGroup -Name $plan.ResourceGroupName -DefaultProfile $context -ErrorAction Stop
                if ($null -eq $group) { throw 'Resource group lookup returned no result.' }
            }
            catch {
                # Az.Resources can hide the original HTTP error behind a generic
                # not-found message. Confirm absence with a scoped ARM GET.
                $groupName = [uri]::EscapeDataString($plan.ResourceGroupName)
                $path = "/subscriptions/$($plan.SubscriptionId)/resourcegroups/${groupName}?api-version=2021-04-01"
                $response = Invoke-AzRestMethod -Path $path -Method GET -DefaultProfile $context -ErrorAction Stop
                $lookupFailure = "Resource group lookup for '$($plan.ResourceGroupName)' failed (HTTP $($response.StatusCode)): $($response.Content)"
                if ($response.StatusCode -ne 404) { throw $lookupFailure }
                try {
                    $details = $response.Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                }
                catch { throw $lookupFailure }
                if ($details -isnot [System.Collections.IDictionary] -or -not $details.Contains('error') -or
                    $details.error -isnot [System.Collections.IDictionary] -or $details.error['code'] -ne 'ResourceGroupNotFound') {
                    throw $lookupFailure
                }
                $group = $null
            }
            # Validation and WhatIf require an existing resource group.
            if ($null -eq $group) {
                if ($Action -ne 'Deploy' -or -not $CreateResourceGroups) {
                    throw "Resource group '$($plan.ResourceGroupName)' does not exist. Create it first, or use Deploy -CreateResourceGroups."
                }
                $null = New-AzResourceGroup -Name $plan.ResourceGroupName -Location $plan.ResourceGroupLocation -DefaultProfile $context -ErrorAction Stop
            }
            $deployment = @{
                ResourceGroupName     = $plan.ResourceGroupName
                TemplateFile          = $plan.TemplateFile
                TemplateParameterFile = $plan.ParameterFile
                Mode                  = 'Incremental'
                DefaultProfile        = $context
                ErrorAction           = 'Stop'
            }
            if ($Action -eq 'Validate') {
                $issues = @(Test-AzResourceGroupDeployment @deployment)
                if ($issues.Count) {
                    throw ($issues | ConvertTo-Json -Depth 20 -Compress)
                }
            }
            else {
                $deployment.Name = '{0}-{1}-{2}' -f $ResourceLabel.ToLowerInvariant(), $plan.Row, ([guid]::NewGuid().ToString('N').Substring(0, 12))
                if ($Action -eq 'WhatIf') {
                    New-AzResourceGroupDeployment @deployment -WhatIf
                }
                else {
                    $result = New-AzResourceGroupDeployment @deployment
                    if ($result.ProvisioningState -ne 'Succeeded') {
                        throw "Deployment returned $($result.ProvisioningState)."
                    }
                }
            }
        }
        catch {
            $status = 'Failed'
            $errorMessage = $_.Exception.Message
            Write-Warning "Row $($plan.Row), subscription $($plan.SubscriptionId): $errorMessage"
        }
        $results.Add([pscustomobject][ordered]@{
                SubscriptionId    = $plan.SubscriptionId
                ResourceGroupName = $plan.ResourceGroupName
                $NameProperty     = $plan.$NameProperty
                Action            = $Action
                Status            = $status
                Error             = $errorMessage
            })
        # Keep successful results, even if a later deployment fails.
        if ($status -eq 'Failed' -and -not $ContinueOnError) {
            break
        }
    }
    $results
    if (@($results | Where-Object Status -EQ 'Failed').Count) {
        throw "One or more $ResourceLabel operations failed. See results above; completed deployments are not rolled back."
    }
}
