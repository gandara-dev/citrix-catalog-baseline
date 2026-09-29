BeforeAll {
    # Stubs let the module resolve the Citrix and Active Directory commands on a
    # machine without either installed; Pester mocks provide every result.
    foreach ($name in 'Get-BrokerCatalog', 'Get-BrokerDesktopGroup', 'Get-BrokerMachine',
        'Get-BrokerEntitlementPolicyRule', 'Get-BrokerAssignmentPolicyRule', 'Get-BrokerAccessPolicyRule') {
        Set-Item -Path "Function:global:$name" -Value {
            [CmdletBinding()]
            param([string]$AdminAddress, [int]$MaxRecordCount)
            [void]$AdminAddress
            [void]$MaxRecordCount
        }
    }
    function global:Get-ADDomain { [CmdletBinding()] param([string]$Server) [void]$Server }
    function global:Get-ADObject { [CmdletBinding()] param([string]$Server, [string]$LDAPFilter, [string[]]$Properties) [void]$Server; [void]$LDAPFilter; [void]$Properties }
    function global:Get-ADGroupMember { [CmdletBinding()] param([string]$Server, [string]$Identity) [void]$Server; [void]$Identity }

    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repositoryRoot 'src/CitrixCatalogBaseline/CitrixCatalogBaseline.psd1') -Force

    # A minimal site: one shared and one private delivery group, built fresh
    # for each test so cases can change it freely.
    function Get-TestSite {
        [ordered]@{
            schemaVersion = 1
            site = [ordered]@{ name = 'Test'; collectedAt = '2026-09-28T12:00:00Z'; source = 'synthetic'; pseudonymized = $false }
            directory = [ordered]@{
                users = @(
                    [ordered]@{ sid = 'U1'; name = 'T\alice'; displayName = 'Alice'; enabled = $true }
                    [ordered]@{ sid = 'U2'; name = 'T\bob'; displayName = 'Bob'; enabled = $true }
                    [ordered]@{ sid = 'U3'; name = 'T\carol'; displayName = 'Carol'; enabled = $false }
                )
                groups = @(
                    [ordered]@{ sid = 'G1'; name = 'T\Desk'; members = @('G2') }
                    [ordered]@{ sid = 'G2'; name = 'T\Team'; members = @('U1', 'U3') }
                )
            }
            catalogs = @(
                [ordered]@{ uid = 1; name = 'Pool'; provisioningType = 'MCS'; allocationType = 'Random'; persistUserChanges = 'Discard'; sessionSupport = 'SingleSession' }
                [ordered]@{ uid = 2; name = 'Personal'; provisioningType = 'MCS'; allocationType = 'Static'; persistUserChanges = 'OnLocal'; sessionSupport = 'SingleSession' }
            )
            deliveryGroups = @(
                [ordered]@{
                    uid = 1; name = 'Shared'; desktopKind = 'Shared'; enabled = $true
                    desktopRules = @([ordered]@{ name = 'Shared_1'; kind = 'Entitlement'; enabled = $true; includedUserFilterEnabled = $true; includedUsers = @('G1'); excludedUserFilterEnabled = $false; excludedUsers = @() })
                    accessRules = @([ordered]@{ name = 'Shared_AG'; enabled = $true; includedUserFilterEnabled = $true; includedUsers = @('G1'); excludedUserFilterEnabled = $false; excludedUsers = @() })
                }
                [ordered]@{
                    uid = 2; name = 'Private'; desktopKind = 'Private'; enabled = $true
                    desktopRules = @()
                    accessRules = @([ordered]@{ name = 'Private_AG'; enabled = $true; includedUserFilterEnabled = $false; includedUsers = @(); excludedUserFilterEnabled = $false; excludedUsers = @() })
                }
            )
            machines = @(
                [ordered]@{ name = 'T\POOL-1'; catalogUid = 1; deliveryGroupUid = 1; agentVersion = '2402.0.100.629'; osType = 'Windows 11'; registrationState = 'Registered'; inMaintenanceMode = $false; assignedUsers = @(); lastConnectionTime = $null; software = $null }
                [ordered]@{ name = 'T\PC-1'; catalogUid = 2; deliveryGroupUid = 2; agentVersion = '2402.0.100.629'; osType = 'Windows 11'; registrationState = 'Registered'; inMaintenanceMode = $false; assignedUsers = @('U2'); lastConnectionTime = '2026-09-27T09:00:00Z'; software = $null }
            )
        }
    }

    $script:synthetic = New-CcbSyntheticSnapshot
    $script:syntheticAccess = @(Resolve-CcbAccess -Snapshot $script:synthetic)
    $script:syntheticRecommendations = @(Get-CcbRecommendation -Snapshot $script:synthetic -Access $script:syntheticAccess)
}

