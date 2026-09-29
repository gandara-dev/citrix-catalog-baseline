# Release Verification

## Public release gate

Every change must pass:

- Pester on Windows and Linux: validation, access model, all recommendation
  rules, pseudonymization, report determinism, current demo data, and the
  mocked collector;
- PSScriptAnalyzer with no warnings or errors;
- the page tests in Node against the generated demo report;
- JSON Schema validation of the sample snapshot;
- a check from a fresh clone: `Invoke-CatalogReview.ps1 -Synthetic` produces a
  report, and the page loads it through `Start-ReviewPage.ps1`.

These prove the model, the rules, and the page behave as documented on
synthetic data. They are not evidence about a real site.

## Environment acceptance gate

Before relying on a report from a real site:

1. Run the collector with a Read Only Administrator account on a
   non-production site, or on production during a quiet period, with
   `-SkipSoftware` first.
2. Pick three delivery groups (one shared, one private, one with an access
   policy exclusion) and compare the granted users with Studio and with
   `Get-BrokerEntitlementPolicyRule`, `Get-BrokerAssignmentPolicyRule`, and
   `Get-BrokerAccessPolicyRule`.
3. For two users with nested memberships, compare the reported path with
   `Get-ADPrincipalGroupMembership` or the AD console.
4. Check the access policy rules for `AllowedConnections`, SmartAccess tags, or
   IP filters the model does not evaluate, and note which reported grants they
   would change.
5. Enable the software inventory on one pooled catalog and one persistent
   catalog; confirm WinRM access, the duration, and a sample of the versions
   against the machines.
6. Review every High recommendation with the site owner before acting on it.
7. If the files must leave the environment, run with `-Pseudonymize` (and
   `-IncludeCatalogNames` when names identify a customer), review them, and
   follow the organization's data handling rules.
