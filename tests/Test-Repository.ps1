#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
function Assert([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
$temp = Join-Path ([IO.Path]::GetTempPath()) ('csv-repository-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory $temp
try {
    $sourceFiles = @(
        Get-ChildItem $root -File
        foreach ($directory in @('src', 'templates', 'examples', 'tests', 'docs')) {
            Get-ChildItem (Join-Path $root $directory) -File -Recurse
        }
    )
    foreach ($file in $sourceFiles) {
        if ($file.Extension -eq '.ps1') {
            $tokens = $null; $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            Assert ($errors.Count -eq 0) "PowerShell parse error in $($file.Name): $errors"
        }
        if ($file.Extension -eq '.json') { $null = Get-Content $file.FullName -Raw | ConvertFrom-Json -Depth 100 }
        if ($file.Extension -eq '.md') {
            $text = Get-Content $file.FullName -Raw
            foreach ($match in [regex]::Matches($text, '\[[^\]]+\]\(([^)]+)\)')) {
                $target = $match.Groups[1].Value
                if ($target -match '^(https?://|mailto:|#)') { continue }
                $local = Join-Path $file.DirectoryName ($target.Split('#')[0])
                Assert (Test-Path -LiteralPath $local) "Broken link in $($file.Name): $target"
            }
        }
    }
    # Generate from another working directory to verify script-relative defaults.
    Push-Location $temp
    try {
        $plans = @(
            & (Join-Path $root 'Deploy-Vnets.ps1') -CsvPath (Join-Path $root 'examples/vnets.csv') -Action Generate -OutputDirectory (Join-Path $temp 'vnets')
            & (Join-Path $root 'Deploy-Vms.ps1') -CsvPath (Join-Path $root 'examples/vms.csv') -Action Generate -OutputDirectory (Join-Path $temp 'vms')
        )
        foreach ($plan in $plans) {
            $actual = [IO.File]::ReadAllText($plan.ParameterFile)
            $parameters = ($actual | ConvertFrom-Json -AsHashtable).parameters
            $name = if ($parameters.Contains('vmName')) { $parameters.vmName.value } else { $parameters.vnetName.value }
            $expected = [IO.File]::ReadAllText((Join-Path $root "examples/parameters/$name.parameters.json"))
            Assert ($actual -ceq $expected) "Parameter example drift: $name. Regenerate the matching file in examples/parameters/."
        }
        foreach ($kind in @('Vms', 'Vnets')) {
            $null = & (Join-Path $root "Deploy-$kind.ps1") -CsvPath (Join-Path $root "examples/$($kind.ToLowerInvariant())-minimal.csv") -Action Generate -OutputDirectory (Join-Path $temp $kind)
        }
    }
    finally { Pop-Location }
    $vnets = @(Import-Csv (Join-Path $root 'examples/vnets.csv'))
    foreach ($vm in (Import-Csv (Join-Path $root 'examples/vms.csv'))) {
        $network = @($vnets | Where-Object {
                $vm.SubnetId -like "/subscriptions/$($_.SubscriptionId)/resourceGroups/$($_.ResourceGroupName)/providers/Microsoft.Network/virtualNetworks/$($_.VnetName)/subnets/*"
            })
        Assert ($network.Count -eq 1 -and $network[0].Location -eq $vm.Location) 'VM and referenced VNet examples must be in the same region.'
    }
    Write-Host 'All repository syntax, link, example and reproducibility checks passed.'
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force }
