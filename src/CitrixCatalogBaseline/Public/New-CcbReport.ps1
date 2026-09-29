function New-CcbReport {
    <#
    .SYNOPSIS
    Builds the review report that the page reads.

    .DESCRIPTION
    Combines the snapshot, the resolved access, and the recommendations into
    one document: catalogs with their machines, software, VDA versions, and
    access paths; delivery groups and their rules; users and what they reach;
    and the recommendations with evidence. Serialize it with
    ConvertTo-Json -Depth 20 and open the file in the review page.

    .EXAMPLE
    New-CcbSyntheticSnapshot | New-CcbReport | ConvertTo-Json -Depth 20 | Set-Content ./report.json
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object in memory; changes no system state.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        $Snapshot,

        [string]$MinimumVdaVersion = '2203',

        [ValidateRange(1, 3650)]
        [int]$UnusedDays = 60,

        [ValidateRange(0.1, 1.0)]
        [double]$OverlapThreshold = 0.8,

        [ValidateRange(0, 20)]
        [int]$MaxNestingDepth = 3,

        [string]$CatalogNamePattern,
        [string]$DeliveryGroupNamePattern,
        [string]$MachineNamePattern,

        # Report timestamp. Defaults to the snapshot collection time so the same
        # snapshot always produces the same report.
        [Nullable[DateTimeOffset]]$GeneratedAt
    )

    process {
        Test-CcbSnapshot -Snapshot $Snapshot -Assert
        $index = New-CcbDirectoryIndex $Snapshot
        $site = Get-CcbValue $Snapshot 'site'
        $access = @(Resolve-CcbAccess -Snapshot $Snapshot)
        $settings = @{
            MinimumVdaVersion = $MinimumVdaVersion
            UnusedDays = $UnusedDays
            OverlapThreshold = $OverlapThreshold
            MaxNestingDepth = $MaxNestingDepth
            CatalogNamePattern = $CatalogNamePattern
            DeliveryGroupNamePattern = $DeliveryGroupNamePattern
            MachineNamePattern = $MachineNamePattern
        }
        $recommendations = @(Get-CcbRecommendation -Snapshot $Snapshot -Access $access @settings)

        $catalogs = @(Get-CcbList $Snapshot 'catalogs' | Sort-Object { Get-CcbValue $_ 'name' })
        $deliveryGroups = @(Get-CcbList $Snapshot 'deliveryGroups' | Sort-Object { Get-CcbValue $_ 'name' })
        $machines = @(Get-CcbList $Snapshot 'machines' | Sort-Object { Get-CcbValue $_ 'name' })
        $catalogName = @{}
        foreach ($catalog in $catalogs) { $catalogName[[long](Get-CcbValue $catalog 'uid')] = Get-CcbValue $catalog 'name' }
        $groupName = @{}
        foreach ($group in $deliveryGroups) { $groupName[[long](Get-CcbValue $group 'uid')] = Get-CcbValue $group 'name' }
        $names = { param($Sids) @($Sids | ForEach-Object { Get-CcbPrincipalName $index $_ }) }

        $catalogReports = foreach ($catalog in $catalogs) {
            $uid = [long](Get-CcbValue $catalog 'uid')
            $members = @($machines | Where-Object { [long](Get-CcbValue $_ 'catalogUid') -eq $uid })
            $inventoried = @($members | Where-Object { $null -ne (Get-CcbValue $_ 'software') })

            $apps = @{}
            foreach ($machine in $inventoried) {
                foreach ($item in Get-CcbList $machine 'software') {
                    $name = Get-CcbValue $item 'name'
                    if (-not $apps.ContainsKey($name)) { $apps[$name] = @{ Publisher = Get-CcbValue $item 'publisher'; Versions = @{} } }
                    $version = [string](Get-CcbValue $item 'version' '')
                    $apps[$name].Versions[$version] = 1 + [int]$apps[$name].Versions[$version]
                }
            }
            $software = foreach ($name in $apps.Keys | Sort-Object) {
                [ordered]@{
                    name = $name
                    publisher = $apps[$name].Publisher
                    versions = @($apps[$name].Versions.Keys | Sort-Object | ForEach-Object { [ordered]@{ version = $_; machines = $apps[$name].Versions[$_] } })
                }
            }

            $agents = $members | Group-Object { [string](Get-CcbValue $_ 'agentVersion' '') } | Sort-Object Name
            $groupUids = @($members | ForEach-Object { Get-CcbValue $_ 'deliveryGroupUid' } | Where-Object { $null -ne $_ } | ForEach-Object { [long]$_ } | Sort-Object -Unique)
            $entries = @($access | Where-Object { $_.CatalogUids -contains $uid } | Sort-Object UserName, DeliveryGroupName)

            [ordered]@{
                uid = $uid
                name = $catalogName[$uid]
                provisioningType = Get-CcbValue $catalog 'provisioningType'
                allocationType = Get-CcbValue $catalog 'allocationType'
                persistUserChanges = Get-CcbValue $catalog 'persistUserChanges'
                sessionSupport = Get-CcbValue $catalog 'sessionSupport'
                persistent = (Get-CcbValue $catalog 'allocationType') -eq 'Static' -or (Get-CcbValue $catalog 'persistUserChanges') -ne 'Discard'
                machineCount = $members.Count
                inventoriedMachines = $inventoried.Count
                deliveryGroups = @($groupUids | ForEach-Object { $groupName[$_] })
                vdaVersions = @($agents | ForEach-Object { [ordered]@{ version = $(if ($_.Name) { $_.Name } else { $null }); machines = $_.Count } })
                software = @($software)
                access = @($entries | ForEach-Object {
                        [ordered]@{
                            user = $_.UserName
                            displayName = $_.DisplayName
                            enabled = $_.UserEnabled
                            deliveryGroup = $_.DeliveryGroupName
                            status = $_.Status
                            grantedBy = $_.GrantedBy
                            desktopRule = $_.DesktopRule
                            accessRule = $_.AccessRule
                            path = @($_.Path)
                            machine = $_.AssignedMachine
                        }
                    })
            }
        }

        $ruleReport = {
            param($Rule)
            $result = [ordered]@{ name = Get-CcbValue $Rule 'name' }
            $kind = Get-CcbValue $Rule 'kind'
            if ($kind) { $result.kind = $kind }
            $result.enabled = [bool](Get-CcbValue $Rule 'enabled')
            $result.includedUsers = if ([bool](Get-CcbValue $Rule 'includedUserFilterEnabled')) { @(& $names (Get-CcbList $Rule 'includedUsers')) } else { @('(all users)') }
            $result.excludedUsers = if ([bool](Get-CcbValue $Rule 'excludedUserFilterEnabled')) { @(& $names (Get-CcbList $Rule 'excludedUsers')) } else { @() }
            return $result
        }
        $groupReports = foreach ($group in $deliveryGroups) {
            $uid = [long](Get-CcbValue $group 'uid')
            $catalogUids = @($machines | Where-Object { $null -ne (Get-CcbValue $_ 'deliveryGroupUid') -and [long](Get-CcbValue $_ 'deliveryGroupUid') -eq $uid } |
                    ForEach-Object { [long](Get-CcbValue $_ 'catalogUid') } | Sort-Object -Unique)
            [ordered]@{
                uid = $uid
                name = $groupName[$uid]
                desktopKind = Get-CcbValue $group 'desktopKind'
                enabled = [bool](Get-CcbValue $group 'enabled')
                catalogs = @($catalogUids | ForEach-Object { $catalogName[$_] })
                machineCount = @($machines | Where-Object { $null -ne (Get-CcbValue $_ 'deliveryGroupUid') -and [long](Get-CcbValue $_ 'deliveryGroupUid') -eq $uid }).Count
                grantedUsers = @($access | Where-Object { $_.DeliveryGroupUid -eq $uid -and $_.Status -eq 'Granted' }).Count
                desktopRules = @(Get-CcbList $group 'desktopRules' | Sort-Object { Get-CcbValue $_ 'name' } | ForEach-Object { & $ruleReport $_ })
                accessRules = @(Get-CcbList $group 'accessRules' | Sort-Object { Get-CcbValue $_ 'name' } | ForEach-Object { & $ruleReport $_ })
            }
        }

        $machineReports = foreach ($machine in $machines) {
            $groupUid = Get-CcbValue $machine 'deliveryGroupUid'
            $software = Get-CcbValue $machine 'software'
            [ordered]@{
                name = Get-CcbValue $machine 'name'
                catalog = $catalogName[[long](Get-CcbValue $machine 'catalogUid')]
                deliveryGroup = if ($null -ne $groupUid) { $groupName[[long]$groupUid] } else { $null }
                agentVersion = Get-CcbValue $machine 'agentVersion'
                osType = Get-CcbValue $machine 'osType'
                registrationState = Get-CcbValue $machine 'registrationState'
                inMaintenanceMode = [bool](Get-CcbValue $machine 'inMaintenanceMode')
                assignedTo = @(& $names (Get-CcbList $machine 'assignedUsers'))
                lastConnectionTime = Format-CcbDate (Get-CcbValue $machine 'lastConnectionTime')
                softwareCount = if ($null -ne $software) { @($software).Count } else { $null }
            }
        }

        $userReports = foreach ($user in $access | Group-Object UserSid | Sort-Object { $_.Group[0].UserName }) {
            $first = $user.Group[0]
            $granted = @($user.Group | Where-Object Status -eq 'Granted')
            [ordered]@{
                name = $first.UserName
                displayName = $first.DisplayName
                enabled = $first.UserEnabled
                known = $first.UserKnown
                catalogs = @($granted | ForEach-Object { $_.CatalogUids } | Sort-Object -Unique | ForEach-Object { $catalogName[[long]$_] })
                deliveryGroups = @($granted | ForEach-Object DeliveryGroupName | Sort-Object -Unique)
                blocked = @($user.Group | Where-Object Status -ne 'Granted' | ForEach-Object { [ordered]@{ deliveryGroup = $_.DeliveryGroupName; status = $_.Status } })
            }
        }

        $severityCount = [ordered]@{}
        foreach ($severity in 'High', 'Medium', 'Low', 'Info') { $severityCount[$severity] = @($recommendations | Where-Object Severity -eq $severity).Count }
        $generated = if ($null -ne $GeneratedAt) { Format-CcbDate $GeneratedAt } else { Format-CcbDate (Get-CcbValue $site 'collectedAt') }

        [ordered]@{
            kind = 'citrix-catalog-baseline-report'
            schemaVersion = $script:SchemaVersion
            generatorVersion = $script:ModuleVersion
            generatedAt = $generated
            site = [ordered]@{
                name = Get-CcbValue $site 'name'
                collectedAt = Format-CcbDate (Get-CcbValue $site 'collectedAt')
                source = Get-CcbValue $site 'source'
                pseudonymized = [bool](Get-CcbValue $site 'pseudonymized' $false)
            }
            settings = [ordered]@{
                minimumVdaVersion = $MinimumVdaVersion
                unusedDays = $UnusedDays
                overlapThreshold = $OverlapThreshold
                maxNestingDepth = $MaxNestingDepth
                namingConvention = [ordered]@{
                    catalog = if ($CatalogNamePattern) { $CatalogNamePattern } else { $null }
                    deliveryGroup = if ($DeliveryGroupNamePattern) { $DeliveryGroupNamePattern } else { $null }
                    machine = if ($MachineNamePattern) { $MachineNamePattern } else { $null }
                }
            }
            summary = [ordered]@{
                catalogs = $catalogs.Count
                deliveryGroups = $deliveryGroups.Count
                machines = $machines.Count
                usersWithAccess = @($userReports | Where-Object { $_.catalogs.Count -gt 0 }).Count
                recommendations = $severityCount
            }
            catalogs = @($catalogReports)
            deliveryGroups = @($groupReports)
            machines = @($machineReports)
            users = @($userReports)
            recommendations = @($recommendations | ForEach-Object {
                    [ordered]@{
                        id = $_.Id
                        rule = $_.Rule
                        severity = $_.Severity
                        title = $_.Title
                        action = $_.Action
                        catalogs = @($_.CatalogUids | ForEach-Object { $catalogName[[long]$_] })
                        evidence = @($_.Evidence)
                    }
                })
        }
    }
}
