<#
.SYNOPSIS
Collects (or loads) a site snapshot and writes the review report.

.DESCRIPTION
One entry point for the whole workflow:

- with -AdminAddress (or no source parameter on a Delivery Controller), it
  collects a snapshot through the Citrix Broker SDK and Active Directory;
- with -SnapshotPath, it analyzes a snapshot collected earlier;
- with -Synthetic, it uses the fictional demo site.

It writes site.snapshot.json (unless loaded from disk) and report.json to
-OutputDirectory. Open report.json in the review page
(./scripts/Start-ReviewPage.ps1 -Open, then "open report"). Nothing leaves this
machine.

.EXAMPLE
./scripts/Invoke-CatalogReview.ps1 -AdminAddress ddc01.corp.example.test -Pseudonymize -Verbose

.EXAMPLE
./scripts/Invoke-CatalogReview.ps1 -Synthetic -OutputDirectory ./review
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Synthetic', Justification = 'The switch selects the Synthetic parameter set.')]
[CmdletBinding(DefaultParameterSetName = 'Collect')]
param(
    [Parameter(ParameterSetName = 'Collect')]
    [string]$AdminAddress,

    [Parameter(ParameterSetName = 'Collect')]
    [switch]$SkipSoftware,

    [Parameter(ParameterSetName = 'Collect')]
    [pscredential]$Credential,

    [Parameter(ParameterSetName = 'Snapshot', Mandatory)]
    [string]$SnapshotPath,

    [Parameter(ParameterSetName = 'Synthetic', Mandatory)]
    [switch]$Synthetic,

    [string]$OutputDirectory = './review',

    # Replace user, group, and machine identities with pseudonyms before writing anything.
    [switch]$Pseudonymize,

    [switch]$IncludeCatalogNames,

    [string]$MinimumVdaVersion = '2203',
    [int]$UnusedDays = 60,
    [double]$OverlapThreshold = 0.8,
    [int]$MaxNestingDepth = 3,

    # Naming convention checks (CCB014): regular expressions for whole names.
    [string]$CatalogNamePattern,
    [string]$DeliveryGroupNamePattern,
    [string]$MachineNamePattern
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repositoryRoot 'src/CitrixCatalogBaseline/CitrixCatalogBaseline.psd1') -Force

$snapshot = switch ($PSCmdlet.ParameterSetName) {
    'Snapshot' { Get-Content -LiteralPath $SnapshotPath -Raw | ConvertFrom-Json }
    'Synthetic' { New-CcbSyntheticSnapshot }
    default {
        $collect = @{ SkipSoftware = $SkipSoftware }
        if ($AdminAddress) { $collect.AdminAddress = $AdminAddress }
        if ($Credential) { $collect.Credential = $Credential }
        Get-CcbSiteSnapshot @collect
    }
}
if ($Pseudonymize) {
    $snapshot = Protect-CcbSnapshot -Snapshot $snapshot -IncludeCatalogNames:$IncludeCatalogNames
}

$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
if ($PSCmdlet.ParameterSetName -ne 'Snapshot' -or $Pseudonymize) {
    $snapshotFile = Join-Path $OutputDirectory 'site.snapshot.json'
    $snapshot | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $snapshotFile -Encoding utf8NoBOM
    Write-Verbose "Snapshot written to $snapshotFile"
}

$settings = @{
    MinimumVdaVersion = $MinimumVdaVersion
    UnusedDays = $UnusedDays
    OverlapThreshold = $OverlapThreshold
    MaxNestingDepth = $MaxNestingDepth
    CatalogNamePattern = $CatalogNamePattern
    DeliveryGroupNamePattern = $DeliveryGroupNamePattern
    MachineNamePattern = $MachineNamePattern
}
$report = New-CcbReport -Snapshot $snapshot @settings
$reportFile = Join-Path $OutputDirectory 'report.json'
$report | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $reportFile -Encoding utf8NoBOM

[pscustomobject]@{
    Site = $report.site.name
    Catalogs = $report.summary.catalogs
    Machines = $report.summary.machines
    UsersWithAccess = $report.summary.usersWithAccess
    High = $report.summary.recommendations.High
    Medium = $report.summary.recommendations.Medium
    Low = $report.summary.recommendations.Low
    Info = $report.summary.recommendations.Info
    Report = (Resolve-Path -LiteralPath $reportFile).Path
}
