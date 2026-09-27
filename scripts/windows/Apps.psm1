Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Infra.psm1') -DisableNameChecking

function New-AppRandom {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
}

function New-AppSecrets {
    $password = New-AppRandom
    $appPassword = New-AppRandom
    $items = @(
        @{apiVersion='v1';kind='Secret';metadata=@{name='postgres-env';namespace='postgresql'};type='Opaque';stringData=@{
            POSTGRES_USER='postgres';POSTGRES_DB='postgres';POSTGRES_PASSWORD=$password
        }},
        @{apiVersion='v1';kind='Secret';metadata=@{name='litellm-env';namespace='litellm'};type='Opaque';stringData=@{
            DATABASE_URL="postgresql://litellm:${appPassword}@postgres.postgresql.svc.cluster.local:5432/litellm"
            LITELLM_MASTER_KEY=('sk-' + (New-AppRandom));LITELLM_SALT_KEY=('sk-' + (New-AppRandom))
            UI_USERNAME='admin';UI_PASSWORD=(New-AppRandom)
        }}
    )
    @{apiVersion='v1';kind='List';items=$items} | ConvertTo-Json -Depth 10 | ConvertFrom-Json
}

function Assert-AppSecretCreationAllowed($ExistingSecrets, $ExistingClaims) {
    if (@($ExistingSecrets).Count -or @($ExistingClaims).Count) {
        throw 'Restore .local/apps/secrets.json before continuing: existing credentials or data must not be replaced.'
    }
}

function Assert-AppSecretDocument($Document) {
    $expected = @{
        'postgres-env'=@('POSTGRES_USER','POSTGRES_DB','POSTGRES_PASSWORD')
        'litellm-env'=@('DATABASE_URL','LITELLM_MASTER_KEY','LITELLM_SALT_KEY','UI_USERNAME','UI_PASSWORD')
    }
    try {
        if ($Document.kind -cne 'List' -or @($Document.items).Count -ne 2) { throw 'invalid' }
        foreach ($name in $expected.Keys) {
            $matches = @($Document.items | Where-Object { $_.metadata.name -ceq $name })
            $namespace = 'litellm'; if ($name -ceq 'postgres-env') { $namespace = 'postgresql' }
            if ($matches.Count -ne 1 -or $matches[0].metadata.namespace -cne $namespace -or $matches[0].kind -cne 'Secret') { throw 'invalid' }
            foreach ($key in $expected[$name]) {
                $prop = $matches[0].stringData.PSObject.Properties[$key]
                if (-not $prop -or [string]::IsNullOrWhiteSpace([string]$prop.Value)) { throw 'invalid' }
            }
        }
    } catch { throw 'Invalid local credentials in .local/apps/secrets.json; restore the original file.' }
}

function Assert-AppSecretMatches($Wanted, $Current) {
    foreach ($property in $Wanted.stringData.PSObject.Properties) {
        $actual = $Current.data.PSObject.Properties[$property.Name]
        if (-not $actual -or [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($actual.Value)) -cne $property.Value) {
            throw "Credential mismatch for $($Wanted.metadata.name); restore matching local credentials. No secret was changed."
        }
    }
}

