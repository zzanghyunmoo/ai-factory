$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module "$root/scripts/windows/Apps.psm1" -Force -DisableNameChecking
$script:count = 0
function Check($Name, [scriptblock]$Body) { & $Body; $script:count++; Write-Host "PASS $Name" }
function Reject([scriptblock]$Body, $Pattern) {
    try { & $Body } catch { if ($_.Exception.Message -notmatch $Pattern) { throw }; return }
    throw "Expected refusal: $Pattern"
}
Check 'new credentials use independent cryptographic values' {
    $one = New-AppSecrets
    $two = New-AppSecrets
    if ($one.items[0].stringData.POSTGRES_PASSWORD -eq $two.items[0].stringData.POSTGRES_PASSWORD) { throw 'Repeated random password' }
    $proxy = $one.items[1].stringData
    if ($proxy.LITELLM_MASTER_KEY -eq $proxy.LITELLM_SALT_KEY) { throw 'Shared encryption and authentication keys' }
    $dbPassword = ([Uri]$proxy.DATABASE_URL).UserInfo.Split(':')[1]
    if ($dbPassword -ceq $one.items[0].stringData.POSTGRES_PASSWORD) { throw 'Application uses database admin password' }
    if ($one.items[0].metadata.namespace -cne 'postgresql' -or $one.items[1].metadata.namespace -cne 'litellm') { throw 'Shared database namespace not isolated' }
    if (([Uri]$proxy.DATABASE_URL).Host -cne 'postgres.postgresql.svc.cluster.local') { throw 'Shared database DNS mismatch' }
}
Check 'existing data prevents silent credential regeneration' {
    Assert-AppSecretCreationAllowed @() @()
    Reject { Assert-AppSecretCreationAllowed @('postgres-env') @() } 'Restore'
    Reject { Assert-AppSecretCreationAllowed @() @('postgres-data') } 'Restore'
}
Check 'matching secret reused and mismatched secret rejected without leaking values' {
    $wanted = [pscustomobject]@{metadata=[pscustomobject]@{name='litellm-env'};stringData=[pscustomobject]@{KEY='private-test-value'}}
    $current = [pscustomobject]@{data=[pscustomobject]@{KEY=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('private-test-value'))}}
    Assert-AppSecretMatches $wanted $current
    $current.data.KEY = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('different-private-value'))
    try { Assert-AppSecretMatches $wanted $current; throw 'Expected mismatch' }
    catch {
        if ($_.Exception.Message -notmatch 'Credential mismatch' -or $_.Exception.Message -match 'private.*value') { throw }
    }
}
Check 'missing remote credential key rejected' {
    $wanted = [pscustomobject]@{metadata=[pscustomobject]@{name='litellm-env'};stringData=[pscustomobject]@{KEY='value'}}
    Reject { Assert-AppSecretMatches $wanted ([pscustomobject]@{data=[pscustomobject]@{}}) } 'Credential mismatch'
}
Check 'local credential file cannot silently omit required keys' {
    $valid = New-AppSecrets
    Assert-AppSecretDocument $valid
    $valid.items[1].stringData.LITELLM_SALT_KEY = ''
    Reject { Assert-AppSecretDocument $valid } 'Invalid local credentials'
}
Check 'foreign WSL registration rejected before guest access' {
    Reject {
        & (Get-Module Apps) {
            function Read-Owner { [pscustomobject]@{phase='committed';name='infra';owner='owner';guid='owned';basePath='C:\infra-test';imageHash='hash'} }
            function Get-LiveRegistration { [pscustomobject]@{guid='foreign';basePath='C:\infra-test'} }
            function Invoke-Wsl { throw 'Unexpected WSL access' }
            Assert-AppTarget ([pscustomobject]@{Install='C:\infra-test';Versions=[pscustomobject]@{ubuntu=[pscustomobject]@{sha256='hash'}}})
        }
    } 'identity mismatch'
}
Check 'stopped owned WSL is not started by app commands' {
    Reject {
        & (Get-Module Apps) {
            function Read-Owner { [pscustomobject]@{phase='committed';name='infra';owner='owner';guid='owned';basePath='C:\infra-test';imageHash='hash'} }
            function Get-LiveRegistration { [pscustomobject]@{guid='owned';basePath='C:\infra-test'} }
            function Invoke-Wsl { [pscustomobject]@{Text='';ExitCode=0} }
            function Assert-GuestMarker { throw 'Unexpected guest start' }
            Assert-AppTarget ([pscustomobject]@{Install='C:\infra-test';Versions=[pscustomobject]@{ubuntu=[pscustomobject]@{sha256='hash'}}})
        }
    } 'infra is stopped'
}
Check 'app kubectl always names the owned kubeconfig and context' {
    & (Get-Module Apps) {
        function Invoke-Guest($Arguments, $Timeout) {
            if ($Arguments[0] -cne '/usr/local/bin/kubectl' -or $Arguments[1] -cne '--kubeconfig' -or
                $Arguments[2] -cne '/opt/infra/.local/kubeconfig' -or $Arguments[3] -cne '--context' -or $Arguments[4] -cne 'kind-infra') { throw 'Ambient kubectl context used' }
            [pscustomobject]@{Text='';ExitCode=0}
        }
        [void](Invoke-AppKubectl @('get','nodes'))
    }
}
Check 'GitOps wait does not accept status while refresh is pending' {
    & (Get-Module Apps) {
        $script:reads = 0
        function Start-Sleep { }
        function Invoke-AppKubectl($Arguments) {
            if ($Arguments -contains 'annotate') { return '' }
            $script:reads++
            $annotations = @{}
            if ($script:reads -eq 1) { $annotations['argocd.argoproj.io/refresh']='hard' }
            @{metadata=@{annotations=$annotations};status=@{sync=@{status='Synced'};health=@{status='Healthy'}}} | ConvertTo-Json -Depth 10
        }
        Wait-AppSync 'litellm'
        if ($script:reads -lt 2) { throw 'Accepted stale Synced/Healthy before refresh completed' }
    }
}
Write-Host "PASS $script:count app offline tests (no WSL calls)"
