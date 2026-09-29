# Citrix Catalog Baseline in Codespaces

This codespace has PowerShell 7 and the module. The console runs on port 8767
and opens by itself (see the **Ports** tab) with the fictional demo site. A
first synthetic review was already written to `review/`.

Open a terminal and run PowerShell with `pwsh`.

## Run a review

```powershell
./scripts/Invoke-CatalogReview.ps1 -Synthetic -OutputDirectory ./review `
    -CatalogNamePattern 'MC-[A-Z]{3}-(W10|W11|S22)-(POOL|DED|MS|RPC)-[A-Z0-9]+' `
    -MachineNamePattern '[A-Z]{3}(W10|W11|S22)[A-Z]{3}[0-9]{3}'
```

Download `review/report.json` (right-click it in the Explorer) and choose
**Open report** in the console, or keep using the demo site.

## Ask the module directly

```powershell
Import-Module ./src/CitrixCatalogBaseline/CitrixCatalogBaseline.psd1
$site = New-CcbSyntheticSnapshot
Resolve-CcbAccess -Snapshot $site | Where-Object UserName -eq 'CORP\diego.esteves' |
    Format-Table DeliveryGroupName, Status, @{ n = 'Path'; e = { $_.Path -join ' > ' } }
Get-CcbRecommendation -Snapshot $site | Format-Table Id, Severity, Title -Wrap
```

## Pseudonymize a snapshot

```powershell
New-CcbSyntheticSnapshot | Protect-CcbSnapshot | ConvertTo-Json -Depth 30 | Set-Content ./review/protected.snapshot.json
```

## Tests

```powershell
Invoke-Pester ./tests
```

A real site needs a Delivery Controller or the Citrix PowerShell SDK and the
ActiveDirectory module, which this codespace does not have; see
`docs/operations-guide.md`. Stop the codespace when you are done so it does not
use your Codespaces quota.
