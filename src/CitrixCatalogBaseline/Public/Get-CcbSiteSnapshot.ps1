function Get-CcbSiteSnapshot {
    <#
    .SYNOPSIS
    Collects a snapshot of an on-premises Citrix site with read-only calls.

    .DESCRIPTION
    Reads machine catalogs, delivery groups, machines, and the entitlement,
    assignment, and access policy rules through the Citrix Broker PowerShell
    SDK. Resolves the users and groups those rules name through the
    ActiveDirectory module, expanding nested groups. Optionally reads the
    installed software from the uninstall registry keys of the VDAs over
    PowerShell remoting: one registered machine per pooled catalog (they share
    one image) and every registered machine in persistent catalogs.

    Nothing is changed on the site. The snapshot stays on this machine; see
    docs/data-safety.md before sharing it, and consider Protect-CcbSnapshot.

    .EXAMPLE
    Get-CcbSiteSnapshot -AdminAddress ddc01.corp.example.test -Verbose | ConvertTo-Json -Depth 20 | Set-Content ./site.snapshot.json
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        # Delivery Controller to query. Defaults to the local Broker service.
        [string]$AdminAddress,

        [ValidateRange(1, 1000000)]
        [int]$MaxRecordCount = 100000,

        # Skip the software inventory (no remoting to the VDAs).
        [switch]$SkipSoftware,

        # Registered machines inventoried per pooled catalog.
        [ValidateRange(1, 100)]
        [int]$PooledSampleSize = 1,

        [pscredential]$Credential,

        [ValidateRange(1, 64)]
        [int]$ThrottleLimit = 16,

        # Domain controller for the ActiveDirectory cmdlets.
        [string]$Server
    )

    $brokerCommands = 'Get-BrokerCatalog', 'Get-BrokerDesktopGroup', 'Get-BrokerMachine',
    'Get-BrokerEntitlementPolicyRule', 'Get-BrokerAssignmentPolicyRule', 'Get-BrokerAccessPolicyRule'
    $missing = @($brokerCommands | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($missing.Count) {
        throw "The Citrix Broker PowerShell SDK is not available ($($missing -join ', ')). Run on a Delivery Controller or a machine with the Citrix PowerShell SDK installed."
    }
    $adCommands = 'Get-ADObject', 'Get-ADGroupMember', 'Get-ADDomain'
    $missing = @($adCommands | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($missing.Count) {
        throw "The ActiveDirectory module is not available ($($missing -join ', ')). Install the RSAT Active Directory tools."
    }

    $broker = @{ MaxRecordCount = $MaxRecordCount }
    if ($AdminAddress) { $broker.AdminAddress = $AdminAddress }
    $ad = @{}
    if ($Server) { $ad.Server = $Server }
    $collectedAt = [DateTimeOffset]::UtcNow
    $text = { param($Value) if ($null -eq $Value) { $null } else { [string]$Value } }
    $sidOf = { param($Principal) if ($Principal -is [string]) { $Principal } else { [string]$Principal.SID } }

    Write-Verbose 'Reading catalogs, delivery groups, and rules from the Broker service.'
    $catalogs = @(Get-BrokerCatalog @broker | Sort-Object Name | ForEach-Object {
            [ordered]@{
                uid = [long]$_.Uid
                name = [string]$_.Name
                provisioningType = & $text $_.ProvisioningType
                allocationType = & $text $_.AllocationType
                persistUserChanges = & $text $_.PersistUserChanges
                sessionSupport = & $text $_.SessionSupport
            }
        })

    $ruleRecord = {
        param($Rule, [string]$Kind)
        $record = [ordered]@{ name = [string]$Rule.Name }
        if ($Kind) { $record.kind = $Kind }
        $record.enabled = [bool]$Rule.Enabled
        $record.includedUserFilterEnabled = [bool]$Rule.IncludedUserFilterEnabled
        $record.includedUsers = @($Rule.IncludedUsers | ForEach-Object { & $sidOf $_ } | Where-Object { $_ })
        $record.excludedUserFilterEnabled = [bool]$Rule.ExcludedUserFilterEnabled
        $record.excludedUsers = @($Rule.ExcludedUsers | ForEach-Object { & $sidOf $_ } | Where-Object { $_ })
        return $record
    }
    $entitlements = @(Get-BrokerEntitlementPolicyRule @broker)
    $assignments = @(Get-BrokerAssignmentPolicyRule @broker)
    $accessRules = @(Get-BrokerAccessPolicyRule @broker)

    $deliveryGroups = @(Get-BrokerDesktopGroup @broker | Sort-Object Name | ForEach-Object {
            $uid = [long]$_.Uid
            [ordered]@{
                uid = $uid
                name = [string]$_.Name
                desktopKind = & $text $_.DesktopKind
                enabled = [bool]$_.Enabled
                desktopRules = @(
                    $entitlements | Where-Object { [long]$_.DesktopGroupUid -eq $uid } | Sort-Object Name | ForEach-Object { & $ruleRecord $_ 'Entitlement' }
                    $assignments | Where-Object { [long]$_.DesktopGroupUid -eq $uid } | Sort-Object Name | ForEach-Object { & $ruleRecord $_ 'Assignment' }
                )
                accessRules = @($accessRules | Where-Object { [long]$_.DesktopGroupUid -eq $uid } | Sort-Object Name | ForEach-Object { & $ruleRecord $_ $null })
            }
        })

    Write-Verbose 'Reading machines.'
    $brokerMachines = @(Get-BrokerMachine @broker | Sort-Object MachineName)

    # ------------------------------------------------------------ directory
    Write-Verbose 'Resolving users and groups in Active Directory.'
    $netbios = (Get-ADDomain @ad).NetBIOSName
    $pending = [System.Collections.Generic.Queue[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $enqueue = { param([string]$Sid) if ($Sid -and $seen.Add($Sid)) { $pending.Enqueue($Sid) } }
    foreach ($group in $deliveryGroups) {
        foreach ($rule in @($group.desktopRules) + @($group.accessRules)) {
            foreach ($sid in @($rule.includedUsers) + @($rule.excludedUsers)) { & $enqueue $sid }
        }
    }
    foreach ($machine in $brokerMachines) {
        foreach ($sid in @($machine.AssociatedUserSIDs)) { & $enqueue ([string]$sid) }
    }

    $users = [System.Collections.Generic.List[object]]::new()
    $groups = [System.Collections.Generic.List[object]]::new()
    while ($pending.Count -gt 0) {
        $sid = $pending.Dequeue()
        $object = Get-ADObject @ad -LDAPFilter "(objectSid=$sid)" -Properties objectClass, sAMAccountName, displayName, userAccountControl |
            Select-Object -First 1
        if ($null -eq $object) {
            Write-Warning "SID $sid is not in this domain (deleted, or from another forest); it is listed without members."
            $groups.Add([ordered]@{ sid = $sid; name = "(unresolved) $sid"; members = @() })
            continue
        }
        $name = "$netbios\$($object.sAMAccountName)"
        if ($object.objectClass -eq 'group') {
            $members = @()
            try {
                $members = @(Get-ADGroupMember @ad -Identity $sid | ForEach-Object { [string]$_.SID })
            }
            catch {
                Write-Warning "Could not list the members of $name`: $($_.Exception.Message)"
            }
            foreach ($member in $members) { & $enqueue $member }
            $groups.Add([ordered]@{ sid = $sid; name = $name; members = @($members) })
        }
        else {
            # userAccountControl bit 0x2 is ACCOUNTDISABLE.
            $disabled = ([int]$object.userAccountControl -band 2) -ne 0
            $users.Add([ordered]@{ sid = $sid; name = $name; displayName = [string]$object.displayName; enabled = -not $disabled })
        }
    }

    # ------------------------------------------------------------- software
    $inventory = @{}
    if (-not $SkipSoftware) {
        $persistentCatalogs = @{}
        foreach ($catalog in $catalogs) {
            $persistentCatalogs[$catalog.uid] = $catalog.allocationType -eq 'Static' -or $catalog.persistUserChanges -ne 'Discard'
        }
        $targets = foreach ($group in $brokerMachines | Where-Object { $_.RegistrationState -eq 'Registered' -and $_.DNSName } | Group-Object CatalogUid) {
            $uid = [long]$group.Name
            if ($persistentCatalogs[$uid]) { $group.Group } else { $group.Group | Select-Object -First $PooledSampleSize }
        }
        $targets = @($targets)
        if ($targets.Count) {
            Write-Verbose "Reading installed software from $($targets.Count) machine(s)."
            $remote = @{ ComputerName = @($targets.DNSName); ThrottleLimit = $ThrottleLimit; ErrorAction = 'SilentlyContinue'; ErrorVariable = 'remoteErrors' }
            if ($Credential) { $remote.Credential = $Credential }
            $results = @(Invoke-Command @remote -ScriptBlock {
                    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
                    $items = Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue |
                        Where-Object { $_.DisplayName -and $_.SystemComponent -ne 1 -and -not $_.ParentKeyName -and $_.ReleaseType -notin 'Update', 'Hotfix', 'Security Update' }
                    [pscustomobject]@{
                        Software = @($items | Sort-Object DisplayName, DisplayVersion -Unique | ForEach-Object {
                                [pscustomobject]@{ name = [string]$_.DisplayName; version = [string]$_.DisplayVersion; publisher = [string]$_.Publisher }
                            })
                    }
                })
            foreach ($result in $results) {
                $inventory[[string]$result.PSComputerName] = @($result.Software | ForEach-Object {
                        [ordered]@{ name = $_.name; version = $_.version; publisher = $_.publisher }
                    })
            }
            foreach ($problem in @($remoteErrors)) {
                Write-Warning "Software inventory failed on $($problem.TargetObject): $($problem.Exception.Message)"
            }
        }
    }

    $machines = @($brokerMachines | ForEach-Object {
            $software = $null
            if ($_.DNSName -and $inventory.ContainsKey([string]$_.DNSName)) { $software = @($inventory[[string]$_.DNSName]) }
            [ordered]@{
                name = [string]$_.MachineName
                catalogUid = [long]$_.CatalogUid
                deliveryGroupUid = if ($null -ne $_.DesktopGroupUid) { [long]$_.DesktopGroupUid } else { $null }
                agentVersion = & $text $_.AgentVersion
                osType = & $text $_.OSType
                registrationState = & $text $_.RegistrationState
                inMaintenanceMode = [bool]$_.InMaintenanceMode
                assignedUsers = @($_.AssociatedUserSIDs | ForEach-Object { [string]$_ })
                lastConnectionTime = Format-CcbDate $_.LastConnectionTime
                software = $software
            }
        })

    $snapshot = [ordered]@{
        schemaVersion = $script:SchemaVersion
        site = [ordered]@{
            name = if ($AdminAddress) { $AdminAddress } else { [Environment]::MachineName }
            collectedAt = Format-CcbDate $collectedAt
            source = 'broker-sdk'
            collectorVersion = $script:ModuleVersion
            pseudonymized = $false
        }
        directory = [ordered]@{
            users = @($users | Sort-Object { $_.name })
            groups = @($groups | Sort-Object { $_.name })
        }
        catalogs = $catalogs
        deliveryGroups = $deliveryGroups
        machines = $machines
    }
    Test-CcbSnapshot -Snapshot $snapshot -Assert
    return $snapshot
}