AfterAll {
    foreach ($name in 'Get-BrokerCatalog', 'Get-BrokerDesktopGroup', 'Get-BrokerMachine', 'Get-BrokerEntitlementPolicyRule',
        'Get-BrokerAssignmentPolicyRule', 'Get-BrokerAccessPolicyRule', 'Get-ADDomain', 'Get-ADObject', 'Get-ADGroupMember') {
        Remove-Item -Path "Function:/$name" -ErrorAction SilentlyContinue
    }
}

Describe 'Module' {
    It 'declares the same version it reports at runtime' {
        $manifest = Import-PowerShellDataFile (Join-Path $PSScriptRoot '../src/CitrixCatalogBaseline/CitrixCatalogBaseline.psd1')
        $manifest.ModuleVersion | Should -Be '0.1.0'
        $script:synthetic.site.collectorVersion | Should -Be $manifest.ModuleVersion
    }

    It 'exports only the documented commands' {
        (Get-Command -Module CitrixCatalogBaseline).Name | Sort-Object | Should -Be @(
            'Get-CcbRecommendation', 'Get-CcbSiteSnapshot', 'New-CcbReport', 'New-CcbSyntheticSnapshot',
            'Protect-CcbSnapshot', 'Resolve-CcbAccess', 'Test-CcbSnapshot')
    }

    It 'compares dotted versions numerically' {
        InModuleScope CitrixCatalogBaseline {
            Compare-CcbVersion '1912.0.9000.26' '2203' | Should -Be -1
            Compare-CcbVersion '2402.0.100.629' '2203' | Should -Be 1
            Compare-CcbVersion '128.0.6613.138' '128.0.6613.138' | Should -Be 0
            Compare-CcbVersion '2.46.0' '2.9' | Should -Be 1
        }
    }
}

Describe 'Test-CcbSnapshot' {
    It 'accepts the synthetic site before and after a JSON round trip' {
        @(Test-CcbSnapshot -Snapshot $script:synthetic) | Should -HaveCount 0
        $roundTrip = $script:synthetic | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        @(Test-CcbSnapshot -Snapshot $roundTrip) | Should -HaveCount 0
    }

    It 'reports <Case>' -ForEach @(
        @{ Case = 'a wrong schema version'; Path = 'schemaVersion'; Change = { param($s) $s.schemaVersion = 2 } }
        @{ Case = 'an unknown provisioning type'; Path = 'catalogs[0].provisioningType'; Change = { param($s) $s.catalogs[0].provisioningType = 'Cloud' } }
        @{ Case = 'a machine in an unknown catalog'; Path = 'machines[0].catalogUid'; Change = { param($s) $s.machines[0].catalogUid = 99 } }
        @{ Case = 'a machine in an unknown delivery group'; Path = 'machines[0].deliveryGroupUid'; Change = { param($s) $s.machines[0].deliveryGroupUid = 99 } }
        @{ Case = 'a duplicate SID'; Path = 'directory.groups[0].sid'; Change = { param($s) $s.directory.groups[0].sid = 'U1' } }
        @{ Case = 'a rule without a kind'; Path = 'deliveryGroups[0].desktopRules[0].kind'; Change = { param($s) $s.deliveryGroups[0].desktopRules[0].kind = 'Other' } }
        @{ Case = 'an invalid date'; Path = 'machines[1].lastConnectionTime'; Change = { param($s) $s.machines[1].lastConnectionTime = 'yesterday' } }
    ) {
        $site = Get-TestSite
        & $Change $site
        (Test-CcbSnapshot -Snapshot $site).Path | Should -Contain $Path
    }

    It 'throws with -Assert' {
        $site = Get-TestSite
        $site.schemaVersion = 7
        { Test-CcbSnapshot -Snapshot $site -Assert } | Should -Throw '*schemaVersion*'
    }
}

