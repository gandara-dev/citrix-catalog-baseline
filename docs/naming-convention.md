# Naming Convention

A consistent naming convention lets anyone read a site, an operating system,
and a purpose out of an object name, and lets tooling group and check objects.
The fictional demo site follows the convention below, and rule `CCB014`
reports every name that breaks the convention you configure.

## Convention used by the demo site

| Object | Pattern | Example |
|---|---|---|
| Machine catalog | `MC-<SITE>-<OS>-<MODEL>-<WORKLOAD>` | `MC-LIS-W11-POOL-FINANCE` |
| Delivery group | `DG-<SITE>-<OS>-<MODEL>-<WORKLOAD>` | `DG-LIS-W11-DED-ENGINEERING` |
| Machine | `<SITE><OS><ROLE><NNN>` (15 characters or fewer, the NetBIOS limit) | `LISW11FIN001` |
| AD group | `GRP-<TYPE>-<NAME>`, upper case | `GRP-CTX-FINANCE`, `GRP-DEPT-HR` |

| Token | Values |
|---|---|
| `SITE` | three-letter site code, for example `LIS` for Lisbon |
| `OS` | `W10`, `W11`, `S22` (Windows Server 2022) |
| `MODEL` | `POOL` pooled random, `DED` dedicated (static), `MS` multi-session, `RPC` Remote PC Access |
| `WORKLOAD` | the user population or application set: `GENERAL`, `FINANCE`, `ENGINEERING`, … |
| `ROLE` | three letters for the workload: `GEN`, `FIN`, `ENG`, `SHD`, `RPC`, `LEG` |
| AD `TYPE` | `CTX` Citrix entitlement groups, `DEPT` departments, `OFFICE`, `REGION`, `TEAM` |

Access rules keep the names Citrix generates from the delivery group name
(`DG-LIS-W11-POOL-FINANCE_1`, `DG-LIS-W11-POOL-FINANCE_AG`).

The demo contains one deliberate exception, the catalog `Pilot W11 (temp)`,
created outside the process; `CCB014` reports it.

## Checking a site against your convention

Pass one regular expression per object type. The whole name must match; leave
a pattern out to skip that check. Machine names are checked without the
`DOMAIN\` prefix.

```powershell
./scripts/Invoke-CatalogReview.ps1 -AdminAddress ddc01.corp.example.test `
    -CatalogNamePattern 'MC-[A-Z]{3}-(W10|W11|S22)-(POOL|DED|MS|RPC)-[A-Z0-9]+' `
    -DeliveryGroupNamePattern 'DG-[A-Z]{3}-(W10|W11|S22)-(POOL|DED|MS|RPC)-[A-Z0-9]+' `
    -MachineNamePattern '[A-Z]{3}(W10|W11|S22)[A-Z]{3}[0-9]{3}'
```

The patterns are recorded in `report.json` under `settings.namingConvention`.
