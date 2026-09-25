$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module "$root/scripts/windows/Infra.psm1" -Force
$script:count = 0
function Check($Name, [scriptblock]$Body) { & $Body; $script:count++; Write-Host "PASS $Name" }
function Reject([scriptblock]$Body, $Pattern) {
    try { & $Body } catch { if ($_.Exception.Message -notmatch $Pattern) { throw }; return }
    throw "Expected refusal: $Pattern"
}
$path = Join-Path $env:TEMP 'infra offline path'
$record = [pscustomobject]@{ phase='committed'; name='infra'; owner='owner'; guid='guid'; basePath=$path; imageHash='hash' }
$live = [pscustomobject]@{ guid='guid'; basePath=$path }
Check 'WSL dispatcher flags and fixed target are never quoted' {
    foreach ($argument in @('--import', '--distribution', 'infra', '--user', 'root', '--exec', '--list', '--version', '2')) {
        if ((ConvertTo-NativeArgument $argument) -cne $argument) { throw "WSL dispatch token incorrectly quoted: $argument" }
    }
}
Check 'owned identity' { Assert-Ownership $record $live 'owner' $path 'hash' }
Check 'foreign missing owner' { Reject { Assert-Ownership $null $live 'owner' $path 'hash' } 'ownership' }
Check 'missing registration' { Reject { Assert-Ownership $record $null 'owner' $path 'hash' } 'registration' }
Check 'GUID replacement' { Reject { Assert-Ownership $record ([pscustomobject]@{guid='other';basePath=$path}) 'owner' $path 'hash' } 'identity' }
Check 'path replacement' { Reject { Assert-Ownership $record ([pscustomobject]@{guid='guid';basePath="$path-other"}) 'owner' $path 'hash' } 'identity' }
Check 'preparing refusal' {
    $copy = $record.PSObject.Copy(); $copy.phase = 'preparing'
    Reject { Assert-Ownership $copy $live 'owner' $path 'hash' } 'preparing'
}
Check 'confirmation absent' { Reject { Assert-DestroyConfirmation '' } 'confirmation' }
Check 'confirmation exact' { Reject { Assert-DestroyConfirmation 'INFRA' } 'confirmation'; Assert-DestroyConfirmation 'infra' }
Write-Host "PASS $script:count offline tests"