Describe 'Resolve-CcbAccess' {
    It 'follows nested groups and reports the shortest path' {
        $entry = Resolve-CcbAccess -Snapshot (Get-TestSite) | Where-Object { $_.UserName -eq 'T\alice' -and $_.DeliveryGroupName -eq 'Shared' }
        $entry.Status | Should -Be 'Granted'
        $entry.Path | Should -Be @('T\alice', 'T\Team', 'T\Desk')
        $entry.NestingDepth | Should -Be 1
        $entry.CatalogUids | Should -Be @(1)
    }

    It 'grants a private desktop through a direct machine assignment' {
        $entry = Resolve-CcbAccess -Snapshot (Get-TestSite) | Where-Object { $_.UserName -eq 'T\bob' }
        $entry.DeliveryGroupName | Should -Be 'Private'
        $entry.GrantedBy | Should -Be 'Machine assignment'
        $entry.AssignedMachine | Should -Be 'T\PC-1'
        $entry.Status | Should -Be 'Granted'
    }

    It 'treats a disabled included-user filter as every user' {
        $site = Get-TestSite
        $site.deliveryGroups[0].desktopRules[0].includedUserFilterEnabled = $false
        $entries = @(Resolve-CcbAccess -Snapshot $site | Where-Object DeliveryGroupName -eq 'Shared')
        $entries.UserName | Should -Be @('T\alice', 'T\bob', 'T\carol')
        ($entries | Where-Object UserName -eq 'T\bob').Status | Should -Be 'BlockedByAccessPolicy'
        $site.deliveryGroups[0].accessRules[0].includedUserFilterEnabled = $false
        (Resolve-CcbAccess -Snapshot $site | Where-Object { $_.DeliveryGroupName -eq 'Shared' -and $_.Status -eq 'Granted' }).UserName |
            Should -Be @('T\alice', 'T\bob', 'T\carol')
    }

    It 'blocks a user excluded by the access policy' {
        $site = Get-TestSite
        $site.deliveryGroups[0].accessRules[0].excludedUserFilterEnabled = $true
        $site.deliveryGroups[0].accessRules[0].excludedUsers = @('U1')
        $entry = Resolve-CcbAccess -Snapshot $site | Where-Object { $_.UserName -eq 'T\alice' -and $_.DeliveryGroupName -eq 'Shared' }
        $entry.Status | Should -Be 'BlockedByAccessPolicy'
    }

    It 'honours exclusions in the desktop rule' {
        $site = Get-TestSite
        $site.deliveryGroups[0].desktopRules[0].excludedUserFilterEnabled = $true
        $site.deliveryGroups[0].desktopRules[0].excludedUsers = @('G2')
        @(Resolve-CcbAccess -Snapshot $site | Where-Object DeliveryGroupName -eq 'Shared') | Should -HaveCount 0
    }

    It 'ignores disabled rules and flags disabled delivery groups' {
        $site = Get-TestSite
        $site.deliveryGroups[0].enabled = $false
        (Resolve-CcbAccess -Snapshot $site | Where-Object DeliveryGroupName -eq 'Shared').Status | Should -Be @('DeliveryGroupDisabled', 'DeliveryGroupDisabled')
        $site.deliveryGroups[0].desktopRules[0].enabled = $false
        @(Resolve-CcbAccess -Snapshot $site | Where-Object DeliveryGroupName -eq 'Shared') | Should -HaveCount 0
    }

    It 'flags users named directly in a rule' {
        $site = Get-TestSite
        $site.deliveryGroups[0].desktopRules[0].includedUsers = @('G1', 'U2')
        $entry = Resolve-CcbAccess -Snapshot $site | Where-Object { $_.UserName -eq 'T\bob' -and $_.DeliveryGroupName -eq 'Shared' }
        $entry.DirectUser | Should -BeTrue
        $entry.Status | Should -Be 'BlockedByAccessPolicy'
    }

    It 'terminates on circular group nesting' {
        $site = Get-TestSite
        $site.directory.groups[0].members = @('G2')
        $site.directory.groups[1].members = @('U1', 'G1')
        $entry = Resolve-CcbAccess -Snapshot $site | Where-Object { $_.UserName -eq 'T\alice' -and $_.DeliveryGroupName -eq 'Shared' }
        $entry.Path | Should -Be @('T\alice', 'T\Team', 'T\Desk')
    }

    It 'resolves the synthetic site' {
        @($script:syntheticAccess | Where-Object Status -eq 'Granted') | Should -HaveCount 137
        ($script:syntheticAccess | Where-Object Status -eq 'BlockedByAccessPolicy').UserName | Should -Be @('CORP\karin.duarte', 'CORP\luis.esteves')
        $deep = $script:syntheticAccess | Where-Object { $_.NestingDepth -ge 4 } | Select-Object -First 1
        $deep.Path | Should -Be @('CORP\marta.faria', 'CORP\GRP-Team-Support-L2', 'CORP\GRP-Dept-Support', 'CORP\GRP-Office-Lisbon', 'CORP\GRP-Region-EMEA', 'CORP\GRP-VDI-AllStaff')
    }
}

