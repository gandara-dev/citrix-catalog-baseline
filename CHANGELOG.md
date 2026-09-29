# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [0.2.0] - 2026-09-29

### Added

- `CCB014` reports catalogs, delivery groups, and machines whose names do not
  match a naming convention given as regular expressions
  (`-CatalogNamePattern`, `-DeliveryGroupNamePattern`, `-MachineNamePattern`);
  the patterns are recorded in the report settings.
- Naming convention guide.

### Changed

- The review page is now a Studio-style console: a navigation tree (Machine
  Catalogs, Delivery Groups, Users, Problems), a sortable and filterable list,
  and a details pane with tabs for the selected object. Every access is
  explained in plain words, and every table exports to CSV.
- The synthetic demo site follows an enterprise naming convention for
  catalogs, delivery groups, machines, and AD groups, with one deliberate
  exception for `CCB014`.

## [0.1.0] - 2026-09-29

### Added

- Read-only collector (`Get-CcbSiteSnapshot`) for on-premises Citrix Virtual
  Apps and Desktops: catalogs, delivery groups, machines, and entitlement,
  assignment, and access policy rules through the Broker SDK; users and nested
  groups through the ActiveDirectory module; installed software over
  PowerShell remoting (one machine per pooled catalog, every machine in
  persistent catalogs).
- Versioned snapshot format with a JSON Schema and `Test-CcbSnapshot`.
- Access resolver (`Resolve-CcbAccess`) that combines desktop and access
  policy rules, exclusions, disabled filters, machine assignments, and nested
  groups, and reports the shortest path for each user.
- Thirteen deterministic recommendation rules with evidence and thresholds.
- Pseudonymization (`Protect-CcbSnapshot`) with a random per-run HMAC key.
- Report builder (`New-CcbReport`) and the `Invoke-CatalogReview.ps1` entry
  point.
- Access review page: findings, catalogs with access, software, and machines,
  catalog comparison, user lookup, and CSV export; published on GitHub Pages
  with a fictional demo site.
- Pester, Node, PSScriptAnalyzer, and schema checks in CI.
