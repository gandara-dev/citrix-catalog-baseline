<#
.SYNOPSIS
Regenerates the synthetic sample snapshot and the demo report.

.DESCRIPTION
The PowerShell module is the only implementation of the access resolver and
the recommendation rules. This script writes samples/synthetic.snapshot.json
and site/data/demo-report.json from it. Pester fails when either file is
stale, so run this after changing the generator, the resolver, the rules, or
the report.

.EXAMPLE
./scripts/Update-DemoData.ps1
#>
[CmdletBinding()]
param(
    [string]$SnapshotPath = (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'samples') 'synthetic.snapshot.json'),
    [string]$ReportPath = (Join-Path (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'site') 'data') 'demo-report.json')
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repositoryRoot 'src/CitrixCatalogBaseline/CitrixCatalogBaseline.psd1') -Force

$snapshot = New-CcbSyntheticSnapshot
# The demo site's naming convention (docs/naming-convention.md).
$convention = @{
    CatalogNamePattern = 'MC-[A-Z]{3}-(W10|W11|S22)-(POOL|DED|MS|RPC)-[A-Z0-9]+'
    DeliveryGroupNamePattern = 'DG-[A-Z]{3}-(W10|W11|S22)-(POOL|DED|MS|RPC)-[A-Z0-9]+'
    MachineNamePattern = '[A-Z]{3}(W10|W11|S22)[A-Z]{3}[0-9]{3}'
}
foreach ($path in $SnapshotPath, $ReportPath) {
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
}
# LF line endings keep the files identical on Windows and Linux.
[System.IO.File]::WriteAllText($SnapshotPath, (($snapshot | ConvertTo-Json -Depth 30) -replace "`r`n", "`n") + "`n")
[System.IO.File]::WriteAllText($ReportPath, ((New-CcbReport -Snapshot $snapshot @convention | ConvertTo-Json -Depth 30) -replace "`r`n", "`n") + "`n")
