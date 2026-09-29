# Testing Guide

No Citrix site or domain is needed. The synthetic site
(`New-CcbSyntheticSnapshot`) contains one case for every recommendation rule,
and the collector is tested with mocks of the Broker SDK, the ActiveDirectory
module, and PowerShell remoting.

## Pester

Requirements: PowerShell 7.2 or newer and Pester 5.7.1.

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
Invoke-Pester -Path ./tests -CI -Output Detailed
```

The suite covers:

- snapshot validation, including a JSON round trip of the synthetic site;
- the access model: nested groups and shortest paths, machine assignments,
  disabled include filters, exclusions in desktop and access rules, disabled
  rules and delivery groups, direct user entitlements, and circular nesting;
- every recommendation rule, its evidence, severity order, and thresholds, plus
  a clean site that yields no findings;
- pseudonymization: no original identity left, identical findings, stable per
  key, different across keys;
- report determinism, and that the committed demo data matches the module;
- the collector: rule mapping by kind, AD resolution (disabled accounts through
  `userAccountControl`, nested members, unresolved SIDs), software sampling
  (one pooled machine, every registered persistent machine), `-SkipSoftware`,
  and a clear error without the Citrix SDK.

## Page

Requirements: Node.js 22 or newer. No packages are installed.

```powershell
node --test tests/web/*.test.mjs
```

The Node suite loads `site/data/demo-report.json` and checks report
validation, filtering, CSV quoting and formula neutralization, catalog
comparison, and user lookup.

## Demo data

`samples/synthetic.snapshot.json` and `site/data/demo-report.json` are
generated from the module. After changing the generator, the resolver, the
rules, or the report, regenerate them; Pester fails until you do:

```powershell
./scripts/Update-DemoData.ps1
```

## Static analysis

```powershell
Install-Module PSScriptAnalyzer -RequiredVersion 1.24.0 -Scope CurrentUser -Force
$findings = @(Invoke-ScriptAnalyzer -Path . -Recurse -Severity Warning,Error)
if ($findings.Count -gt 0) { $findings | Format-Table; throw 'PSScriptAnalyzer reported findings.' }
```

CI also validates the sample snapshot against `schemas/snapshot.schema.json`
with `Test-Json`, and runs `actionlint` locally before workflow changes.
