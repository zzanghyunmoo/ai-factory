[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidateSet('Create','Destroy')][string]$Action)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Infra.psm1') -Force -DisableNameChecking
try {
    if (-not $env:INFRA_ROOT -or -not $env:INFRA_OWNER -or -not $env:INFRA_IMAGE_HASH) { throw 'Missing lifecycle bridge inputs.' }
    $context = Get-InfraContext $env:INFRA_ROOT
    Invoke-WithInstanceLock $context {
        Invoke-Lifecycle $context $Action $env:INFRA_OWNER $env:INFRA_IMAGE_HASH
    } -Bridge
} catch { Write-Error $_; exit 1 }
