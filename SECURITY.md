# Security Policy

## Supported versions

Security fixes are applied to the latest released minor version. The project
is pre-1.0; review the changelog before upgrading.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub Private
Vulnerability Reporting for this repository. Include only a synthetic
reproduction: never real snapshots, reports, user names, host names, or
credentials.

## Security boundaries

- The collector only reads. It runs with the rights of the account that starts
  it; use a Citrix Read Only Administrator and least-privilege AD access.
- The software inventory opens PowerShell remoting sessions to the VDAs with
  that account or the credential passed with `-Credential`.
- Snapshots and reports contain identities, group membership, and software
  inventory. Store them as confidential data; see `docs/data-safety.md`.
- The review page reads a local file in the browser, escapes every value, and
  makes no network request except loading the bundled demo.
- `Start-ReviewPage.ps1` listens on loopback only and serves `site/`.

## Secret handling

The project never stores credentials. Do not put passwords, tokens, or real
exports in the repository, issues, command history, or test fixtures.
