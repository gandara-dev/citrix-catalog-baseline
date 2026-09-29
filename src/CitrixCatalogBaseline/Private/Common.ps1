# Helpers shared by the resolver, the recommendation rules, and the report.
#
# Snapshots arrive either from ConvertFrom-Json (PSCustomObject) or from the
# synthetic generator and collector (ordered dictionaries), so every accessor
# accepts both shapes.

function Get-CcbValue {
    param($InputObject, [string]$Name, $Default = $null)

    # The unary comma keeps one-element and empty arrays intact instead of
    # letting the pipeline unroll them.
    if ($null -eq $InputObject) { return , $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return , $InputObject[$Name] }
        return , $Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return , $Default }
    return , $property.Value
}

function Get-CcbList {
    param($InputObject, [string]$Name)

    # Emits the items one by one, for foreach loops and pipelines; wrap the
    # call in @() when an array is needed.
    $value = Get-CcbValue $InputObject $Name
    if ($null -eq $value) { return }
    foreach ($item in $value) { $item }
}

# ConvertFrom-Json turns ISO 8601 strings into DateTime on some PowerShell
# versions and leaves them as strings on others; normalize both.
function ConvertTo-CcbDate {
    param($Value)

    if ($null -eq $Value -or ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value))) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetime]) { return [DateTimeOffset]::new($Value.ToUniversalTime()) }
    return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
}

function Format-CcbDate {
    param($Value)

    $date = ConvertTo-CcbDate $Value
    if ($null -eq $date) { return $null }
    return $date.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

# Compares dotted versions part by part as numbers ("2203.0.3000" vs "1912.0.9000").
function Compare-CcbVersion {
    param([string]$Left, [string]$Right)

    $leftParts = @(([string]$Left) -split '[.\-]')
    $rightParts = @(([string]$Right) -split '[.\-]')
    $count = [Math]::Max($leftParts.Count, $rightParts.Count)
    for ($index = 0; $index -lt $count; $index++) {
        $a = if ($index -lt $leftParts.Count) { $leftParts[$index] } else { '0' }
        $b = if ($index -lt $rightParts.Count) { $rightParts[$index] } else { '0' }
        $numberA = 0L
        $numberB = 0L
        if ([long]::TryParse($a, [ref]$numberA) -and [long]::TryParse($b, [ref]$numberB)) {
            if ($numberA -ne $numberB) { return [Math]::Sign($numberA - $numberB) }
        }
        else {
            $text = [string]::CompareOrdinal($a, $b)
            if ($text -ne 0) { return [Math]::Sign($text) }
        }
    }
    return 0
}

# Indexes the directory once: principals by SID and the groups each principal
# is a direct member of.
function New-CcbDirectoryIndex {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an index in memory; changes no system state.')]
    param($Snapshot)

    $directory = Get-CcbValue $Snapshot 'directory'
    $principals = @{}
    $memberOf = @{}
    foreach ($user in Get-CcbList $directory 'users') {
        $principals[(Get-CcbValue $user 'sid')] = [pscustomobject]@{
            Sid = Get-CcbValue $user 'sid'
            Name = Get-CcbValue $user 'name'
            DisplayName = Get-CcbValue $user 'displayName'
            Kind = 'User'
            Enabled = [bool](Get-CcbValue $user 'enabled' $true)
        }
    }
    foreach ($group in Get-CcbList $directory 'groups') {
        $sid = Get-CcbValue $group 'sid'
        $principals[$sid] = [pscustomobject]@{
            Sid = $sid
            Name = Get-CcbValue $group 'name'
            DisplayName = Get-CcbValue $group 'name'
            Kind = 'Group'
            Enabled = $true
            Members = @(Get-CcbList $group 'members')
        }
        foreach ($member in Get-CcbList $group 'members') {
            if (-not $memberOf.ContainsKey($member)) { $memberOf[$member] = [System.Collections.Generic.List[string]]::new() }
            $memberOf[$member].Add($sid)
        }
    }
    return [pscustomobject]@{ Principals = $principals; MemberOf = $memberOf }
}

function Get-CcbPrincipalName {
    param($Index, [string]$Sid)

    $principal = $Index.Principals[$Sid]
    if ($null -ne $principal -and $principal.Name) { return $principal.Name }
    return $Sid
}

# Breadth-first walk up the membership graph from one user. Returns, for every
# principal the user belongs to (including the user), the shortest chain of
# SIDs from the user to that principal. The visited set makes circular nesting
# harmless.
function Get-CcbMembershipChain {
    param($Index, [string]$UserSid)

    $chains = @{ $UserSid = , @($UserSid) }
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($UserSid)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not $Index.MemberOf.ContainsKey($current)) { continue }
        foreach ($parent in $Index.MemberOf[$current] | Sort-Object) {
            if ($chains.ContainsKey($parent)) { continue }
            $chains[$parent] = @($chains[$current]) + $parent
            $queue.Enqueue($parent)
        }
    }
    return $chains
}

# Finds cycles among groups (a group that contains itself through nesting).
# Each cycle is returned once, as an ordered list of SIDs starting from the
# smallest SID so the output is stable.
function Find-CcbGroupCycle {
    param($Index)

    $groups = @($Index.Principals.Values | Where-Object Kind -eq 'Group' | Sort-Object Sid)
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $cycles = [System.Collections.Generic.List[object]]::new()
    foreach ($start in $groups) {
        $stack = [System.Collections.Generic.Stack[object]]::new()
        $stack.Push(@($start.Sid))
        while ($stack.Count -gt 0) {
            $path = $stack.Pop()
            $last = $path[-1]
            $principal = $Index.Principals[$last]
            if ($null -eq $principal -or $principal.Kind -ne 'Group') { continue }
            foreach ($member in $principal.Members | Sort-Object) {
                $memberPrincipal = $Index.Principals[$member]
                if ($null -eq $memberPrincipal -or $memberPrincipal.Kind -ne 'Group') { continue }
                if ($member -eq $start.Sid) {
                    $minimum = ($path | Sort-Object)[0]
                    $rotation = [array]::IndexOf($path, $minimum)
                    $ordered = @($path[$rotation..($path.Count - 1)]) + @(if ($rotation -gt 0) { $path[0..($rotation - 1)] })
                    $key = $ordered -join '>'
                    if ($seen.Add($key)) { $cycles.Add($ordered) }
                    continue
                }
                if ($path -contains $member) { continue }
                $stack.Push(@($path) + $member)
            }
        }
    }
    return , $cycles.ToArray()
}
