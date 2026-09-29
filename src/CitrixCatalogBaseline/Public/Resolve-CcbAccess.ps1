function Resolve-CcbAccess {
    <#
    .SYNOPSIS
    Resolves which users can reach each delivery group, and through which path.

    .DESCRIPTION
    Follows the Citrix on-premises model. A user reaches a delivery group when
    a desktop rule grants a desktop (an entitlement rule for shared desktops;
    an assignment rule or a direct machine assignment for private desktops) and
    an access policy rule allows the connection. Each rule matches through its
    included users, minus its excluded users; a rule whose included-user filter
    is disabled matches every user. Group membership is expanded through
    nested groups, and the shortest membership chain is reported as the path.

    Returns one object per user and delivery group where a desktop is granted,
    with Status Granted, BlockedByAccessPolicy, or DeliveryGroupDisabled.

    .EXAMPLE
    New-CcbSyntheticSnapshot | Resolve-CcbAccess | Where-Object Status -eq 'Granted'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        $Snapshot
    )

    process {
        Test-CcbSnapshot -Snapshot $Snapshot -Assert
        $index = New-CcbDirectoryIndex $Snapshot

        $catalogsByGroup = @{}
        $assignedByGroup = @{}
        foreach ($machine in Get-CcbList $Snapshot 'machines') {
            $groupUid = Get-CcbValue $machine 'deliveryGroupUid'
            if ($null -eq $groupUid) { continue }
            $groupUid = [long]$groupUid
            if (-not $catalogsByGroup.ContainsKey($groupUid)) {
                $catalogsByGroup[$groupUid] = [System.Collections.Generic.SortedSet[long]]::new()
                $assignedByGroup[$groupUid] = @{}
            }
            [void]$catalogsByGroup[$groupUid].Add([long](Get-CcbValue $machine 'catalogUid'))
            foreach ($sid in Get-CcbList $machine 'assignedUsers') {
                $assignedByGroup[$groupUid][$sid] = Get-CcbValue $machine 'name'
            }
        }

        # Users come from the directory; machine assignments can name users the
        # directory export did not include, so those are added as unknown.
        $userSids = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($principal in $index.Principals.Values) {
            if ($principal.Kind -eq 'User') { [void]$userSids.Add($principal.Sid) }
        }
        foreach ($assignments in $assignedByGroup.Values) {
            foreach ($sid in $assignments.Keys) {
                if (-not $index.Principals.ContainsKey($sid)) { [void]$userSids.Add($sid) }
            }
        }

        $matchRule = {
            param($Rule, $Chains)
            if (-not [bool](Get-CcbValue $Rule 'enabled')) { return $null }
            if ([bool](Get-CcbValue $Rule 'excludedUserFilterEnabled')) {
                foreach ($excluded in Get-CcbList $Rule 'excludedUsers') {
                    if ($Chains.ContainsKey($excluded)) { return $null }
                }
            }
            if (-not [bool](Get-CcbValue $Rule 'includedUserFilterEnabled')) {
                return [pscustomobject]@{ Chain = @($Chains.Keys | Where-Object { $Chains[$_].Count -eq 1 }); Everyone = $true }
            }
            $best = $null
            foreach ($included in Get-CcbList $Rule 'includedUsers' | Sort-Object) {
                if (-not $Chains.ContainsKey($included)) { continue }
                $chain = $Chains[$included]
                if ($null -eq $best -or $chain.Count -lt $best.Count) { $best = $chain }
            }
            if ($null -eq $best) { return $null }
            return [pscustomobject]@{ Chain = @($best); Everyone = $false }
        }

        $deliveryGroups = @(Get-CcbList $Snapshot 'deliveryGroups' | Sort-Object { Get-CcbValue $_ 'name' })
        $results = [System.Collections.Generic.List[object]]::new()
        foreach ($userSid in $userSids) {
            $chains = Get-CcbMembershipChain -Index $index -UserSid $userSid
            $user = $index.Principals[$userSid]
            foreach ($group in $deliveryGroups) {
                $groupUid = [long](Get-CcbValue $group 'uid')
                $grant = $null
                $grantKind = $null
                $grantRule = $null

                foreach ($rule in Get-CcbList $group 'desktopRules' | Sort-Object { Get-CcbValue $_ 'name' }) {
                    $kind = Get-CcbValue $rule 'kind'
                    if ((Get-CcbValue $group 'desktopKind') -eq 'Shared' -and $kind -ne 'Entitlement') { continue }
                    if ((Get-CcbValue $group 'desktopKind') -eq 'Private' -and $kind -ne 'Assignment') { continue }
                    $match = & $matchRule $rule $chains
                    if ($null -ne $match -and ($null -eq $grant -or $match.Chain.Count -lt $grant.Chain.Count)) {
                        $grant = $match
                        $grantKind = "$kind rule"
                        $grantRule = Get-CcbValue $rule 'name'
                    }
                }

                $assignedMachine = $null
                if ((Get-CcbValue $group 'desktopKind') -eq 'Private' -and $assignedByGroup.ContainsKey($groupUid)) {
                    foreach ($sid in $assignedByGroup[$groupUid].Keys | Sort-Object) {
                        if ($chains.ContainsKey($sid)) {
                            $assignedMachine = $assignedByGroup[$groupUid][$sid]
                            if ($null -eq $grant) {
                                $grant = [pscustomobject]@{ Chain = @($chains[$sid]); Everyone = $false }
                                $grantKind = 'Machine assignment'
                                $grantRule = $assignedMachine
                            }
                            break
                        }
                    }
                }
                if ($null -eq $grant) { continue }

                $access = $null
                $accessRule = $null
                foreach ($rule in Get-CcbList $group 'accessRules' | Sort-Object { Get-CcbValue $_ 'name' }) {
                    $match = & $matchRule $rule $chains
                    if ($null -ne $match) {
                        $access = $match
                        $accessRule = Get-CcbValue $rule 'name'
                        break
                    }
                }

                $status = if (-not [bool](Get-CcbValue $group 'enabled')) { 'DeliveryGroupDisabled' }
                elseif ($null -eq $access) { 'BlockedByAccessPolicy' }
                else { 'Granted' }

                $pathNames = if ($grant.Everyone) { @((Get-CcbPrincipalName $index $userSid), '(all users)') }
                else { @($grant.Chain | ForEach-Object { Get-CcbPrincipalName $index $_ }) }

                $results.Add([pscustomobject]@{
                    UserSid = $userSid
                    UserName = if ($user) { $user.Name } else { $userSid }
                    DisplayName = if ($user) { $user.DisplayName } else { $null }
                    UserEnabled = if ($user) { $user.Enabled } else { $null }
                    UserKnown = [bool]$user
                    DeliveryGroupUid = $groupUid
                    DeliveryGroupName = Get-CcbValue $group 'name'
                    DesktopKind = Get-CcbValue $group 'desktopKind'
                    Status = $status
                    GrantedBy = $grantKind
                    DesktopRule = $grantRule
                    AccessRule = $accessRule
                    Path = $pathNames
                    PathSids = @($grant.Chain)
                    NestingDepth = [Math]::Max(0, @($grant.Chain).Count - 2)
                    DirectUser = (-not $grant.Everyone) -and @($grant.Chain).Count -eq 1 -and $grantKind -ne 'Machine assignment'
                    AssignedMachine = $assignedMachine
                    CatalogUids = if ($catalogsByGroup.ContainsKey($groupUid)) { @($catalogsByGroup[$groupUid]) } else { @() }
                })
            }
        }
        $results.ToArray()
    }
}
