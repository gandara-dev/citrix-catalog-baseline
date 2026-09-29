# Recommendations

`Get-CcbRecommendation` runs deterministic rules over a snapshot. A rule never
changes anything; it points at data worth reviewing and lists the evidence
rows that triggered it. The same snapshot always produces the same result.

Parameters (also accepted by `New-CcbReport` and `Invoke-CatalogReview.ps1`):

| Parameter | Default | Used by |
|---|---|---|
| `-MinimumVdaVersion` | `2203` | CCB006 |
| `-UnusedDays` | `60` | CCB009 |
| `-OverlapThreshold` | `0.8` | CCB003 |
| `-MaxNestingDepth` | `3` | CCB010 |

## CCB001 Disabled account with access (High)

An account disabled in Active Directory still matches a desktop rule and an
access rule, or still owns an assigned machine. The account cannot log on
today, but it will the moment someone re-enables it. Evidence: user, delivery
group, path, assigned machine.

## CCB002 Direct user entitlement (Medium)

A desktop rule names a user instead of a group. Access granted this way is easy
to forget during joiner/mover/leaver processes. Evidence: user, delivery
group, rule.

## CCB003 Overlapping catalogs (Low)

Two catalogs share at least one user, and the software they share divided by
all the software either one has (Jaccard similarity of application names)
reaches `-OverlapThreshold`. Users who reach both may need only one of them.
The action lists what exists only in each catalog. Evidence: shared users.

## CCB004 Version drift across catalogs (Medium)

The same application name appears in several catalogs with different versions.
The newest version found is suggested as the target. Evidence: catalog,
version, number of machines, and whether it is the newest.

## CCB005 Drift inside a persistent catalog (Medium)

For catalogs with static allocation or persistent user changes and at least
three inventoried machines, the catalog baseline is every application present
on more than half of the machines, at its most common version. Each machine is
compared with it. Differences are `Missing`, `Version`, or `Extra`. Pooled
catalogs are skipped: their machines reset from one image.

## CCB006 Unsupported VDA (High)

A machine reports a VDA version older than `-MinimumVdaVersion`. Versions are
compared numerically part by part (`1912.0.9000` is older than `2203`).

## CCB007 Machines without a delivery group (Low)

Machines that belong to no delivery group consume hypervisor resources and
licenses, but no user can reach them. When every machine in a catalog is in
this state, the title says the catalog is unused.

## CCB008 Empty catalog (Low)

A catalog with no machines.

## CCB009 Unused private desktop (Low)

A machine in a private delivery group with an assigned user and no connection
for `-UnusedDays` days, or never, measured from the snapshot time.

## CCB010 Deep group nesting (Low)

Users whose shortest access path crosses more than `-MaxNestingDepth`
group-to-group hops. Evidence rows group identical paths and count the users.

## CCB011 Circular group nesting (Medium)

A group that contains itself through nesting. Active Directory allows it, but
it hides who is really a member.

## CCB012 Blocked by access policy (Info)

A desktop rule grants a desktop but no access rule lets the user connect. Often
intended (for example contractors excluded from a group); listed so the two
rules can be reviewed together.

## CCB013 Disabled delivery group (Info)

A disabled delivery group that still entitles users, usually left over from a
retirement.