function Write-AppPrivateJson([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
}

function Invoke-AppKubectl([string[]]$Arguments, [int]$Timeout = 300) {
    (Invoke-Guest (@('/usr/local/bin/kubectl', '--kubeconfig', '/opt/infra/.local/kubeconfig', '--context', 'kind-infra') + $Arguments) -Timeout $Timeout).Text
}

function Get-AppGuestPath([string]$Path) {
    (Invoke-Guest @('/usr/bin/wslpath', '-a', '-u', $Path)).Text.Trim()
}

function Assert-AppTarget($Context) {
    $record = Read-Owner $Context
    if (-not $record) { throw 'Missing ownership record. Run infra.ps1 Apply first.' }
    Assert-Ownership $record (Get-LiveRegistration) $record.owner $Context.Install $Context.Versions.ubuntu.sha256
    $running = ConvertFrom-WslList (Invoke-Wsl @('--list','--running','--quiet') -Unicode).Text
    if ($running -cnotcontains 'infra') { throw 'Owned infra is stopped. Run infra.ps1 Apply first.' }
    Assert-GuestMarker $record
    [void](Invoke-Guest @('/bin/bash','/opt/infra/scripts/guest/doctor.sh','--root','/opt/infra','--owner-id',$record.owner))
}

function Initialize-AppNamespaces($Context) {
    foreach ($name in @('argocd','postgresql','litellm')) {
        $raw = Invoke-AppKubectl @('get','namespace',$name,'--ignore-not-found','-o','json')
        if ($raw.Trim()) {
            $ns = $raw | ConvertFrom-Json
            $label = $ns.metadata.labels.PSObject.Properties['app.kubernetes.io/managed-by']
            if (-not $label -or $label.Value -cne 'ai-factory') { throw "Existing namespace $name is not managed by ai-factory; no automatic adoption." }
        }
    }
    [void](Invoke-AppKubectl @('apply','--server-side','--field-manager=ai-factory-apps','-f',(Get-AppGuestPath (Join-Path $Context.Root 'kubernetes/bootstrap/namespaces.yaml'))))
}

function Initialize-AppSecrets($Context) {
    $path = Join-Path $Context.Local 'apps/secrets.json'
    $current = @()
    foreach ($pair in @(@('postgresql','postgres-env'), @('litellm','litellm-env'))) {
        $raw = Invoke-AppKubectl @('-n',$pair[0],'get','secret',$pair[1],'--ignore-not-found','-o','json')
        if ($raw.Trim()) { $current += ($raw | ConvertFrom-Json) }
    }
    if (-not (Test-Path -LiteralPath $path)) {
        $claims = (Invoke-AppKubectl @('-n','postgresql','get','pvc','postgres-data','--ignore-not-found','-o','json')).Trim()
        $claimNames = @(); if ($claims) { $claimNames = @('postgres-data') }
        Assert-AppSecretCreationAllowed $current $claimNames
        Write-AppPrivateJson $path (New-AppSecrets)
    }
    $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Assert-AppSecretDocument $saved
    # Check all existing values before creating either missing Secret.
    foreach ($wanted in $saved.items) {
        $found = @($current | Where-Object { $_.metadata.name -ceq $wanted.metadata.name })
        if ($found.Count) { Assert-AppSecretMatches $wanted $found[0] }
    }
    foreach ($wanted in $saved.items) {
        $found = @($current | Where-Object { $_.metadata.name -ceq $wanted.metadata.name })
        if (-not $found.Count) {
            $single = Join-Path $Context.Local ('apps/' + $wanted.metadata.name + '.json')
            Write-AppPrivateJson $single $wanted
            [void](Invoke-AppKubectl @('create','-f',(Get-AppGuestPath $single)))
        }
    }
}

function Initialize-LiteLlmDatabase($Context) {
    [void](Invoke-AppKubectl @('-n','postgresql','rollout','status','statefulset/postgres','--timeout=300s') -Timeout 330)
    $saved = Get-Content -LiteralPath (Join-Path $Context.Local 'apps/secrets.json') -Raw | ConvertFrom-Json
    $proxy = @($saved.items | Where-Object { $_.metadata.name -ceq 'litellm-env' })[0]
    $password = ([Uri]$proxy.stringData.DATABASE_URL).UserInfo.Split(':')[1]
    if ($password -cnotmatch '^[a-f0-9]{64}$') { throw 'Unexpected database credential format; provisioning refused.' }
    $sql = @'
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'litellm') THEN
    CREATE ROLE litellm LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '__PASSWORD__';
  ELSIF EXISTS (SELECT FROM pg_roles WHERE rolname = 'litellm' AND (rolsuper OR rolcreatedb OR rolcreaterole)) THEN
    RAISE EXCEPTION 'Existing litellm role has unexpected administrative privileges';
  END IF;
  IF EXISTS (SELECT FROM pg_database d JOIN pg_roles r ON r.oid = d.datdba WHERE d.datname = 'litellm' AND r.rolname <> 'litellm') THEN
    RAISE EXCEPTION 'Existing litellm database has an unexpected owner';
  END IF;
END $$;
SELECT 'CREATE DATABASE litellm OWNER litellm'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'litellm')\gexec
REVOKE CONNECT ON DATABASE litellm FROM PUBLIC;
GRANT CONNECT ON DATABASE litellm TO litellm;
'@
    $path = Join-Path $Context.Local 'apps/litellm-database.sql'
    [IO.File]::WriteAllText($path, $sql.Replace('__PASSWORD__', $password), (New-Object Text.UTF8Encoding($false)))
    [void](Invoke-Guest @('/bin/bash','-c', 'set -euo pipefail; exec /usr/local/bin/kubectl --kubeconfig /opt/infra/.local/kubeconfig --context kind-infra -n postgresql exec -i postgres-0 -- psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$1"', 'apps', (Get-AppGuestPath $path)))
}

function Wait-AppSync([string]$Name) {
    [void](Invoke-AppKubectl @('-n','argocd','annotate','application',$Name,'argocd.argoproj.io/refresh=hard','--overwrite','--request-timeout=20s') -Timeout 30)
    for ($attempt=0; $attempt -lt 90; $attempt++) {
        $app = (Invoke-AppKubectl @('-n','argocd','get','application',$Name,'-o','json','--request-timeout=20s') -Timeout 30) | ConvertFrom-Json
        $refreshPending = $app.metadata.PSObject.Properties['annotations'] -and $app.metadata.annotations.PSObject.Properties['argocd.argoproj.io/refresh']
        if (-not $refreshPending -and $app.PSObject.Properties['status'] -and $app.status.PSObject.Properties['sync'] -and $app.status.PSObject.Properties['health'] -and
            $app.status.sync.status -eq 'Synced' -and $app.status.health.status -eq 'Healthy') { return }
        Start-Sleep -Seconds 10
    }
    throw "Argo CD $Name did not reach Synced/Healthy. Inspect Application conditions and verify the configured Git ref is published."
}