$temp = Join-Path $env:TEMP ('infra-offline-' + [guid]::NewGuid().ToString())
[void][IO.Directory]::CreateDirectory($temp)
try {
    Check 'WSL install allows SYSTEM while private state remains user-only' {
        $installPath = Join-Path $temp 'vm-acl'
        $privatePath = Join-Path $temp 'private-acl'
        Protect-Directory $installPath -AllowSystem
        Protect-Directory $privatePath
        foreach ($entry in @(@($installPath, 1), @($privatePath, 0))) {
            $rules = @((Get-Acl -LiteralPath $entry[0]).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-18' -and $_.AccessControlType -eq 'Allow' -and $_.FileSystemRights -eq 'FullControl' })
            if ($rules.Count -ne $entry[1]) { throw 'Incorrect SYSTEM access boundary for WSL install/private state.' }
        }
    }
    & (Get-Module Infra) {
        param($Temp)
        $when = [datetime]'2026-01-01T00:00:00Z'
        function Get-Process { [pscustomobject]@{ ProcessName='wsl'; StartTime=$when } }
        function Start-Process { throw 'Unexpected duplicate keeper launch' }
        $ctx = [pscustomobject]@{Home=$Temp}
        $owned = [pscustomobject]@{owner='owner';guid='guid'}
        $keeper = [pscustomobject]@{owner='owner';guid='guid';pid=123;started=$when.ToUniversalTime().ToString('o')}
        $file = Join-Path $Temp 'keeper.json'
        [IO.File]::WriteAllText($file, ($keeper | ConvertTo-Json))
        Check 'healthy owned keeper reused without duplicate process' { Start-OwnedKeeper $ctx $owned }
        $keeper.owner = 'foreign'
        [IO.File]::WriteAllText($file, ($keeper | ConvertTo-Json))
        Check 'foreign live keeper identity rejected' { Reject { Start-OwnedKeeper $ctx $owned } 'keeper identity' }
        Remove-Item -LiteralPath $file
    } $temp
    Check 'checksum mismatch' {
        $file = Join-Path $temp 'checksum'; [IO.File]::WriteAllText($file, 'not an image')
        Reject { Assert-Checksum $file ('0' * 64) } 'checksum'
    }
    Check 'native nonzero exit' {
        Reject { Invoke-Native "$env:SystemRoot/System32/WindowsPowerShell/v1.0/powershell.exe" @('-NoProfile','-Command','exit 7') } 'exit 7'
    }
    Check 'native args preserve spaces quotes empty trailing slash' {
        $file = Join-Path $temp 'echo args.exe'
        Add-Type -TypeDefinition 'using System; using System.Text; public class EchoArgs { public static void Main(string[] args) { foreach (string arg in args) Console.WriteLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(arg))); } }' -OutputAssembly $file -OutputType ConsoleApplication
        $expected = @('path with spaces', 'a"b', '', 'C:\space here\', 'dollar$semicolon;')
        $result = Invoke-Native $file $expected
        $lines = $result.Text -split '\r?\n'
        $actual = @($lines[0..($lines.Count-2)] | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) })
        if ($actual.Count -ne $expected.Count) { throw "Argument count differs: $($actual.Count)/$($expected.Count); encoded=$($result.Text); command=$(($expected | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')" }
        for ($i=0; $i -lt $expected.Count; $i++) { if ($actual[$i] -cne $expected[$i]) { throw "Argument $i differs" } }
    }
    Check 'UTF16 native list decode' {
        $command = '[Console]::OutputEncoding=[Text.Encoding]::Unicode; [Console]::Write("infra`r`nUbuntu-26.04`r`n")'
        $result = Invoke-Native "$env:SystemRoot/System32/WindowsPowerShell/v1.0/powershell.exe" @('-NoProfile','-Command',$command) -Unicode
        $names = ConvertFrom-WslList $result.Text
        if ($names.Count -ne 2 -or $names[0] -cne 'infra') { throw 'WSL list decoding failed' }
    }
    Check 'lock exclusion' {
        $lockPath = Join-Path $temp 'instance.lock'; $lock = Enter-InstanceLock $lockPath
        try { Reject { Enter-InstanceLock $lockPath } 'instance lock' } finally { $lock.Dispose() }
        $second = Enter-InstanceLock $lockPath; $second.Dispose()
    }
    Check 'native failure diagnostics stay private' {
        $diagnostic = Join-Path $temp 'native-error.log'
        & (Get-Module Infra) {
            param($Diagnostic)
            $script:NativeFailureLog = $Diagnostic
            try {
                Reject { Invoke-Native "$env:SystemRoot/System32/WindowsPowerShell/v1.0/powershell.exe" @('-NoProfile','-Command','[Console]::Error.WriteLine("private-diagnostic"); exit 9') } 'exit 9.*private .local/native-error.log'
            } finally { $script:NativeFailureLog = $null }
        } $diagnostic
        if ((Get-Content -LiteralPath $diagnostic -Raw) -notmatch 'private-diagnostic') { throw 'Private diagnostics missing' }
    }
    Check 'native timeout' {
        Reject { Invoke-Native "$env:SystemRoot/System32/WindowsPowerShell/v1.0/powershell.exe" @('-NoProfile','-Command','Start-Sleep 10') -Timeout 1 } 'timed out'
    }
    Check 'all PowerShell parses on PS5.1' {
        Get-ChildItem $root -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') -and $_.FullName -notmatch '[\/]\.local[\/]' } | ForEach-Object {
            $tokens = $null; $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
            if ($errors.Count) { throw ($errors | Out-String) }
        }
    }
    # Run lifecycle + lock delegation with fake WSL/registry functions inside the module.
    & (Get-Module Infra) {
        param($Temp)
        $script:fakeLive = $null; $script:fakeMarker = $null; $script:calls = @()
        function Get-LiveRegistration { $script:fakeLive }
        function Invoke-Wsl($Arguments, $Timeout) {
            $script:calls += ,$Arguments
            if ($Arguments[0] -eq '--import') {
                if ((Read-Owner $script:context).phase -ne 'preparing') { throw 'Import before preparing intent' }
                $script:fakeLive = [pscustomobject]@{guid='registry-guid';basePath=$script:context.Install}
            } elseif ($Arguments[0] -eq '--unregister') { $script:fakeLive = $null }
            else { throw 'Unexpected fake WSL call' }
        }
        function Invoke-Guest($Arguments, $Timeout) {
            if ($Arguments[0] -eq '/bin/cat') {
                if (-not $script:fakeMarker) { throw 'Guest marker missing' }
                return [pscustomobject]@{Text=$script:fakeMarker;ExitCode=0}
            }
            $script:fakeMarker = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Arguments[-1]))
            [pscustomobject]@{Text='';ExitCode=0}
        }
        $image = Join-Path $Temp 'image'; [IO.File]::WriteAllText($image,'fake rootfs')
        $hash = (Get-FileHash $image -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:context = [pscustomobject]@{ Home=$Temp; Lock=(Join-Path $Temp 'delegation.lock'); Record=(Join-Path $Temp 'owner.json'); Install=(Join-Path $Temp 'wsl'); Image=$image; Versions=[pscustomobject]@{ubuntu=[pscustomobject]@{sha256=$hash}} }
        Check 'create commit and stable owned retry' {
            Invoke-Lifecycle $script:context Create 'stable-owner' $hash
            if ((Read-Owner $script:context).phase -ne 'committed') { throw 'Commit missing' }
            Invoke-Lifecycle $script:context Create 'stable-owner' $hash
            if ($script:calls.Count -ne 1) { throw 'Retry imported again' }
        }
        Check 'raw destroy denied before unregister' {
            $env:INFRA_DESTROY_CONFIRM = $null
            Reject { Invoke-Lifecycle $script:context Destroy 'stable-owner' $hash } 'confirmation'
            if ($script:calls.Count -ne 1) { throw 'Unauthorized unregister' }
        }
        Check 'foreign marker blocks destroy' {
            $env:INFRA_DESTROY_CONFIRM = 'infra'; $saved = $script:fakeMarker
            $script:fakeMarker = $script:fakeMarker.Replace('stable-owner','foreign-owner')
            try { Reject { Invoke-Lifecycle $script:context Destroy 'stable-owner' $hash } 'marker mismatch' }
            finally { $script:fakeMarker = $saved; $env:INFRA_DESTROY_CONFIRM = $null }
        }
        Check 'delegated lock and stale lease refusal' {
            Invoke-WithInstanceLock $script:context {
                Invoke-WithInstanceLock $script:context { } -Bridge
                Reject { Enter-InstanceLock $script:context.Lock } 'instance lock'
                $script:savedLease = $env:INFRA_LOCK_LEASE
            }
            $env:INFRA_LOCK_LEASE = $script:savedLease
            try { Reject { Invoke-WithInstanceLock $script:context { throw 'Must not execute' } -Bridge } 'Expired' }
            finally { $env:INFRA_LOCK_LEASE = $null }
        }
        Check 'preparing import interruption refuses retry' {
            $record = Read-Owner $script:context; $record.phase = 'preparing'; Write-Owner $script:context $record
            Reject { Invoke-Lifecycle $script:context Create 'stable-owner' $hash } 'preparing'
            $record.phase = 'committed'; Write-Owner $script:context $record
        }
        Check 'explicit owned destroy' {
            $env:INFRA_DESTROY_CONFIRM = 'infra'
            try { Invoke-Lifecycle $script:context Destroy 'stable-owner' $hash }
            finally { $env:INFRA_DESTROY_CONFIRM = $null }
            if ($script:fakeLive -or (Test-Path $script:context.Record)) { throw 'Destroy incomplete' }
        }
    } $temp
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
Write-Host 'PASS extended offline suite; no real WSL commands executed'
