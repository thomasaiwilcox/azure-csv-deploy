#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/Common.ps1')
function Assert([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock] $Body, [string] $Pattern) {
    $caught = $null
    try { & $Body | Out-Null } catch { $caught = $_.Exception.Message }
    Assert ($null -ne $caught -and $caught -like $Pattern) "Expected error '$Pattern'; received '$caught'."
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('csv-common-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory $temp
try {
    $path = Join-Path $temp 'input.csv'
    foreach ($case in @(
            @{ Csv = "Name,Value`nfirst,second,extra"; Error = '*expected 2 fields, found 3*' },
            @{ Csv = "Name,Value`nfirst"; Error = '*expected 2 fields, found 1*' },
            @{ Csv = "Name,name`nfirst,second"; Error = '*Duplicate CSV column*' },
            @{ Csv = "Name,`nfirst,second"; Error = '*must not be blank*' },
            @{ Csv = "Name,Value`n`"unterminated"; Error = '*malformed quoting*' },
            @{ Csv = 'Name,Value'; Error = '*at least one data row*' }
        )) {
        Set-Content -LiteralPath $path -Value $case.Csv
        Assert-Throws { Import-DeploymentCsv $path @('Name') @('Value') } $case.Error
    }
    $content = "{`n  `"one`": `"two,three`"`n}"
    [pscustomobject]@{ Name = 'valid'; Value = $content } | Export-Csv $path -NoTypeInformation
    $rows = @(Import-DeploymentCsv $path @('Name') @('Value'))
    Assert ($rows.Count -eq 1 -and $rows[0].Value -eq $content) 'Quoted multiline CSV values must be preserved.'
    foreach ($json in @('{"key":1,"key":2}', '{"outer":{"key":1,"KEY":2}}')) {
        Assert-Throws { Read-JsonCell $json 'Example' ([System.Collections.IDictionary]) @{} } '*duplicate properties*'
    }
    $json = Read-JsonCell '{"ADMINPASSWORD":"example"}' 'Example' ([System.Collections.IDictionary]) @{}
    Assert-Throws { Assert-NoKey $json @('adminPassword') 'Example' } '*managed by dedicated*'
    $value = Read-JsonCell '{"Values":"test","Keys":"test","empty":[],"one":[{}]}' 'Example' ([System.Collections.IDictionary]) @{}
    $roundTrip = ConvertTo-OrderedValue $value | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
    Assert ($roundTrip.psbase.Count -eq 4 -and $roundTrip.empty -is [array] -and $roundTrip.empty.Count -eq 0 -and $roundTrip.one.Count -eq 1) 'Dictionary member names and array sizes must survive serialization.'
    Assert-Throws { Assert-ResourceId '/subscriptions/------------------------------------/resourceGroups/rg/providers/Microsoft.Compute/disks/disk' 'Microsoft.Compute/disks/[^/]+' 'Disk' } '*full*resource ID*'
    Assert-Throws { Assert-ResourceId '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/MicrosoftXCompute/disks/disk' 'Microsoft.Compute/disks/[^/]+' 'Disk' } '*full*resource ID*'
    Assert-Throws { Assert-ResourceName 'parent/child' 'Name' } '*use 1-80*'
    Assert-Throws { Assert-IpAddress '10.1' 'Address' } '*canonical*'
    Assert-Throws { Assert-IpAddress '0x7f000001' 'Address' } '*canonical*'
    Assert-IpAddress '10.0.0.1' 'Address' -IPv4Only
    Assert-IpAddress '2001:db8::1' 'Address'
    Assert-SshPublicKey (Get-Content (Join-Path $PSScriptRoot 'fixtures/ssh-test.pub') -Raw).Trim() 'Validate'
    Assert-SshPublicKey 'REPLACE_WITH_YOUR_SSH_PUBLIC_KEY' 'Generate'
    foreach ($key in @('REPLACE_WITH_YOUR_SSH_PUBLIC_KEY', 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQFake', 'ssh-ed25519 YWJj')) {
        Assert-Throws { Assert-SshPublicKey $key 'Validate' } '*valid RSA*'
    }
    # Exercise the RSA branch using an ephemeral key; no private key is serialized.
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $stream = [IO.MemoryStream]::new()
    try {
        $public = $rsa.ExportParameters($false)
        foreach ($field in @([Text.Encoding]::ASCII.GetBytes('ssh-rsa'), $public.Exponent, ([byte[]](@(0) + $public.Modulus)))) {
            $length = [BitConverter]::GetBytes([Net.IPAddress]::HostToNetworkOrder([int]$field.Length))
            $stream.Write($length, 0, $length.Length)
            $stream.Write($field, 0, $field.Length)
        }
        Assert-SshPublicKey ('ssh-rsa ' + [Convert]::ToBase64String($stream.ToArray())) 'Validate'
    }
    finally { $rsa.Dispose(); $stream.Dispose() }
    Write-Host 'All common parsing and validation checks passed.'
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force }
