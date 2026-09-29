# Access Model

`Resolve-CcbAccess` answers one question for every user and delivery group:
can this user start a desktop here, and why? It follows the on-premises Citrix
Virtual Apps and Desktops model.

## Rules

Each delivery group carries two kinds of rules.

| Rule | Broker cmdlet | Grants |
|---|---|---|
| Entitlement rule | `Get-BrokerEntitlementPolicyRule` | a desktop in a **shared** (pooled) delivery group |
| Assignment rule | `Get-BrokerAssignmentPolicyRule` | a desktop in a **private** (static) delivery group |
| Access policy rule | `Get-BrokerAccessPolicyRule` | permission to connect to the delivery group |

A private desktop can also be granted by a direct machine assignment
(`AssociatedUserSIDs` on the machine), without any assignment rule.

## Matching a rule

A rule matches a user when:

1. the rule is enabled;
2. the user is not excluded: when `ExcludedUserFilterEnabled` is true, neither
   the user nor any group the user belongs to (through any level of nesting) is
   in `ExcludedUsers`;
3. the user is included: when `IncludedUserFilterEnabled` is false the rule
   includes **every** user; otherwise the user, or a group the user belongs to,
   is in `IncludedUsers`.

## Outcome

| Status | Meaning |
|---|---|
| `Granted` | a desktop rule (or machine assignment) grants a desktop and an access policy rule matches |
| `BlockedByAccessPolicy` | a desktop is granted but no access policy rule matches, so the connection is refused |
| `DeliveryGroupDisabled` | the rules would grant access but the delivery group is disabled |

Users that no desktop rule grants are not listed at all.

A catalog is reachable by the union of the users granted in every delivery
group that contains machines from it. A delivery group with machines from two
catalogs makes its users appear in both.

## Paths

Group membership is walked breadth-first from the user up through `memberOf`,
so the path reported for a rule is the **shortest** chain from the user to the
principal the rule names, for example:

```text
CORP\ana.alves › CORP\GRP-Dept-Finance › CORP\GRP-VDI-Finance
```

`NestingDepth` counts the group-to-group hops in that chain (0 when the user is
a direct member of the named group). Circular nesting cannot loop: each
principal is visited once, and `CCB011` reports the cycle.

## Not evaluated

- The connection type of access policy rules (`AllowedConnections`: through
  Citrix Gateway or direct), SmartAccess tags, and client IP or name filters.
  Any enabled access rule that matches the user counts. A real connection can
  still be refused by those filters.
- Published applications and application groups.
- Citrix Cloud (DaaS) and its identity providers.
- Users that exist only in a trusted forest the collector cannot resolve: they
  appear as `(unresolved)` groups without members.
