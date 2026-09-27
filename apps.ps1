[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet('Bootstrap','DeployLocal','Deploy','Status','Forward')]
    [string]$Command,
    [ValidateSet('argocd','litellm')]
    [string]$Service = 'litellm'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts/windows/Apps.psm1') -Force -DisableNameChecking
try { Invoke-AppsCommand (Get-InfraContext $PSScriptRoot) $Command $Service }
catch { Write-Error $_; exit 1 }