Describe 'Get-CcbRecommendation' {
    It 'finds one case of every rule in the synthetic site' {
        $script:syntheticRecommendations.Id | Sort-Object -Unique | Should -Be @(
            'CCB001', 'CCB002', 'CCB003', 'CCB004', 'CCB005', 'CCB006', 'CCB007', 'CCB008', 'CCB009', 'CCB010', 'CCB011', 'CCB012', 'CCB013')
    }

    It 'orders by severity' {
        $order = @{ High = 0; Medium = 1; Low = 2; Info = 3 }
        $ranks = @($script:syntheticRecommendations | ForEach-Object { $order[$_.Severity] })
        $ranks | Should -Be @($ranks | Sort-Object)
    }

    It 'reports drift inside the persistent catalog with the exact differences' {
        $drift = $script:syntheticRecommendations | Where-Object Id -eq 'CCB005'
        $drift.CatalogUids | Should -Be @(3)
        @($drift.Evidence | ForEach-Object { "$($_.machine)|$($_.difference)|$($_.application)" }) | Should -Be @(
            'CORP\VDI-ENG-004|Version|Google Chrome'
            'CORP\VDI-ENG-007|Missing|Python 3.12.6 (64-bit)'
            'CORP\VDI-ENG-007|Extra|Wireshark 4.2.6 x64'
            'CORP\VDI-ENG-011|Version|Git')
    }

    It 'reports disabled accounts that still have access' {
        $disabled = $script:syntheticRecommendations | Where-Object Id -eq 'CCB001'
        $disabled.Severity | Should -Be 'High'
        @($disabled.Evidence.user | Sort-Object -Unique) | Should -Be @('CORP\diego.esteves', 'CORP\joao.barros')
    }

    It 'reports the circular group by name' {
        ($script:syntheticRecommendations | Where-Object Id -eq 'CCB011').Evidence.cycle |
            Should -Be 'CORP\GRP-Legacy-Apps > CORP\GRP-Legacy-Users > CORP\GRP-Legacy-Apps'
    }

    It 'applies the thresholds' {
        $recommendations = @(Get-CcbRecommendation -Snapshot $script:synthetic -Access $script:syntheticAccess -UnusedDays 90 -MinimumVdaVersion '1912' -MaxNestingDepth 5 -OverlapThreshold 1.0)
        ($recommendations | Where-Object Id -eq 'CCB009').Evidence.machine | Should -Be @('CORP\VDI-ENG-009', 'CORP\VDI-ENG-012')
        $recommendations.Id | Should -Not -Contain 'CCB006'
        $recommendations.Id | Should -Not -Contain 'CCB010'
        @($recommendations | Where-Object Id -eq 'CCB003') | Should -HaveCount 1
    }

    It 'stays quiet on a clean site' {
        $site = Get-TestSite
        $site.directory.users[2].enabled = $true
        @(Get-CcbRecommendation -Snapshot $site) | Should -HaveCount 0
    }
}

