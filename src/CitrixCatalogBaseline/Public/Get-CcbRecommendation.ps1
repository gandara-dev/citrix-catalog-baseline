function Get-CcbRecommendation {
    <#
    .SYNOPSIS
    Runs the deterministic recommendation rules on a snapshot.

    .DESCRIPTION
    Every recommendation carries a rule ID, a severity, the affected catalogs,
    a suggested action, and the evidence rows that triggered it. The rules
    never change the site; they only point at data worth reviewing. See
    docs/recommendations.md for each rule.

    .EXAMPLE
    New-CcbSyntheticSnapshot | Get-CcbRecommendation | Format-Table Id, Severity, Title
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        $Snapshot,

        # Access entries from Resolve-CcbAccess; resolved again when omitted.
        [object[]]$Access,

        # VDAs older than this version are reported (1912 LTSR reached end of life).
        [string]$MinimumVdaVersion = '2203',

        # Private desktops without a connection for this many days are reported.
        [ValidateRange(1, 3650)]
        [int]$UnusedDays = 60,

        # Two catalogs are consolidation candidates when the software they share,
        # divided by all the software either one has (Jaccard similarity),
        # reaches this value.
        [ValidateRange(0.1, 1.0)]
        [double]$OverlapThreshold = 0.8,

        # Access paths with more nested group levels than this are reported.
        [ValidateRange(0, 20)]
        [int]$MaxNestingDepth = 3
    )

    process {
        Test-CcbSnapshot -Snapshot $Snapshot -Assert
        if (-not $PSBoundParameters.ContainsKey('Access')) { $Access = @(Resolve-CcbAccess -Snapshot $Snapshot) }
        $index = New-CcbDirectoryIndex $Snapshot
        $collectedAt = ConvertTo-CcbDate (Get-CcbValue (Get-CcbValue $Snapshot 'site') 'collectedAt')

        $catalogs = @(Get-CcbList $Snapshot 'catalogs' | Sort-Object { Get-CcbValue $_ 'name' })
        $catalogName = @{}
        foreach ($catalog in $catalogs) { $catalogName[[long](Get-CcbValue $catalog 'uid')] = Get-CcbValue $catalog 'name' }
        $groupsByUid = @{}
        foreach ($group in Get-CcbList $Snapshot 'deliveryGroups') { $groupsByUid[[long](Get-CcbValue $group 'uid')] = $group }
        $machines = @(Get-CcbList $Snapshot 'machines' | Sort-Object { Get-CcbValue $_ 'name' })
        $machinesByCatalog = @{}
        foreach ($catalog in $catalogs) { $machinesByCatalog[[long](Get-CcbValue $catalog 'uid')] = [System.Collections.Generic.List[object]]::new() }
        foreach ($machine in $machines) { $machinesByCatalog[[long](Get-CcbValue $machine 'catalogUid')].Add($machine) }

        # Software per catalog: app name -> version -> machine count.
        $softwareByCatalog = @{}
        foreach ($uid in $machinesByCatalog.Keys) {
            $apps = @{}
            foreach ($machine in $machinesByCatalog[$uid]) {
                foreach ($item in Get-CcbList $machine 'software') {
                    $name = Get-CcbValue $item 'name'
                    $version = [string](Get-CcbValue $item 'version' '')
                    if (-not $apps.ContainsKey($name)) { $apps[$name] = @{} }
                    $apps[$name][$version] = 1 + [int]$apps[$name][$version]
                }
            }
            $softwareByCatalog[$uid] = $apps
        }

        $results = [System.Collections.Generic.List[object]]::new()
        $emit = {
            param([string]$Id, [string]$Rule, [string]$Severity, [string]$Title, [string]$Action, [long[]]$CatalogUids, [object[]]$Evidence)
            $results.Add([pscustomobject]@{
                Id = $Id
                Rule = $Rule
                Severity = $Severity
                Title = $Title
                Action = $Action
                CatalogUids = @($CatalogUids | Sort-Object -Unique)
                Evidence = @($Evidence)
            })
        }
        $row = { param([hashtable]$Values) $ordered = [ordered]@{}; foreach ($key in $Values.Keys | Sort-Object) { $ordered[$key] = $Values[$key] }; [pscustomobject]$ordered }

        # CCB001 - disabled accounts that can still start a desktop.
        $disabled = @($Access | Where-Object { $_.Status -eq 'Granted' -and $_.UserEnabled -eq $false } | Sort-Object UserName, DeliveryGroupName)
        if ($disabled.Count) {
            & $emit 'CCB001' 'DisabledAccountWithAccess' 'High' `
                "$(@($disabled.UserSid | Sort-Object -Unique).Count) disabled account(s) still reach a desktop" `
                'Remove the accounts from the groups and machine assignments below, or confirm they are expected to return.' `
                @($disabled | ForEach-Object { $_.CatalogUids }) `
                @($disabled | ForEach-Object { & $row @{ user = $_.UserName; deliveryGroup = $_.DeliveryGroupName; path = ($_.Path -join ' > '); machine = $_.AssignedMachine } })
        }

        # CCB002 - users named directly in a desktop rule instead of through a group.
        $direct = @($Access | Where-Object DirectUser | Sort-Object DeliveryGroupName, UserName)
        if ($direct.Count) {
            & $emit 'CCB002' 'DirectUserEntitlement' 'Medium' `
                "$($direct.Count) user(s) are entitled directly instead of through a group" `
                'Grant access through an AD group so membership stays auditable in one place.' `
                @($direct | ForEach-Object { $_.CatalogUids }) `
                @($direct | ForEach-Object { & $row @{ user = $_.UserName; deliveryGroup = $_.DeliveryGroupName; rule = $_.DesktopRule } })
        }

        # CCB003 - pairs of catalogs that share users and most of their software.
        $usersByCatalog = @{}
        foreach ($entry in $Access | Where-Object Status -eq 'Granted') {
            foreach ($uid in $entry.CatalogUids) {
                if (-not $usersByCatalog.ContainsKey($uid)) { $usersByCatalog[$uid] = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
                [void]$usersByCatalog[$uid].Add($entry.UserName)
            }
        }
        $inventoried = @($catalogs | Where-Object { $softwareByCatalog[[long](Get-CcbValue $_ 'uid')].Count -gt 0 })
        for ($i = 0; $i -lt $inventoried.Count; $i++) {
            for ($j = $i + 1; $j -lt $inventoried.Count; $j++) {
                $uidA = [long](Get-CcbValue $inventoried[$i] 'uid')
                $uidB = [long](Get-CcbValue $inventoried[$j] 'uid')
                if (-not $usersByCatalog.ContainsKey($uidA) -or -not $usersByCatalog.ContainsKey($uidB)) { continue }
                $shared = @($usersByCatalog[$uidA] | Where-Object { $usersByCatalog[$uidB].Contains($_) })
                if (-not $shared.Count) { continue }
                $appsA = @($softwareByCatalog[$uidA].Keys)
                $appsB = @($softwareByCatalog[$uidB].Keys)
                $common = @($appsA | Where-Object { $appsB -contains $_ })
                $union = @($appsA + $appsB | Sort-Object -Unique)
                $overlap = $common.Count / $union.Count
                if ($overlap -lt $OverlapThreshold) { continue }
                $percent = [Math]::Round($overlap * 100)
                $onlyA = @($appsA | Where-Object { $appsB -notcontains $_ } | Sort-Object)
                $onlyB = @($appsB | Where-Object { $appsA -notcontains $_ } | Sort-Object)
                & $emit 'CCB003' 'OverlappingCatalogs' 'Low' `
                    "$($shared.Count) user(s) can use both $($catalogName[$uidA]) and $($catalogName[$uidB]), which share $percent% of their software" `
                    "Check whether these users need both desktops. Only in $($catalogName[$uidA]): $(if ($onlyA) { $onlyA -join ', ' } else { 'nothing' }). Only in $($catalogName[$uidB]): $(if ($onlyB) { $onlyB -join ', ' } else { 'nothing' })." `
                    @($uidA, $uidB) `
                    @($shared | ForEach-Object { & $row @{ user = $_ } })
            }
        }

        # CCB004 - the same application at different versions across catalogs.
        $allApps = @($softwareByCatalog.Values | ForEach-Object { $_.Keys } | Sort-Object -Unique)
        foreach ($app in $allApps) {
            $found = @($catalogs | Where-Object { $softwareByCatalog[[long](Get-CcbValue $_ 'uid')].ContainsKey($app) })
            if ($found.Count -lt 2) { continue }
            $versions = @($found | ForEach-Object { $softwareByCatalog[[long](Get-CcbValue $_ 'uid')][$app].Keys } | Sort-Object -Unique)
            if ($versions.Count -lt 2) { continue }
            $newest = $versions[0]
            foreach ($version in $versions) { if ((Compare-CcbVersion $version $newest) -gt 0) { $newest = $version } }
            $evidence = foreach ($catalog in $found) {
                $uid = [long](Get-CcbValue $catalog 'uid')
                foreach ($version in $softwareByCatalog[$uid][$app].Keys | Sort-Object) {
                    & $row @{ catalog = $catalogName[$uid]; version = $version; machines = $softwareByCatalog[$uid][$app][$version]; newest = ($version -eq $newest) }
                }
            }
            & $emit 'CCB004' 'VersionDriftAcrossCatalogs' 'Medium' `
                "$app runs $($versions.Count) different versions across $($found.Count) catalogs" `
                "Align the images on $newest or record why a catalog must stay behind." `
                @($found | ForEach-Object { [long](Get-CcbValue $_ 'uid') }) `
                @($evidence)
        }

        # CCB005 - persistent machines whose software drifted from the rest of the catalog.
        foreach ($catalog in $catalogs) {
            $uid = [long](Get-CcbValue $catalog 'uid')
            $persistent = (Get-CcbValue $catalog 'allocationType') -eq 'Static' -or (Get-CcbValue $catalog 'persistUserChanges') -ne 'Discard'
            $sampled = @($machinesByCatalog[$uid] | Where-Object { $null -ne (Get-CcbValue $_ 'software') })
            if (-not $persistent -or $sampled.Count -lt 3) { continue }
            $half = $sampled.Count / 2
            $expected = @{}
            foreach ($app in $softwareByCatalog[$uid].Keys) {
                $counts = $softwareByCatalog[$uid][$app]
                $total = ($counts.Values | Measure-Object -Sum).Sum
                if ($total -le $half) { continue }
                $expected[$app] = ($counts.GetEnumerator() | Sort-Object @{ Expression = 'Value'; Descending = $true }, @{ Expression = 'Key' } | Select-Object -First 1).Key
            }
            $evidence = [System.Collections.Generic.List[object]]::new()
            foreach ($machine in $sampled) {
                $installed = @{}
                foreach ($item in Get-CcbList $machine 'software') { $installed[(Get-CcbValue $item 'name')] = [string](Get-CcbValue $item 'version' '') }
                foreach ($app in $expected.Keys | Sort-Object) {
                    if (-not $installed.ContainsKey($app)) {
                        $evidence.Add((& $row @{ machine = Get-CcbValue $machine 'name'; difference = 'Missing'; application = $app; found = $null; expected = $expected[$app] }))
                    }
                    elseif ($installed[$app] -ne $expected[$app]) {
                        $evidence.Add((& $row @{ machine = Get-CcbValue $machine 'name'; difference = 'Version'; application = $app; found = $installed[$app]; expected = $expected[$app] }))
                    }
                }
                foreach ($app in $installed.Keys | Sort-Object) {
                    if (-not $expected.ContainsKey($app)) {
                        $evidence.Add((& $row @{ machine = Get-CcbValue $machine 'name'; difference = 'Extra'; application = $app; found = $installed[$app]; expected = $null }))
                    }
                }
            }
            if ($evidence.Count) {
                $drifted = @($evidence | ForEach-Object machine | Sort-Object -Unique).Count
                & $emit 'CCB005' 'DriftInsidePersistentCatalog' 'Medium' `
                    "$drifted of $($sampled.Count) machines in $($catalogName[$uid]) differ from the rest of the catalog" `
                    'Persistent machines do not reset at logoff. Bring them back to the catalog baseline or document the exception.' `
                    @($uid) @($evidence)
            }
        }

        # CCB006 - VDAs older than the supported minimum.
        foreach ($catalog in $catalogs) {
            $uid = [long](Get-CcbValue $catalog 'uid')
            $old = @($machinesByCatalog[$uid] | Where-Object {
                    $agent = Get-CcbValue $_ 'agentVersion'
                    $agent -and (Compare-CcbVersion $agent $MinimumVdaVersion) -lt 0
                })
            if ($old.Count) {
                & $emit 'CCB006' 'UnsupportedVda' 'High' `
                    "$($old.Count) machine(s) in $($catalogName[$uid]) run a VDA older than $MinimumVdaVersion" `
                    'Upgrade the VDA (for MCS, in the master image) to a supported LTSR or current release.' `
                    @($uid) @($old | ForEach-Object { & $row @{ machine = Get-CcbValue $_ 'name'; agentVersion = Get-CcbValue $_ 'agentVersion' } })
            }
        }

        # CCB007 / CCB008 - machines outside any delivery group, and empty catalogs.
        foreach ($catalog in $catalogs) {
            $uid = [long](Get-CcbValue $catalog 'uid')
            $all = @($machinesByCatalog[$uid])
            if (-not $all.Count) {
                & $emit 'CCB008' 'EmptyCatalog' 'Low' "$($catalogName[$uid]) has no machines" `
                    'Delete the catalog if it is no longer planned, or record its purpose.' @($uid) @()
                continue
            }
            $loose = @($all | Where-Object { $null -eq (Get-CcbValue $_ 'deliveryGroupUid') })
            if ($loose.Count) {
                $title = if ($loose.Count -eq $all.Count) { "$($catalogName[$uid]) is not used by any delivery group" }
                else { "$($loose.Count) machine(s) in $($catalogName[$uid]) are not in a delivery group" }
                & $emit 'CCB007' 'MachinesWithoutDeliveryGroup' 'Low' $title `
                    'These machines consume resources and licenses but no user can reach them. Add them to a delivery group or remove them.' `
                    @($uid) @($loose | ForEach-Object { & $row @{ machine = Get-CcbValue $_ 'name'; agentVersion = Get-CcbValue $_ 'agentVersion'; lastConnection = Format-CcbDate (Get-CcbValue $_ 'lastConnectionTime') } })
            }
        }

        # CCB009 - private desktops nobody has used recently.
        $unused = foreach ($machine in $machines) {
            $groupUid = Get-CcbValue $machine 'deliveryGroupUid'
            if ($null -eq $groupUid -or (Get-CcbValue $groupsByUid[[long]$groupUid] 'desktopKind') -ne 'Private') { continue }
            $assigned = @(Get-CcbList $machine 'assignedUsers')
            if (-not $assigned.Count) { continue }
            $last = ConvertTo-CcbDate (Get-CcbValue $machine 'lastConnectionTime')
            $days = if ($null -eq $last) { $null } else { [int][Math]::Floor(($collectedAt - $last).TotalDays) }
            if ($null -ne $days -and $days -lt $UnusedDays) { continue }
            [pscustomobject]@{ Machine = $machine; Days = $days; Assigned = $assigned }
        }
        $unused = @($unused)
        if ($unused.Count) {
            & $emit 'CCB009' 'UnusedPrivateDesktop' 'Low' `
                "$($unused.Count) private desktop(s) have not been used for $UnusedDays days or more" `
                'Confirm with the owners and reclaim the machines and their licenses.' `
                @($unused | ForEach-Object { [long](Get-CcbValue $_.Machine 'catalogUid') }) `
                @($unused | ForEach-Object {
                        & $row @{
                            machine = Get-CcbValue $_.Machine 'name'
                            assignedTo = (@($_.Assigned | ForEach-Object { Get-CcbPrincipalName $index $_ }) -join ', ')
                            lastConnection = Format-CcbDate (Get-CcbValue $_.Machine 'lastConnectionTime')
                            daysIdle = $_.Days
                        }
                    })
        }

        # CCB010 - access that depends on deeply nested groups.
        $deep = @($Access | Where-Object { $_.NestingDepth -gt $MaxNestingDepth })
        if ($deep.Count) {
            $paths = $deep | Group-Object { (@($_.Path | Select-Object -Skip 1) -join ' > ') + '|' + $_.DeliveryGroupName } | Sort-Object Name
            & $emit 'CCB010' 'DeepGroupNesting' 'Low' `
                "$(@($deep.UserSid | Sort-Object -Unique).Count) user(s) reach a desktop through more than $MaxNestingDepth levels of nested groups" `
                'Deep nesting makes access reviews hard to follow. Entitle a flatter group closer to the users.' `
                @($deep | ForEach-Object { $_.CatalogUids }) `
                @($paths | ForEach-Object {
                        $first = $_.Group[0]
                        & $row @{ groupPath = (@($first.Path | Select-Object -Skip 1) -join ' > '); deliveryGroup = $first.DeliveryGroupName; users = $_.Count; levels = $first.NestingDepth }
                    })
        }

        # CCB011 - circular group nesting.
        $cycles = Find-CcbGroupCycle -Index $index
        if ($cycles.Count) {
            & $emit 'CCB011' 'CircularGroupNesting' 'Medium' `
                "$($cycles.Count) group cycle(s) found in the directory" `
                'Break the cycle. Circular nesting is legal in Active Directory but hides who is really a member.' `
                @() @(foreach ($cycle in $cycles) {
                        $names = foreach ($sid in @($cycle) + @($cycle[0])) { Get-CcbPrincipalName $index $sid }
                        & $row @{ cycle = ($names -join ' > ') }
                    })
        }

        # CCB012 - desktop granted, connection refused by the access policy.
        $blocked = @($Access | Where-Object Status -eq 'BlockedByAccessPolicy' | Sort-Object DeliveryGroupName, UserName)
        if ($blocked.Count) {
            & $emit 'CCB012' 'BlockedByAccessPolicy' 'Info' `
                "$($blocked.Count) user(s) are granted a desktop but blocked by the access policy" `
                'Usually intended (for example contractors excluded from a group). Confirm, or remove them from the desktop rule so the two rules agree.' `
                @($blocked | ForEach-Object { $_.CatalogUids }) `
                @($blocked | ForEach-Object { & $row @{ user = $_.UserName; deliveryGroup = $_.DeliveryGroupName; desktopRule = $_.DesktopRule; path = ($_.Path -join ' > ') } })
        }

        # CCB013 - entitlements left on a disabled delivery group.
        $disabledGroups = @($Access | Where-Object Status -eq 'DeliveryGroupDisabled' | Group-Object DeliveryGroupName | Sort-Object Name)
        foreach ($group in $disabledGroups) {
            & $emit 'CCB013' 'DisabledDeliveryGroup' 'Info' `
                "$($group.Name) is disabled but still entitles $($group.Count) user(s)" `
                'Remove the delivery group, or its rules, once the retirement is confirmed.' `
                @($group.Group | ForEach-Object { $_.CatalogUids }) `
                @($group.Group | Sort-Object UserName | ForEach-Object { & $row @{ user = $_.UserName; path = ($_.Path -join ' > ') } })
        }

        $order = @{ High = 0; Medium = 1; Low = 2; Info = 3 }
        $results | Sort-Object @{ Expression = { $order[$_.Severity] } }, Id, Title
    }
}
