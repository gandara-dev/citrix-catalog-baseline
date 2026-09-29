function Test-CcbSnapshot {
    <#
    .SYNOPSIS
    Validates a site snapshot against schema version 1.

    .DESCRIPTION
    Checks required fields, allowed Citrix values, unique identifiers, and
    references between machines, catalogs, and delivery groups. Returns one
    object per problem; an empty result means the snapshot is valid. Use
    -Assert to throw instead.

    .EXAMPLE
    Get-Content ./site.snapshot.json -Raw | ConvertFrom-Json | Test-CcbSnapshot
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        $Snapshot,

        [switch]$Assert
    )

    process {
        $problems = [System.Collections.Generic.List[object]]::new()
        $add = { param($Path, $Message) $problems.Add([pscustomobject]@{ Path = $Path; Message = $Message }) }

        $isText = { param($Value) $Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value) }
        $isArray = { param($Value) $Value -is [array] -or $Value -is [System.Collections.IList] }
        $isInteger = { param($Value) $Value -is [int] -or $Value -is [long] }
        $isDate = {
            param($Value)
            try { $null -ne (ConvertTo-CcbDate $Value) } catch { $false }
        }

        $version = Get-CcbValue $Snapshot 'schemaVersion'
        if ($version -ne $script:SchemaVersion) {
            & $add 'schemaVersion' "Expected schema version $script:SchemaVersion, found '$version'."
        }

        $site = Get-CcbValue $Snapshot 'site'
        if (-not (& $isText (Get-CcbValue $site 'name'))) { & $add 'site.name' 'Site name is required.' }
        if (-not (& $isDate (Get-CcbValue $site 'collectedAt'))) { & $add 'site.collectedAt' 'Collection time must be an ISO 8601 date.' }

        $directory = Get-CcbValue $Snapshot 'directory'
        $sids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($kind in 'users', 'groups') {
            $items = Get-CcbValue $directory $kind
            if (-not (& $isArray $items)) { & $add "directory.$kind" 'Must be an array.'; continue }
            for ($i = 0; $i -lt $items.Count; $i++) {
                $item = $items[$i]
                $sid = Get-CcbValue $item 'sid'
                if (-not (& $isText $sid)) { & $add "directory.$kind[$i].sid" 'SID is required.'; continue }
                if (-not $sids.Add($sid)) { & $add "directory.$kind[$i].sid" "Duplicate SID '$sid'." }
                if (-not (& $isText (Get-CcbValue $item 'name'))) { & $add "directory.$kind[$i].name" 'Name is required.' }
                if ($kind -eq 'groups' -and -not (& $isArray (Get-CcbValue $item 'members'))) {
                    & $add "directory.groups[$i].members" 'Members must be an array of SIDs.'
                }
            }
        }

        $allowed = @{
            provisioningType = @('MCS', 'Manual', 'PVS')
            allocationType = @('Random', 'Static')
            persistUserChanges = @('Discard', 'OnLocal', 'OnPvd')
            sessionSupport = @('SingleSession', 'MultiSession')
        }
        $catalogUids = @{}
        $catalogs = Get-CcbValue $Snapshot 'catalogs'
        if (-not (& $isArray $catalogs)) {
            & $add 'catalogs' 'Must be an array.'
            $catalogs = @()
        }
        for ($i = 0; $i -lt $catalogs.Count; $i++) {
            $catalog = $catalogs[$i]
            $uid = Get-CcbValue $catalog 'uid'
            if (-not (& $isInteger $uid)) { & $add "catalogs[$i].uid" 'UID must be an integer.' }
            elseif ($catalogUids.ContainsKey([long]$uid)) { & $add "catalogs[$i].uid" "Duplicate catalog UID $uid." }
            else { $catalogUids[[long]$uid] = $true }
            if (-not (& $isText (Get-CcbValue $catalog 'name'))) { & $add "catalogs[$i].name" 'Name is required.' }
            foreach ($field in $allowed.Keys | Sort-Object) {
                $value = Get-CcbValue $catalog $field
                if ($allowed[$field] -notcontains $value) {
                    & $add "catalogs[$i].$field" "Must be one of $($allowed[$field] -join ', '); found '$value'."
                }
            }
        }

        $ruleCheck = {
            param($Rule, $Path, [bool]$NeedsKind)
            if (-not (& $isText (Get-CcbValue $Rule 'name'))) { & $add "$Path.name" 'Rule name is required.' }
            if ($NeedsKind -and @('Entitlement', 'Assignment') -notcontains (Get-CcbValue $Rule 'kind')) {
                & $add "$Path.kind" 'Kind must be Entitlement or Assignment.'
            }
            foreach ($flag in 'enabled', 'includedUserFilterEnabled', 'excludedUserFilterEnabled') {
                if ((Get-CcbValue $Rule $flag) -isnot [bool]) { & $add "$Path.$flag" 'Must be true or false.' }
            }
            foreach ($list in 'includedUsers', 'excludedUsers') {
                if (-not (& $isArray (Get-CcbValue $Rule $list))) { & $add "$Path.$list" 'Must be an array of SIDs.' }
            }
        }

        $groupUids = @{}
        $groups = Get-CcbValue $Snapshot 'deliveryGroups'
        if (-not (& $isArray $groups)) {
            & $add 'deliveryGroups' 'Must be an array.'
            $groups = @()
        }
        for ($i = 0; $i -lt $groups.Count; $i++) {
            $group = $groups[$i]
            $uid = Get-CcbValue $group 'uid'
            if (-not (& $isInteger $uid)) { & $add "deliveryGroups[$i].uid" 'UID must be an integer.' }
            elseif ($groupUids.ContainsKey([long]$uid)) { & $add "deliveryGroups[$i].uid" "Duplicate delivery group UID $uid." }
            else { $groupUids[[long]$uid] = $true }
            if (-not (& $isText (Get-CcbValue $group 'name'))) { & $add "deliveryGroups[$i].name" 'Name is required.' }
            if (@('Shared', 'Private') -notcontains (Get-CcbValue $group 'desktopKind')) { & $add "deliveryGroups[$i].desktopKind" 'Must be Shared or Private.' }
            if ((Get-CcbValue $group 'enabled') -isnot [bool]) { & $add "deliveryGroups[$i].enabled" 'Must be true or false.' }
            foreach ($list in 'desktopRules', 'accessRules') {
                $rules = Get-CcbValue $group $list
                if (-not (& $isArray $rules)) { & $add "deliveryGroups[$i].$list" 'Must be an array.'; continue }
                for ($r = 0; $r -lt $rules.Count; $r++) {
                    & $ruleCheck $rules[$r] "deliveryGroups[$i].$list[$r]" ($list -eq 'desktopRules')
                }
            }
        }

        $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $machines = Get-CcbValue $Snapshot 'machines'
        if (-not (& $isArray $machines)) {
            & $add 'machines' 'Must be an array.'
            $machines = @()
        }
        for ($i = 0; $i -lt $machines.Count; $i++) {
            $machine = $machines[$i]
            $name = Get-CcbValue $machine 'name'
            if (-not (& $isText $name)) { & $add "machines[$i].name" 'Name is required.' }
            elseif (-not $names.Add($name)) { & $add "machines[$i].name" "Duplicate machine '$name'." }
            $catalogUid = Get-CcbValue $machine 'catalogUid'
            if (-not (& $isInteger $catalogUid) -or -not $catalogUids.ContainsKey([long]$catalogUid)) {
                & $add "machines[$i].catalogUid" "Unknown catalog UID '$catalogUid'."
            }
            $groupUid = Get-CcbValue $machine 'deliveryGroupUid'
            if ($null -ne $groupUid -and (-not (& $isInteger $groupUid) -or -not $groupUids.ContainsKey([long]$groupUid))) {
                & $add "machines[$i].deliveryGroupUid" "Unknown delivery group UID '$groupUid'."
            }
            if ((Get-CcbValue $machine 'inMaintenanceMode') -isnot [bool]) { & $add "machines[$i].inMaintenanceMode" 'Must be true or false.' }
            if (-not (& $isArray (Get-CcbValue $machine 'assignedUsers'))) { & $add "machines[$i].assignedUsers" 'Must be an array of SIDs.' }
            $last = Get-CcbValue $machine 'lastConnectionTime'
            if ($null -ne $last -and -not (& $isDate $last)) { & $add "machines[$i].lastConnectionTime" 'Must be null or an ISO 8601 date.' }
            $software = Get-CcbValue $machine 'software'
            if ($null -ne $software) {
                if (-not (& $isArray $software)) { & $add "machines[$i].software" 'Must be null or an array.' }
                else {
                    for ($s = 0; $s -lt $software.Count; $s++) {
                        if (-not (& $isText (Get-CcbValue $software[$s] 'name'))) { & $add "machines[$i].software[$s].name" 'Name is required.' }
                    }
                }
            }
        }

        if ($Assert -and $problems.Count -gt 0) {
            $first = $problems | Select-Object -First 5 | ForEach-Object { "$($_.Path): $($_.Message)" }
            throw "The snapshot is not valid ($($problems.Count) problem(s)): $($first -join ' ')"
        }
        if (-not $Assert) { $problems.ToArray() }
    }
}