Describe 'Protect-CcbSnapshot' {
    BeforeAll {
        $script:key = [byte[]](1..32)
        $script:protected = Protect-CcbSnapshot -Snapshot $script:synthetic -Key $script:key
        $script:protectedJson = $script:protected | ConvertTo-Json -Depth 30
    }

    It 'removes every user, group, and machine identity' {
        $script:protectedJson | Should -Not -Match 'CORP\\\\'
        $script:protectedJson | Should -Not -Match 'S-1-5-21'
        $script:protectedJson | Should -Not -Match 'alves|Lisbon Site'
        $script:protected.site.pseudonymized | Should -BeTrue
        @(Test-CcbSnapshot -Snapshot $script:protected) | Should -HaveCount 0
    }

    It 'keeps the access structure and the findings' {
        $access = @(Resolve-CcbAccess -Snapshot $script:protected)
        ($access | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }) |
            Should -Be ($script:syntheticAccess | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" })
        (Get-CcbRecommendation -Snapshot $script:protected -Access $access).Id | Should -Be $script:syntheticRecommendations.Id
    }

    It 'is stable for one key and different across keys' {
        (Protect-CcbSnapshot -Snapshot $script:synthetic -Key $script:key | ConvertTo-Json -Depth 30) | Should -Be $script:protectedJson
        (Protect-CcbSnapshot -Snapshot $script:synthetic | ConvertTo-Json -Depth 30) | Should -Not -Be $script:protectedJson
    }

    It 'keeps catalog names unless asked to replace them' {
        $script:protected.catalogs.name | Should -Contain 'W11-Pooled-General'
        (Protect-CcbSnapshot -Snapshot $script:synthetic -Key $script:key -IncludeCatalogNames).catalogs.name | Should -Not -Contain 'W11-Pooled-General'
    }
}

Describe 'New-CcbReport' {
    It 'produces the same document for the same snapshot' {
        (New-CcbReport -Snapshot $script:synthetic | ConvertTo-Json -Depth 30) |
            Should -Be (New-CcbReport -Snapshot ($script:synthetic | ConvertTo-Json -Depth 30 | ConvertFrom-Json) | ConvertTo-Json -Depth 30)
    }

    It 'summarizes the synthetic site' {
        $report = New-CcbReport -Snapshot $script:synthetic
        $report.kind | Should -Be 'citrix-catalog-baseline-report'
        $report.summary.catalogs | Should -Be 7
        $report.summary.machines | Should -Be 65
        ($report.catalogs | Where-Object name -eq 'W11-Pooled-Pilot').machineCount | Should -Be 0
        ($report.catalogs | Where-Object name -eq 'W11-Dedicated-Engineering').persistent | Should -BeTrue
    }

    It 'keeps the committed demo data current' {
        $snapshotPath = Join-Path $TestDrive 'synthetic.snapshot.json'
        $reportPath = Join-Path $TestDrive 'demo-report.json'
        & (Join-Path $PSScriptRoot '../scripts/Update-DemoData.ps1') -SnapshotPath $snapshotPath -ReportPath $reportPath
        foreach ($pair in @(@($snapshotPath, '../samples/synthetic.snapshot.json'), @($reportPath, '../site/data/demo-report.json'))) {
            $expected = (Get-Content -LiteralPath (Join-Path $PSScriptRoot $pair[1]) -Raw) -replace "`r`n", "`n"
            (Get-Content -LiteralPath $pair[0] -Raw) | Should -BeExactly $expected -Because "$($pair[1]) must be regenerated with scripts/Update-DemoData.ps1"
        }
    }
}

