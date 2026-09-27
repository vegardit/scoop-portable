# Regression tests for exact user PATH snapshots. Only a unique HKCU test subkey
# is changed; the current user's Environment key is never used by this fixture.
param([string]$PortableRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$source = Get-Content -LiteralPath "$PortableRoot\scoop-portable.cmd" -Raw
$helper = $source -split '(?m)^:portable_environment_source\r?\n', 2
if ($helper.Count -ne 2) { throw 'Missing embedded environment helper' }
. ([scriptblock]::Create($helper[1]))

function Assert-Fails([scriptblock]$Action, [string]$Description) {
    try { & $Action } catch { return }
    throw "Expected failure: $Description"
}

function Assert-PathState([string]$Value, [Microsoft.Win32.RegistryValueKind]$Kind) {
    if ($key.GetValueKind('Path') -ne $Kind -or
        -not [string]::Equals($key.GetValue('Path', $null, 'DoNotExpandEnvironmentNames'), $Value, 'Ordinal')) {
        throw 'The raw PATH value or registry type changed'
    }
}

$testId = [guid]::NewGuid().ToString('N')
$subkey = "Software\ScoopPortable\Tests\UserPath-$testId"
$fixture = Join-Path $env:TEMP "scoop-portable-user-path-$testId"
New-Item -ItemType Directory -Path $fixture | Out-Null
$key = $null
try {
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($subkey)
    $snapshot = Join-Path $fixture 'path.json'
    # Cross both setx's 1024-character limit and CMD's 8191-character limit.
    # Build non-ASCII text without relying on the source file's encoding.
    $literal = '%USERPROFILE%\bin;C:\space & tools!^(x);C:\' + [char]0x00E9 + [char]0x4E2D
    foreach ($value in @('C:\short', ('C:\long;' * 200), ('C:\long;' * 1200), $literal, '')) {
        foreach ($kind in @('String', 'ExpandString')) {
            $key.SetValue('Path', $value, $kind)
            Save-ScoopPortableUserPath $snapshot $subkey
            $key.SetValue('Path', 'changed by an installer', 'String')
            if (-not (Restore-ScoopPortableUserPath $snapshot $subkey)) { throw 'A changed PATH was not restored' }
            Assert-PathState $value $kind
            [IO.File]::Delete($snapshot)
        }
    }

    # A case-only edit and a type-only edit must both count as changes.
    $key.SetValue('Path', 'C:\MixedCase;%USERPROFILE%', 'ExpandString')
    Save-ScoopPortableUserPath $snapshot $subkey
    $key.SetValue('Path', 'c:\mixedcase;%userprofile%', 'ExpandString')
    if (-not (Restore-ScoopPortableUserPath $snapshot $subkey)) { throw 'A case-only edit was ignored' }
    $key.SetValue('Path', 'C:\MixedCase;%USERPROFILE%', 'String')
    if (-not (Restore-ScoopPortableUserPath $snapshot $subkey)) { throw 'A type-only edit was ignored' }
    Assert-PathState 'C:\MixedCase;%USERPROFILE%' 'ExpandString'
    $key.DeleteValue('Path')
    if (-not (Restore-ScoopPortableUserPath $snapshot $subkey)) { throw 'A removed PATH was not restored' }
    [IO.File]::Delete($snapshot)

    $key.DeleteValue('Path')
    $key.SetValue('Unrelated', 'keep')
    Save-ScoopPortableUserPath $snapshot $subkey
    if (Restore-ScoopPortableUserPath $snapshot $subkey) { throw 'An absent PATH was treated as changed' }
    $key.SetValue('Path', '', 'String')
    if (-not (Restore-ScoopPortableUserPath $snapshot $subkey)) { throw 'Empty PATH was confused with absence' }
    if ($key.GetValueNames() -contains 'Path') { throw 'Originally absent PATH was retained' }
    if ($key.GetValue('Unrelated') -ne 'keep') { throw 'An unrelated value was changed' }
    [IO.File]::Delete($snapshot)

    # Missing keys should remain absent when no restoration is needed.
    Save-ScoopPortableUserPath $snapshot "$subkey\missing"
    if (Restore-ScoopPortableUserPath $snapshot "$subkey\missing") { throw 'A missing key was treated as changed' }
    if ($key.GetSubKeyNames() -contains 'missing') { throw 'An unchanged missing key was created' }
    [IO.File]::Delete($snapshot)

    $key.SetValue('Path', 'C:\original', 'String')
    Assert-Fails { Save-ScoopPortableUserPath "$fixture\missing\path.json" $subkey } 'unwritable snapshot'
    Save-ScoopPortableUserPath $snapshot $subkey
    $savedBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($snapshot))
    Assert-Fails { Save-ScoopPortableUserPath $snapshot $subkey } 'snapshot filename collision'
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($snapshot)) -cne $savedBytes) {
        throw 'An existing recovery snapshot was overwritten'
    }

    # Deny new write handles, but keep our existing handle so permissions can be
    # restored even if the assertion fails. This proves unchanged means no write.
    $readOnly = $key.GetAccessControl()
    $rule = [Security.AccessControl.RegistryAccessRule]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent().User,
        [Security.AccessControl.RegistryRights]::SetValue,
        [Security.AccessControl.AccessControlType]::Deny)
    $readOnly.AddAccessRule($rule)
    try {
        $key.SetAccessControl($readOnly)
        if (Restore-ScoopPortableUserPath $snapshot $subkey) { throw 'An unchanged PATH was restored' }
        $key.SetValue('Path', 'changed', 'String')
        Assert-Fails { Restore-ScoopPortableUserPath $snapshot $subkey } 'registry write denied'
        Assert-PathState 'changed' 'String'
        if (-not (Test-Path -LiteralPath $snapshot)) { throw 'Failed restoration lost its snapshot' }
    } finally {
        # Mutate the descriptor when undoing the denial: SetAccessControl skips
        # an unchanged descriptor, even if it was read before the deny was added.
        $readOnly.RemoveAccessRuleSpecific($rule)
        $key.SetAccessControl($readOnly)
    }
    if (-not (Restore-ScoopPortableUserPath $snapshot $subkey)) { throw 'Restoration could not be retried' }
    Assert-PathState 'C:\original' 'String'

    'invalid JSON' | Set-Content -LiteralPath $snapshot -Encoding Unicode
    Assert-Fails { Restore-ScoopPortableUserPath $snapshot $subkey } 'invalid snapshot'
    Assert-PathState 'C:\original' 'String'
    '{"exists":true,"kind":"String","value":null}' | Set-Content -LiteralPath $snapshot -Encoding Unicode
    Assert-Fails { Restore-ScoopPortableUserPath $snapshot $subkey } 'invalid snapshot value'
    Assert-PathState 'C:\original' 'String'
    Write-Host 'User PATH snapshot tests passed.'
} catch {
    # Preserve the assertion error if registry cleanup also fails.
    [Console]::Error.WriteLine($_.ToString())
    throw
} finally {
    if ($key) {
        $key.Dispose()
        # The fixed prefix and fresh GUID restrict cleanup to this fixture's key.
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($subkey)
    }
}
