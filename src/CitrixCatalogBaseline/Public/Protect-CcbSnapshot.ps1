function Protect-CcbSnapshot {
    <#
    .SYNOPSIS
    Replaces user, group, and machine identities with stable pseudonyms.

    .DESCRIPTION
    Every SID and every user, group, and machine name is replaced with a code
    derived from an HMAC-SHA256 of the original value. Within one snapshot the
    same identity always maps to the same code, so access paths, assignments,
    and group nesting stay intact. The key is random for each run and is never
    written anywhere, so two protected snapshots cannot be linked to each other
    or reversed.

    Catalog, delivery group, and software names are kept by default because the
    review depends on them; add -IncludeCatalogNames when those names identify
    a customer or a project.

    Pseudonymization reduces what a shared file reveals. It is not
    anonymization: software lists, counts, and structure can still identify an
    organization. Review the file before it leaves your control.

    .EXAMPLE
    Get-CcbSiteSnapshot -AdminAddress ddc01.example.test | Protect-CcbSnapshot | ConvertTo-Json -Depth 20
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        $Snapshot,

        [switch]$IncludeCatalogNames,

        # Fixed key for tests. Leave it out in real use.
        [byte[]]$Key
    )

    process {
        Test-CcbSnapshot -Snapshot $Snapshot -Assert
        if (-not $Key) {
            $Key = [byte[]]::new(32)
            [System.Security.Cryptography.RandomNumberGenerator]::Fill($Key)
        }
        $hmac = [System.Security.Cryptography.HMACSHA256]::new($Key)
        try {
            $code = {
                param([string]$Kind, [string]$Value)
                $bytes = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes("$Kind|$($Value.ToLowerInvariant())"))
                ([BitConverter]::ToString($bytes, 0, 5) -replace '-', '').ToLowerInvariant()
            }
            $sid = { param([string]$Value) "S-PSEUDO-$(& $code 'sid' $Value)" }
            $sids = { param($Values) @($Values | ForEach-Object { & $sid $_ }) }

            $copy = $Snapshot | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
            $copy.site.name = 'Pseudonymized site'
            $copy.site.pseudonymized = $true

            foreach ($user in @($copy.directory.users)) {
                $pseudonym = & $code 'user' $user.sid
                $user.sid = & $sid $user.sid
                $user.name = "user-$pseudonym"
                $user.displayName = "User $pseudonym"
            }
            foreach ($group in @($copy.directory.groups)) {
                $group.name = "group-$(& $code 'group' $group.sid)"
                $group.sid = & $sid $group.sid
                $group.members = @(& $sids $group.members)
            }
            foreach ($deliveryGroup in @($copy.deliveryGroups)) {
                if ($IncludeCatalogNames) { $deliveryGroup.name = "delivery-group-$(& $code 'dg' $deliveryGroup.name)" }
                foreach ($rule in @($deliveryGroup.desktopRules) + @($deliveryGroup.accessRules)) {
                    if ($IncludeCatalogNames) { $rule.name = "rule-$(& $code 'rule' $rule.name)" }
                    $rule.includedUsers = @(& $sids $rule.includedUsers)
                    $rule.excludedUsers = @(& $sids $rule.excludedUsers)
                }
            }
            if ($IncludeCatalogNames) {
                foreach ($catalog in @($copy.catalogs)) { $catalog.name = "catalog-$(& $code 'catalog' $catalog.name)" }
            }
            foreach ($machine in @($copy.machines)) {
                $machine.name = "machine-$(& $code 'machine' $machine.name)"
                $machine.assignedUsers = @(& $sids $machine.assignedUsers)
            }
            return $copy
        }
        finally {
            $hmac.Dispose()
        }
    }
}