Describe 'Get-CcbSiteSnapshot' {
    BeforeAll {
        $user = { param($Sid, $Name) [pscustomobject]@{ SID = $Sid; Name = $Name } }
        Mock -ModuleName CitrixCatalogBaseline Get-BrokerCatalog {
            [pscustomobject]@{ Uid = 1; Name = 'Pool'; ProvisioningType = 'MCS'; AllocationType = 'Random'; PersistUserChanges = 'Discard'; SessionSupport = 'SingleSession' }
            [pscustomobject]@{ Uid = 2; Name = 'Personal'; ProvisioningType = 'MCS'; AllocationType = 'Static'; PersistUserChanges = 'OnLocal'; SessionSupport = 'SingleSession' }
        }
        Mock -ModuleName CitrixCatalogBaseline Get-BrokerDesktopGroup {
            [pscustomobject]@{ Uid = 10; Name = 'Shared'; DesktopKind = 'Shared'; Enabled = $true }
            [pscustomobject]@{ Uid = 20; Name = 'Private'; DesktopKind = 'Private'; Enabled = $true }
        }
        Mock -ModuleName CitrixCatalogBaseline Get-BrokerEntitlementPolicyRule {
            [pscustomobject]@{ DesktopGroupUid = 10; Name = 'Shared_1'; Enabled = $true; IncludedUserFilterEnabled = $true; IncludedUsers = @(& $user 'S-G1' 'T\Desk'); ExcludedUserFilterEnabled = $false; ExcludedUsers = @() }
        }.GetNewClosure()
        Mock -ModuleName CitrixCatalogBaseline Get-BrokerAssignmentPolicyRule {
            [pscustomobject]@{ DesktopGroupUid = 20; Name = 'Private_1'; Enabled = $true; IncludedUserFilterEnabled = $true; IncludedUsers = @(& $user 'S-GONE' 'T\Old'); ExcludedUserFilterEnabled = $false; ExcludedUsers = @() }
        }.GetNewClosure()
        Mock -ModuleName CitrixCatalogBaseline Get-BrokerAccessPolicyRule {
            [pscustomobject]@{ DesktopGroupUid = 10; Name = 'Shared_AG'; Enabled = $true; IncludedUserFilterEnabled = $false; IncludedUsers = @(); ExcludedUserFilterEnabled = $false; ExcludedUsers = @() }
            [pscustomobject]@{ DesktopGroupUid = 20; Name = 'Private_AG'; Enabled = $true; IncludedUserFilterEnabled = $false; IncludedUsers = @(); ExcludedUserFilterEnabled = $false; ExcludedUsers = @() }
        }
        Mock -ModuleName CitrixCatalogBaseline Get-BrokerMachine {
            [pscustomobject]@{ MachineName = 'T\POOL-1'; DNSName = 'pool-1.t.test'; CatalogUid = 1; DesktopGroupUid = 10; AgentVersion = '2402.0.100.629'; OSType = 'Windows 11'; RegistrationState = 'Registered'; InMaintenanceMode = $false; AssociatedUserSIDs = @(); LastConnectionTime = $null }
            [pscustomobject]@{ MachineName = 'T\POOL-2'; DNSName = 'pool-2.t.test'; CatalogUid = 1; DesktopGroupUid = 10; AgentVersion = '2402.0.100.629'; OSType = 'Windows 11'; RegistrationState = 'Registered'; InMaintenanceMode = $false; AssociatedUserSIDs = @(); LastConnectionTime = $null }
            [pscustomobject]@{ MachineName = 'T\PC-1'; DNSName = 'pc-1.t.test'; CatalogUid = 2; DesktopGroupUid = 20; AgentVersion = '2203.0.3000.3052'; OSType = 'Windows 11'; RegistrationState = 'Registered'; InMaintenanceMode = $false; AssociatedUserSIDs = @('S-U2'); LastConnectionTime = [datetime]::new(2026, 9, 20, 8, 0, 0, [DateTimeKind]::Utc) }
            [pscustomobject]@{ MachineName = 'T\PC-2'; DNSName = 'pc-2.t.test'; CatalogUid = 2; DesktopGroupUid = $null; AgentVersion = $null; OSType = $null; RegistrationState = 'Unregistered'; InMaintenanceMode = $true; AssociatedUserSIDs = @(); LastConnectionTime = $null }
        }
        Mock -ModuleName CitrixCatalogBaseline Get-ADDomain { [pscustomobject]@{ NetBIOSName = 'T' } }
        Mock -ModuleName CitrixCatalogBaseline Get-ADObject {
            switch -Regex ($LDAPFilter) {
                'S-G1\)' { [pscustomobject]@{ objectClass = 'group'; sAMAccountName = 'Desk'; displayName = $null; userAccountControl = $null } }
                'S-U1\)' { [pscustomobject]@{ objectClass = 'user'; sAMAccountName = 'alice'; displayName = 'Alice'; userAccountControl = 512 } }
                'S-U2\)' { [pscustomobject]@{ objectClass = 'user'; sAMAccountName = 'bob'; displayName = 'Bob'; userAccountControl = 514 } }
            }
        }
        Mock -ModuleName CitrixCatalogBaseline Get-ADGroupMember { [pscustomobject]@{ SID = 'S-U1' } } -ParameterFilter { $Identity -eq 'S-G1' }
        Mock -ModuleName CitrixCatalogBaseline Invoke-Command {
            foreach ($computer in $ComputerName) {
                [pscustomobject]@{
                    PSComputerName = $computer
                    Software = @([pscustomobject]@{ name = 'Google Chrome'; version = '128.0.6613.138'; publisher = 'Google LLC' })
                }
            }
        }
        Mock -ModuleName CitrixCatalogBaseline Write-Warning {}

        $script:collected = Get-CcbSiteSnapshot -AdminAddress 'ddc01.t.test'
    }

    It 'produces a valid snapshot' {
        @(Test-CcbSnapshot -Snapshot $script:collected) | Should -HaveCount 0
        $script:collected.site.source | Should -Be 'broker-sdk'
        $script:collected.site.name | Should -Be 'ddc01.t.test'
    }

    It 'maps rules to their delivery groups by kind' {
        $shared = $script:collected.deliveryGroups | Where-Object name -eq 'Shared'
        $shared.desktopRules[0].kind | Should -Be 'Entitlement'
        $shared.desktopRules[0].includedUsers | Should -Be @('S-G1')
        $shared.accessRules[0].includedUserFilterEnabled | Should -BeFalse
        ($script:collected.deliveryGroups | Where-Object name -eq 'Private').desktopRules[0].kind | Should -Be 'Assignment'
    }

    It 'resolves users, disabled accounts, nested members, and unknown SIDs' {
        ($script:collected.directory.users | Where-Object sid -eq 'S-U1').name | Should -Be 'T\alice'
        ($script:collected.directory.users | Where-Object sid -eq 'S-U2').enabled | Should -BeFalse
        ($script:collected.directory.groups | Where-Object sid -eq 'S-G1').members | Should -Be @('S-U1')
        ($script:collected.directory.groups | Where-Object sid -eq 'S-GONE').name | Should -Be '(unresolved) S-GONE'
        Should -Invoke -ModuleName CitrixCatalogBaseline Write-Warning -Scope Describe -ParameterFilter { $Message -like '*S-GONE*' }
    }

    It 'inventories one pooled machine and every registered persistent machine' {
        Should -Invoke -ModuleName CitrixCatalogBaseline Invoke-Command -Times 1 -Exactly -Scope Describe -ParameterFilter {
            (@($ComputerName) -join ',') -eq 'pool-1.t.test,pc-1.t.test'
        }
        ($script:collected.machines | Where-Object name -eq 'T\POOL-1').software[0].name | Should -Be 'Google Chrome'
        ($script:collected.machines | Where-Object name -eq 'T\POOL-2').software | Should -BeNullOrEmpty
        ($script:collected.machines | Where-Object name -eq 'T\PC-2').software | Should -BeNullOrEmpty
    }

    It 'keeps machines outside a delivery group and normalizes dates' {
        $loose = $script:collected.machines | Where-Object name -eq 'T\PC-2'
        $loose.deliveryGroupUid | Should -BeNullOrEmpty
        ($script:collected.machines | Where-Object name -eq 'T\PC-1').lastConnectionTime | Should -Be '2026-09-20T08:00:00Z'
    }

    It 'skips remoting with -SkipSoftware' {
        $null = Get-CcbSiteSnapshot -SkipSoftware
        Should -Invoke -ModuleName CitrixCatalogBaseline Invoke-Command -Times 0 -Exactly -Scope It
    }

    It 'explains a missing Citrix SDK' {
        Mock -ModuleName CitrixCatalogBaseline Get-Command { $null } -ParameterFilter { $Name -eq 'Get-BrokerCatalog' }
        { Get-CcbSiteSnapshot } | Should -Throw '*Citrix Broker PowerShell SDK*'
    }
}
