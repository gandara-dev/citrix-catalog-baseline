function New-CcbSyntheticSnapshot {
    <#
    .SYNOPSIS
    Creates a deterministic, fully fictional site snapshot.

    .DESCRIPTION
    The synthetic site has seven machine catalogs, six delivery groups, 64
    users, nested and circular groups, persistent and pooled desktops, Remote
    PC Access, and software inventories. It deliberately contains one case for
    every recommendation rule, so it doubles as test data and as the public
    demo. The same input always produces the same snapshot.

    .EXAMPLE
    New-CcbSyntheticSnapshot | ConvertTo-Json -Depth 20 | Set-Content ./synthetic.snapshot.json
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object in memory; changes no system state.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [DateTimeOffset]$CollectedAt = [DateTimeOffset]::new(2026, 9, 28, 12, 0, 0, [TimeSpan]::Zero)
    )

    $domain = 'CORP'
    $sidPrefix = 'S-1-5-21-1004336348-1177238915-682003330'
    $iso = { param([DateTimeOffset]$Date) $Date.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture) }
    $daysAgo = {
        param([int]$Days, [int]$Hours = 9)
        & $iso ([DateTimeOffset]::new($CollectedAt.UtcDateTime.Date.AddDays(-$Days).AddHours($Hours), [TimeSpan]::Zero))
    }

    # ---------------------------------------------------------------- users
    $firstNames = @('Ana', 'Bruno', 'Carla', 'Diego', 'Elena', 'Filipe', 'Grace', 'Hugo', 'Ines', 'Joao', 'Karin', 'Luis',
        'Marta', 'Nuno', 'Olga', 'Pedro', 'Rita', 'Samuel', 'Tania', 'Victor', 'Wanda', 'Xavier', 'Yara', 'Zeca',
        'Alice', 'Bernardo', 'Clara', 'Daniel', 'Eva', 'Fabio', 'Gil', 'Helena')
    $lastNames = @('Alves', 'Barros', 'Costa', 'Duarte', 'Esteves', 'Faria', 'Gomes', 'Henriques')
    $departments = @(
        @{ Name = 'Finance'; Count = 10 }
        @{ Name = 'Sales'; Count = 14 }
        @{ Name = 'HR'; Count = 6 }
        @{ Name = 'Engineering'; Count = 14 }
        @{ Name = 'Support'; Count = 8 }
        @{ Name = 'Operations'; Count = 12 }
    )
    $users = [System.Collections.Generic.List[object]]::new()
    $byDepartment = @{}
    $rid = 2001
    $n = 0
    foreach ($department in $departments) {
        $byDepartment[$department.Name] = [System.Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $department.Count; $i++) {
            $first = $firstNames[$n % $firstNames.Count]
            # Shifting the surname every 32 users keeps every first/last pair unique.
            $last = $lastNames[($n + [Math]::Floor($n / $firstNames.Count)) % $lastNames.Count]
            $sam = "$($first.ToLowerInvariant()).$($last.ToLowerInvariant())"
            $user = [ordered]@{
                sid = "$sidPrefix-$rid"
                name = "$domain\$sam"
                displayName = "$first $last"
                enabled = $true
            }
            $users.Add($user)
            $byDepartment[$department.Name].Add($user)
            $rid++
            $n++
        }
    }
    # Two leavers whose accounts were disabled but not removed from groups.
    $byDepartment['Finance'][9].enabled = $false
    $byDepartment['Engineering'][5].enabled = $false
    $contractors = @($byDepartment['Engineering'][12], $byDepartment['Engineering'][13])
    $supportL2 = @($byDepartment['Support'][0..4])

    # --------------------------------------------------------------- groups
    $groups = [ordered]@{}
    $newGroup = {
        param([string]$Name)
        $groups[$Name] = [ordered]@{ sid = "$sidPrefix-$(3001 + $groups.Count)"; name = "$domain\$Name"; members = [System.Collections.Generic.List[string]]::new() }
    }
    foreach ($name in @(
            'GRP-VDI-AllStaff', 'GRP-Region-EMEA', 'GRP-Region-Americas', 'GRP-Office-Lisbon', 'GRP-Office-Madrid',
            'GRP-Team-Support-L2', 'GRP-Dept-Finance', 'GRP-Dept-Sales', 'GRP-Dept-HR', 'GRP-Dept-Engineering',
            'GRP-Dept-Support', 'GRP-Dept-Operations', 'GRP-VDI-General', 'GRP-VDI-Finance', 'GRP-VDI-Engineering',
            'GRP-Contractors', 'GRP-RemotePC-Users', 'GRP-Legacy-Apps', 'GRP-Legacy-Users')) {
        & $newGroup $name
    }
    $add = { param([string]$Group, [string[]]$Sids) foreach ($sid in $Sids) { $groups[$Group].members.Add($sid) } }
    $sidsOf = { param($List) @($List | ForEach-Object { $_.sid }) }

    & $add 'GRP-Dept-Finance' (& $sidsOf $byDepartment['Finance'])
    & $add 'GRP-Dept-Sales' (& $sidsOf $byDepartment['Sales'])
    & $add 'GRP-Dept-HR' (& $sidsOf $byDepartment['HR'])
    & $add 'GRP-Dept-Engineering' (& $sidsOf $byDepartment['Engineering'])
    & $add 'GRP-Dept-Support' ((& $sidsOf $byDepartment['Support'][5..7]) + $groups['GRP-Team-Support-L2'].sid)
    & $add 'GRP-Dept-Operations' (& $sidsOf $byDepartment['Operations'])
    & $add 'GRP-Team-Support-L2' (& $sidsOf $supportL2)
    & $add 'GRP-Contractors' (& $sidsOf $contractors)

    # Five levels for the L2 team: user > Team-Support-L2 > Dept-Support > Office-Lisbon > Region-EMEA > VDI-AllStaff.
    & $add 'GRP-Office-Lisbon' @($groups['GRP-Dept-Finance'].sid, $groups['GRP-Dept-HR'].sid, $groups['GRP-Dept-Support'].sid)
    & $add 'GRP-Office-Madrid' @($groups['GRP-Dept-Sales'].sid, $groups['GRP-Dept-Operations'].sid)
    & $add 'GRP-Region-EMEA' @($groups['GRP-Office-Lisbon'].sid, $groups['GRP-Office-Madrid'].sid)
    & $add 'GRP-Region-Americas' @($groups['GRP-Dept-Engineering'].sid)
    & $add 'GRP-VDI-AllStaff' @($groups['GRP-Region-EMEA'].sid, $groups['GRP-Region-Americas'].sid)

    & $add 'GRP-VDI-General' @($groups['GRP-Dept-Sales'].sid, $groups['GRP-Dept-HR'].sid, $groups['GRP-Dept-Finance'].sid, $groups['GRP-Dept-Operations'].sid)
    & $add 'GRP-VDI-Finance' @($groups['GRP-Dept-Finance'].sid)
    & $add 'GRP-VDI-Engineering' @($groups['GRP-Dept-Engineering'].sid)
    & $add 'GRP-RemotePC-Users' (& $sidsOf @($byDepartment['Operations'][0..7]))

    # Circular nesting left behind by an old migration.
    & $add 'GRP-Legacy-Apps' @($groups['GRP-Legacy-Users'].sid)
    & $add 'GRP-Legacy-Users' @($groups['GRP-Legacy-Apps'].sid, $byDepartment['Operations'][8].sid, $byDepartment['Operations'][9].sid)

    # ------------------------------------------------------------- software
    $app = { param([string]$Name, [string]$Version, [string]$Publisher) [ordered]@{ name = $Name; version = $Version; publisher = $Publisher } }
    $office = & $app 'Microsoft 365 Apps for enterprise' '16.0.18025.20160' 'Microsoft Corporation'
    $officeOld = & $app 'Microsoft 365 Apps for enterprise' '16.0.14332.20763' 'Microsoft Corporation'
    $edge = & $app 'Microsoft Edge' '128.0.2739.79' 'Microsoft Corporation'
    $chrome = & $app 'Google Chrome' '128.0.6613.138' 'Google LLC'
    $chromeBehind = & $app 'Google Chrome' '126.0.6478.183' 'Google LLC'
    $chromeOld = & $app 'Google Chrome' '109.0.5414.120' 'Google LLC'
    $reader = & $app 'Adobe Acrobat Reader' '24.003.20112' 'Adobe'
    $readerOld = & $app 'Adobe Acrobat Reader' '23.008.20470' 'Adobe'
    $zip = & $app '7-Zip' '24.08' 'Igor Pavlov'
    $zipBehind = & $app '7-Zip' '22.01' 'Igor Pavlov'
    $zipOld = & $app '7-Zip' '19.00' 'Igor Pavlov'
    $teams = & $app 'Microsoft Teams' '24215.1007.3082.1590' 'Microsoft Corporation'
    $fslogix = & $app 'Microsoft FSLogix Apps' '2.9.8884.27471' 'Microsoft Corporation'
    $fslogixOld = & $app 'Microsoft FSLogix Apps' '2.9.8440.42104' 'Microsoft Corporation'
    $wem = & $app 'Citrix Workspace Environment Management Agent' '2407.1.0.1' 'Citrix Systems, Inc.'
    $sap = & $app 'SAP GUI for Windows' '8.00.3' 'SAP SE'
    $powerBi = & $app 'Microsoft Power BI Desktop' '2.132.908.0' 'Microsoft Corporation'
    $vscode = & $app 'Microsoft Visual Studio Code' '1.93.1' 'Microsoft Corporation'
    $git = & $app 'Git' '2.46.0' 'The Git Development Community'
    $gitOld = & $app 'Git' '2.39.2' 'The Git Development Community'
    $python = & $app 'Python 3.12.6 (64-bit)' '3.12.6150.0' 'Python Software Foundation'
    $pwsh = & $app 'PowerShell 7-x64' '7.4.5.0' 'Microsoft Corporation'
    $wireshark = & $app 'Wireshark 4.2.6 x64' '4.2.6' 'The Wireshark developer community'
    $java = & $app 'Java 8 Update 202' '8.0.2020.8' 'Oracle Corporation'

    $baseline = @{
        General = @($office, $edge, $chrome, $reader, $zip, $teams, $fslogix, $wem)
        Finance = @($office, $edge, $chromeBehind, $reader, $zip, $teams, $fslogix, $wem, $sap, $powerBi)
        Engineering = @($office, $edge, $chrome, $zip, $teams, $fslogix, $vscode, $git, $python, $pwsh)
        Shared = @($office, $edge, $chrome, $reader, $zip, $teams, $fslogix, $wem)
        RemotePc = @($office, $edge, $chrome, $readerOld, $zipBehind, $teams)
        Legacy = @($officeOld, $chromeOld, $zipOld, $fslogixOld, $java)
    }
    $clone = { param($Item) [ordered]@{ name = $Item.name; version = $Item.version; publisher = $Item.publisher } }
    $copy = { param($Items) , @($Items | ForEach-Object { & $clone $_ }) }

    # ------------------------------------------------------------- catalogs
    $catalog = {
        param([int]$Uid, [string]$Name, [string]$Provisioning, [string]$Allocation, [string]$Persist, [string]$Session)
        [ordered]@{ uid = $Uid; name = $Name; provisioningType = $Provisioning; allocationType = $Allocation; persistUserChanges = $Persist; sessionSupport = $Session }
    }
    $catalogs = @(
        & $catalog 1 'W11-Pooled-General' 'MCS' 'Random' 'Discard' 'SingleSession'
        & $catalog 2 'W11-Pooled-Finance' 'MCS' 'Random' 'Discard' 'SingleSession'
        & $catalog 3 'W11-Dedicated-Engineering' 'MCS' 'Static' 'OnLocal' 'SingleSession'
        & $catalog 4 'WS2022-Shared-Desktop' 'MCS' 'Random' 'Discard' 'MultiSession'
        & $catalog 5 'RemotePC-Lisbon' 'Manual' 'Static' 'OnLocal' 'SingleSession'
        & $catalog 6 'W10-Legacy-Apps' 'MCS' 'Random' 'Discard' 'SingleSession'
        & $catalog 7 'W11-Pooled-Pilot' 'MCS' 'Random' 'Discard' 'SingleSession'
    )

    # ------------------------------------------------------ delivery groups
    $rule = {
        param([string]$Name, [string]$Kind, [string[]]$Included, [string[]]$Excluded, [bool]$Filter = $true)
        $result = [ordered]@{ name = $Name }
        if ($Kind) { $result.kind = $Kind }
        $result.enabled = $true
        $result.includedUserFilterEnabled = $Filter
        $result.includedUsers = @($Included | Where-Object { $_ })
        $result.excludedUserFilterEnabled = @($Excluded | Where-Object { $_ }).Count -gt 0
        $result.excludedUsers = @($Excluded | Where-Object { $_ })
        return $result
    }
    $g = { param([string]$Name) $groups[$Name].sid }
    $directFinanceUser = $byDepartment['Sales'][3].sid

    $deliveryGroups = @(
        [ordered]@{
            uid = 1; name = 'General Desktops'; desktopKind = 'Shared'; enabled = $true
            desktopRules = @(& $rule 'General Desktops_1' 'Entitlement' @(& $g 'GRP-VDI-General') @())
            accessRules = @(
                & $rule 'General Desktops_AG' $null @(& $g 'GRP-VDI-General') @()
                & $rule 'General Desktops_Direct' $null @(& $g 'GRP-VDI-General') @()
            )
        }
        [ordered]@{
            uid = 2; name = 'Finance Desktops'; desktopKind = 'Shared'; enabled = $true
            desktopRules = @(& $rule 'Finance Desktops_1' 'Entitlement' @((& $g 'GRP-VDI-Finance'), $directFinanceUser) @())
            accessRules = @(& $rule 'Finance Desktops_AG' $null @(& $g 'GRP-VDI-AllStaff') @())
        }
        [ordered]@{
            uid = 3; name = 'Engineering Workstations'; desktopKind = 'Private'; enabled = $true
            desktopRules = @(& $rule 'Engineering Workstations_1' 'Assignment' @(& $g 'GRP-VDI-Engineering') @())
            accessRules = @(& $rule 'Engineering Workstations_AG' $null @(& $g 'GRP-VDI-Engineering') @(& $g 'GRP-Contractors'))
        }
        [ordered]@{
            uid = 4; name = 'Shared Desktop'; desktopKind = 'Shared'; enabled = $true
            desktopRules = @(& $rule 'Shared Desktop_1' 'Entitlement' @(& $g 'GRP-VDI-AllStaff') @())
            accessRules = @(& $rule 'Shared Desktop_AG' $null @() @() $false)
        }
        [ordered]@{
            uid = 5; name = 'Remote PC Access'; desktopKind = 'Private'; enabled = $true
            desktopRules = @(& $rule 'Remote PC Access_1' 'Assignment' @(& $g 'GRP-RemotePC-Users') @())
            accessRules = @(& $rule 'Remote PC Access_AG' $null @(& $g 'GRP-RemotePC-Users') @())
        }
        [ordered]@{
            uid = 6; name = 'Legacy Desktops (retired)'; desktopKind = 'Shared'; enabled = $false
            desktopRules = @(& $rule 'Legacy Desktops_1' 'Entitlement' @(& $g 'GRP-Legacy-Apps') @())
            accessRules = @(& $rule 'Legacy Desktops_AG' $null @(& $g 'GRP-Legacy-Apps') @())
        }
    )

    # ------------------------------------------------------------- machines
    $machines = [System.Collections.Generic.List[object]]::new()
    $machine = {
        param([string]$Name, [int]$Catalog, $Group, [string]$Agent, [string]$Os, [string[]]$Assigned, $LastConnection, $Software,
            [string]$Registration = 'Registered', [bool]$Maintenance = $false)
        $machines.Add([ordered]@{
            name = "$domain\$Name"
            catalogUid = $Catalog
            deliveryGroupUid = $Group
            agentVersion = $Agent
            osType = $Os
            registrationState = $Registration
            inMaintenanceMode = $Maintenance
            assignedUsers = @($Assigned | Where-Object { $_ })
            lastConnectionTime = $LastConnection
            software = $Software
        })
    }
    $vdaCurrent = '2402.0.100.629'
    $vdaLtsr = '2203.0.3000.3052'
    $vdaEol = '1912.0.9000.26'

    # Pooled catalogs: one machine per catalog is inventoried because every
    # machine starts from the same image.
    for ($i = 1; $i -le 24; $i++) {
        $software = if ($i -eq 1) { & $copy $baseline.General } else { $null }
        $state = if ($i -eq 23) { 'Unregistered' } else { 'Registered' }
        & $machine ('VDI-GEN-{0:000}' -f $i) 1 1 $vdaCurrent 'Windows 11' @() (& $daysAgo ($i % 3)) $software $state ($i -eq 24)
    }
    for ($i = 1; $i -le 10; $i++) {
        $software = if ($i -eq 1) { & $copy $baseline.Finance } else { $null }
        & $machine ('VDI-FIN-{0:000}' -f $i) 2 2 $vdaLtsr 'Windows 11' @() (& $daysAgo ($i % 2)) $software
    }
    for ($i = 1; $i -le 6; $i++) {
        $software = if ($i -eq 1) { & $copy $baseline.Shared } else { $null }
        & $machine ('VDI-SHD-{0:000}' -f $i) 4 4 $vdaCurrent 'Windows Server 2022' @() (& $daysAgo 0) $software
    }
    for ($i = 1; $i -le 5; $i++) {
        $software = if ($i -eq 1) { & $copy $baseline.Legacy } else { $null }
        & $machine ('VDI-LEG-{0:000}' -f $i) 6 $null $vdaEol 'Windows 10' @() (& $daysAgo (120 + $i)) $software
    }

    # Persistent engineering desktops: every machine is inventoried and three
    # of them drifted from the rest of the catalog.
    for ($i = 1; $i -le 12; $i++) {
        $owner = $byDepartment['Engineering'][$i - 1]
        $software = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $baseline.Engineering) { $software.Add((& $clone $item)) }
        if ($i -eq 4) { $software[2] = & $clone $chromeBehind }
        if ($i -eq 7) {
            $software.RemoveAt(8)
            $software.Add((& $clone $wireshark))
        }
        if ($i -eq 11) { $software[7] = & $clone $gitOld }
        $last = switch ($i) {
            6 { & $daysAgo 75 }
            9 { & $daysAgo 94 }
            12 { $null }
            default { & $daysAgo ($i % 4) }
        }
        & $machine ('VDI-ENG-{0:000}' -f $i) 3 3 $vdaCurrent 'Windows 11' @($owner.sid) $last @($software)
    }

    # Remote PC Access: physical desks in the Lisbon office.
    for ($i = 1; $i -le 8; $i++) {
        $owner = $byDepartment['Operations'][$i - 1]
        $agent = if ($i -le 2) { $vdaEol } else { $vdaLtsr }
        $state = if ($i -eq 8) { 'Unregistered' } else { 'Registered' }
        $software = if ($state -eq 'Registered') { & $copy $baseline.RemotePc } else { $null }
        & $machine ('RPC-LIS-{0:000}' -f $i) 5 5 $agent 'Windows 11' @($owner.sid) (& $daysAgo ($i * 3)) $software $state
    }

    $snapshot = [ordered]@{
        schemaVersion = $script:SchemaVersion
        site = [ordered]@{
            name = 'Synthetic Lisbon Site'
            collectedAt = & $iso $CollectedAt
            source = 'synthetic'
            collectorVersion = $script:ModuleVersion
            pseudonymized = $false
        }
        directory = [ordered]@{
            users = @($users)
            groups = @($groups.Values | ForEach-Object { [ordered]@{ sid = $_.sid; name = $_.name; members = @($_.members) } })
        }
        catalogs = $catalogs
        deliveryGroups = $deliveryGroups
        machines = @($machines)
    }
    return $snapshot
}
