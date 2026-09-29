# Contributing

Contributions should keep the project read-only against Citrix and Active
Directory, deterministic, and runnable without real infrastructure.

## Development workflow

1. Create a focused branch from `main`.
2. Keep every example, fixture, and screenshot synthetic.
3. Add or update Pester tests for behavioral changes, and a synthetic case for
   every new recommendation rule.
4. Run `./scripts/Update-DemoData.ps1` after changing the generator, the
   resolver, the rules, or the report.
5. Run Pester, the Node tests, and PSScriptAnalyzer.
6. Update the documentation and the changelog when behavior changes.
7. Open a pull request explaining the change and how it was validated.

Use English for code, documentation, issues, and commit messages.

## Rules for recommendations

A recommendation rule must be deterministic, explain its evidence, suggest an
action, and never change the site. Keep the analysis in the PowerShell module;
the page only displays the report.

## Pull request checklist

- [ ] No real snapshot, report, or customer name is included.
- [ ] Pester passes on PowerShell 7.
- [ ] `node --test tests/web/*.test.mjs` passes.
- [ ] PSScriptAnalyzer reports no warnings or errors.
- [ ] The demo data is current.
- [ ] Documentation and `CHANGELOG.md` reflect the change.

Security reports must follow `SECURITY.md`, not the public issue tracker.
