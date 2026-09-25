[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet('Bootstrap','Plan','Apply','Doctor','Start','Stop','Destroy','Smoke')]
    [string]$Command,
    [string]$ConfirmName = ''
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts/windows/Infra.psm1') -Force -DisableNameChecking
try { Invoke-InfraCommand (Get-InfraContext $PSScriptRoot) $Command $ConfirmName }
catch { Write-Error $_; exit 1 }