function Invoke-AppsCommand($Context, [string]$Command, [string]$Service) {
    Invoke-WithInstanceLock $Context {
        Protect-Directory $Context.Local
        Protect-Directory (Join-Path $Context.Local 'apps')
        & (Get-Module Infra) { param($Path) $script:NativeFailureLog = $Path } (Join-Path $Context.Local 'apps-error.log')
        Assert-AppTarget $Context
        switch ($Command) {
            'Bootstrap' {
                Initialize-AppNamespaces $Context
                Initialize-AppSecrets $Context
                $directory = Join-Path $Context.Local 'apps/argocd'
                [void][IO.Directory]::CreateDirectory($directory)
                Receive-PinnedFile $Context.Versions.argocd (Join-Path $directory 'install.yaml')
                Copy-Item -LiteralPath (Join-Path $Context.Root 'kubernetes/argocd/kustomization.yaml') -Destination (Join-Path $directory 'kustomization.yaml')
                [void](Invoke-AppKubectl @('apply','--server-side','--field-manager=ai-factory-apps','-k',(Get-AppGuestPath $directory)) -Timeout 600)
                [void](Invoke-AppKubectl @('-n','argocd','rollout','status','deployment','--timeout=600s') -Timeout 660)
                [void](Invoke-AppKubectl @('-n','argocd','rollout','status','statefulset/argocd-application-controller','--timeout=600s') -Timeout 660)
                Write-Host 'Argo CD ready. LiteLLM credentials are in private .local/apps/secrets.json.'
            }
            'DeployLocal' {
                $app = Invoke-AppKubectl @('-n','argocd','get','application','litellm','postgresql','--ignore-not-found','-o','name')
                if ($app.Trim()) { throw 'Argo CD already owns LiteLLM. Change Git and use Deploy; local apply is refused.' }
                Initialize-AppSecrets $Context
                foreach ($component in @('postgresql','litellm')) {
                    $path = Get-AppGuestPath (Join-Path $Context.Root "kubernetes/$component")
                    [void](Invoke-AppKubectl @('apply','--server-side','--field-manager=ai-factory-apps','--dry-run=server','-k',$path))
                    [void](Invoke-AppKubectl @('apply','--server-side','--field-manager=ai-factory-apps','-k',$path))
                    if ($component -eq 'postgresql') { Initialize-LiteLlmDatabase $Context }
                }
                [void](Invoke-AppKubectl @('-n','litellm','rollout','status','deployment/litellm','--timeout=900s') -Timeout 930)
                Write-Host 'Local LiteLLM ready. GitOps handoff remains: publish the reviewed branch with approval, then Deploy.'
            }
            'Deploy' {
                Initialize-AppSecrets $Context
                foreach ($file in @('project.yaml','postgresql-application.yaml','application.yaml')) {
                    [void](Invoke-AppKubectl @('apply','--server-side','--field-manager=ai-factory-apps','-f',(Get-AppGuestPath (Join-Path $Context.Root "kubernetes/bootstrap/$file"))))
                    if ($file -eq 'postgresql-application.yaml') { Wait-AppSync 'postgresql'; Initialize-LiteLlmDatabase $Context }
                }
                Wait-AppSync 'litellm'
                Write-Host 'Argo CD PostgreSQL and LiteLLM Applications are Synced and Healthy.'
            }
            'Status' {
                Write-Host (Invoke-AppKubectl @('-n','argocd','get','pods'))
                Write-Host (Invoke-AppKubectl @('-n','postgresql','get','pods,services,pvc'))
                Write-Host (Invoke-AppKubectl @('-n','litellm','get','pods,services,pvc'))
                Write-Host (Invoke-AppKubectl @('-n','argocd','get','applications'))
            }
            'Forward' { }
            default { throw 'Unsupported apps command.' }
        }
    }
    if ($Command -eq 'Forward') {
        # Release the instance lock before the foreground forwarding process.
        $port = '4000:4000'; $target = 'service/litellm'
        if ($Service -eq 'argocd') { $port = '18081:80'; $target = 'service/argocd-server' }
        if ($Service -notin @('argocd','litellm')) { throw 'Unsupported forward service.' }
        Write-Host "Forwarding $Service on 127.0.0.1; Ctrl+C stops this tunnel."
        & "$env:SystemRoot/System32/wsl.exe" --distribution infra --user root --exec /usr/local/bin/kubectl `
            --kubeconfig /opt/infra/.local/kubeconfig --context kind-infra -n $Service port-forward --address 127.0.0.1 $target $port
        if ($LASTEXITCODE -ne 0) { throw 'Port-forward exited with an error.' }
    }
}
