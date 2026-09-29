# Operations Guide

## Prerequisites

- PowerShell 7.2 or newer on the machine that runs the collector.
- The Citrix PowerShell SDK (the Broker snap-in or module), present on every
  Delivery Controller and installable on a management machine.
- The ActiveDirectory module (RSAT Active Directory tools).
- For the software inventory: PowerShell remoting (WinRM) from that machine to
  the VDAs.

## Permissions

| Source | Right needed |
|---|---|
| Citrix site | read machine catalogs, delivery groups, machines, and policy rules; the built-in Read Only Administrator role scoped to the site covers it |
| Active Directory | read users (`sAMAccountName`, `displayName`, `userAccountControl`, `objectSid`) and group membership |
| VDAs (optional) | run a remote PowerShell command; reading `HKLM:\SOFTWARE\...\Uninstall` needs no administrative right, but WinRM usually admits only local administrators or members of Remote Management Users |

## Collect and review

```powershell
./scripts/Invoke-CatalogReview.ps1 -AdminAddress ddc01.corp.example.test -OutputDirectory ./review -Verbose
./scripts/Start-ReviewPage.ps1 -Open
```

Then choose **open report.json** and pick `./review/report.json`.

Useful options:

| Option | Effect |
|---|---|
| `-SkipSoftware` | no remoting to the VDAs; software tabs stay empty |
| `-Credential` | credential for the remoting sessions |
| `-Pseudonymize` | protect identities before anything is written |
| `-IncludeCatalogNames` | with `-Pseudonymize`, also replace catalog, delivery group, and rule names |
| `-SnapshotPath` | analyze a snapshot collected earlier, for example with other thresholds |
| `-CatalogNamePattern`, `-DeliveryGroupNamePattern`, `-MachineNamePattern` | check names against your convention (CCB014) |

`Get-CcbSiteSnapshot` exposes `-PooledSampleSize` (machines inventoried per
pooled catalog, default 1), `-ThrottleLimit` (parallel remoting sessions,
default 16), `-MaxRecordCount`, and `-Server` (domain controller) when called
directly.

## Load and duration

The Broker queries are single reads of each object type. Active Directory
lookups grow with the number of distinct users and groups the rules reach
through nesting. The software inventory opens one remoting session per
inventoried machine; on a large persistent catalog, schedule it outside
business hours or raise `-ThrottleLimit` carefully.

## Troubleshooting

### "The Citrix Broker PowerShell SDK is not available"

Run on a Delivery Controller, or install the Citrix PowerShell SDK and load
the Broker snap-in or module in the session.

### A group shows as "(unresolved)"

The SID belongs to a deleted object or to another forest. Access through that
principal cannot be expanded; the warning names the SID.

### Software inventory failed on a machine

The warning names the machine. Check WinRM, the firewall, and whether the
account may open a remoting session there. The rest of the snapshot is still
written; that machine has no software list.

### A user appears blocked although they connect fine

The model does not evaluate connection types or SmartAccess filters, and it
treats any matching access rule as allowing the connection. Compare with the
access policy rules in Studio; see [access-model.md](access-model.md).
