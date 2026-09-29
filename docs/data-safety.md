# Data Safety

A snapshot and a report describe who can reach which desktops, which groups
exist, and what software runs where. Treat both as confidential internal data.

## What the project does

- **Read-only collection.** The collector calls only `Get-*` Broker and Active
  Directory cmdlets and reads registry values on the VDAs. It changes nothing.
- **Local files.** The snapshot and report are written only to the output
  directory you choose.
- **No network from the page.** The page reads `report.json` with the
  browser's file API inside the tab. It sends nothing anywhere; the only fetch
  is the bundled demo report. There is no analytics, no telemetry, and no
  third-party script.
- **No language model.** Every finding comes from deterministic rules in the
  PowerShell module.
- **Escaped rendering.** Every value from a report is escaped before it is
  shown, and CSV exports neutralize cells that a spreadsheet would run as a
  formula.

## Pseudonymization

`Protect-CcbSnapshot` (or `Invoke-CatalogReview.ps1 -Pseudonymize`) replaces
every SID and every user, group, and machine name with a code derived from an
HMAC-SHA256 of the original value. The key is random per run and never saved:

- the same identity maps to the same code inside one snapshot, so access paths
  and assignments still make sense;
- two protected snapshots cannot be linked to each other or reversed.

Catalog, delivery group, rule, and software names are kept by default because
the review needs them. Add `-IncludeCatalogNames` when those names identify a
customer or a project.

Pseudonymization is not anonymization. Software lists, counts, and the shape
of the site can still identify an organization. Review a file before it leaves
your control, and follow your organization's data handling rules; when in
doubt, do not share it.

## Repository hygiene

`.gitignore` blocks `*.snapshot.json`, `report.json`, and the default `review/`
output directory, except the synthetic sample in `samples/`. Never commit a
real snapshot or report, even pseudonymized.
