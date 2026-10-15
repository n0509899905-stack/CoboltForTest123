<#
.SYNOPSIS
    ITZHAK PC TWEAKS - safe, reversible performance / gaming / privacy / quality-of-life tweaks for Windows 10/11.

.DESCRIPTION
    Interactive menu (run with no parameters) or non-interactive via switches.
    Every registry change is backed up to $env:ProgramData\ItzhakPCTweaks\state.json before it is made,
    so "Undo all" can restore the original values, remove values that did not exist, and delete
    registry keys the tool created. Power plan settings are backed up the same way.
    A System Restore point is created before the first change.
    State from older versions ($env:ProgramData\PCTweaks\state.json) is migrated automatically.

.PARAMETER Recommended
    Apply all tweaks marked as recommended, without prompting.

.PARAMETER Undo
    Revert every change recorded in state.json, without prompting.

.PARAMETER Maintenance
    Run the maintenance routine (temp cleanup, component store cleanup, drive optimization, DNS flush).

.PARAMETER DeepRepair
    With -Maintenance: also run DISM /RestoreHealth and sfc /scannow (slow).

.PARAMETER HealthCheck
    Print the read-only FPS Health Check report (RAM speed, refresh rate, GPU driver, power plan, ...).

.EXAMPLE
    .\ItzhakPCTweaks.ps1
.EXAMPLE
    .\ItzhakPCTweaks.ps1 -Recommended -Maintenance
.EXAMPLE
    .\ItzhakPCTweaks.ps1 -Undo
#>
[CmdletBinding()]
param(
    [switch]$Recommended,
    [switch]$Undo,
    [switch]$Maintenance,
    [switch]$DeepRepair,
    [switch]$HealthCheck
)

$ErrorActionPreference = 'Continue'
$script:AppName = 'ITZHAK PC TWEAKS'
try { $Host.UI.RawUI.WindowTitle = $script:AppName } catch { }

# ---------------------------------------------------------------------------
# Console helpers
# ---------------------------------------------------------------------------
function Write-Info([string]$Message) { Write-Host "[*] $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "[+] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "[!] $Message" -ForegroundColor Yellow }
function Write-Err([string]$Message)  { Write-Host "[x] $Message" -ForegroundColor Red }

function Read-YesNo([string]$Question, [bool]$Default = $false) {
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $answer = Read-Host "$Question $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return ($answer.Trim() -match '^(y|yes)$')
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Err "$($script:AppName) must be run as Administrator. Use Run-ItzhakPCTweaks.bat or an elevated PowerShell."
    exit 1
}

$script:Interactive = -not ($Recommended -or $Undo -or $Maintenance -or $HealthCheck)
$script:StateDir    = Join-Path $env:ProgramData 'ItzhakPCTweaks'
$script:StateFile   = Join-Path $script:StateDir 'state.json'
$script:LegacyStateFile = Join-Path (Join-Path $env:ProgramData 'PCTweaks') 'state.json'
$script:RestorePointDone = $false
$script:GuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$script:UltimateGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$script:HighPerfGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'

if (-not (Test-Path -LiteralPath $script:StateDir)) {
    New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
}

# Older versions stored their backup under %ProgramData%\PCTweaks; carry it over so Undo still works.
if (-not (Test-Path -LiteralPath $script:StateFile) -and (Test-Path -LiteralPath $script:LegacyStateFile)) {
    try {
        Copy-Item -LiteralPath $script:LegacyStateFile -Destination $script:StateFile -ErrorAction Stop
        Move-Item -LiteralPath $script:LegacyStateFile -Destination ($script:LegacyStateFile + '.migrated') -Force -ErrorAction SilentlyContinue
        Write-Info "Migrated previous backup from $($script:LegacyStateFile) to $($script:StateFile)."
    } catch {
        Write-Warn "Could not migrate $($script:LegacyStateFile): $($_.Exception.Message). Using it in place."
        $script:StateFile = $script:LegacyStateFile
    }
}

$script:OSBuild = 0
try {
    $script:OSBuild = [int](Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).CurrentBuildNumber
} catch {
    $script:OSBuild = [Environment]::OSVersion.Version.Build
}

$script:IsLaptop = $false
try {
    $script:IsLaptop = [bool](Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop)
} catch {
    $script:IsLaptop = $false
}

# Use the 64-bit registry view even if launched from a 32-bit host, so HKLM\SOFTWARE is not redirected.
$script:RegView = if ([Environment]::Is64BitOperatingSystem) {
    [Microsoft.Win32.RegistryView]::Registry64
} else {
    [Microsoft.Win32.RegistryView]::Default
}

# ---------------------------------------------------------------------------
# State (backup of original values)
# ---------------------------------------------------------------------------
function New-EmptyState {
    [pscustomobject]@{
        Version       = 1
        Registry      = New-Object System.Collections.ArrayList
        CreatedKeys   = New-Object System.Collections.ArrayList
        Services      = New-Object System.Collections.ArrayList
        Applied       = New-Object System.Collections.ArrayList
        PowerSettings = New-Object System.Collections.ArrayList
        PowerScheme   = $null
        CreatedScheme = $null
    }
}

function Import-State {
    $state = New-EmptyState
    if (Test-Path -LiteralPath $script:StateFile) {
        try {
            $json = Get-Content -LiteralPath $script:StateFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            foreach ($r in @($json.Registry))    { if ($null -ne $r) { [void]$state.Registry.Add($r) } }
            foreach ($k in @($json.CreatedKeys)) { if ($k) { [void]$state.CreatedKeys.Add([string]$k) } }
            foreach ($s in @($json.Services))    { if ($s) { [void]$state.Services.Add([string]$s) } }
            foreach ($a in @($json.Applied))     { if ($a) { [void]$state.Applied.Add([string]$a) } }
            foreach ($p in @($json.PowerSettings)) { if ($null -ne $p) { [void]$state.PowerSettings.Add($p) } }
            $state.PowerScheme   = $json.PowerScheme
            $state.CreatedScheme = $json.CreatedScheme
        } catch {
            Write-Err "Could not read $($script:StateFile): $($_.Exception.Message)"
            Write-Err 'Refusing to continue so the existing backup is not overwritten. Fix or move the file and retry.'
            exit 1
        }
    }
    return $state
}

function Save-State {
    $script:State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:StateFile -Encoding UTF8
}

$script:State = Import-State

# ---------------------------------------------------------------------------
# Registry helpers
# ---------------------------------------------------------------------------
function Split-RegPath([string]$Path) {
    $p = ($Path -replace '^Registry::', '') -replace '^(HK[A-Za-z_]+):', '$1'
    $parts = $p -split '\\', 2
    switch ($parts[0].ToUpperInvariant()) {
        { $_ -in 'HKLM', 'HKEY_LOCAL_MACHINE' } { $hive = [Microsoft.Win32.RegistryHive]::LocalMachine; $short = 'HKLM' }
        { $_ -in 'HKCU', 'HKEY_CURRENT_USER' }  { $hive = [Microsoft.Win32.RegistryHive]::CurrentUser;  $short = 'HKCU' }
        default { throw "Unsupported registry hive in path '$Path'" }
    }
    $sub = ''
    if ($parts.Count -gt 1) { $sub = $parts[1].Trim('\') }
    [pscustomobject]@{
        Hive      = $hive
        HiveName  = $short
        SubKey    = $sub
        Canonical = "$short\$sub"
    }
}

function Get-BaseKey($Hive) {
    [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, $script:RegView)
}

function ConvertTo-Storable([string]$Kind, $Value) {
    switch ($Kind) {
        'Binary'      { return [Convert]::ToBase64String([byte[]]$Value) }
        'None'        { return [Convert]::ToBase64String([byte[]]$Value) }
        'QWord'       { return [string]$Value }
        'DWord'       { return [int]$Value }
        'MultiString' { return ,([string[]]@($Value)) }
        default       { return [string]$Value }
    }
}

function ConvertFrom-Storable([string]$Kind, $Value) {
    switch ($Kind) {
        'Binary'      { return ,([byte[]][Convert]::FromBase64String([string]$Value)) }
        'None'        { return ,([byte[]][Convert]::FromBase64String([string]$Value)) }
        'QWord'       { return [long]$Value }
        'DWord'       { return [int]$Value }
        'MultiString' { return ,([string[]]@($Value)) }
        default       { return [string]$Value }
    }
}

function Get-RegValueInfo([string]$Path, [string]$Name) {
    $s = Split-RegPath $Path
    $base = Get-BaseKey $s.Hive
    $key = $base.OpenSubKey($s.SubKey, $false)
    if ($null -eq $key) {
        return [pscustomobject]@{ Exists = $false; Kind = $null; Value = $null }
    }
    try {
        if (@($key.GetValueNames()) -notcontains $Name) {
            return [pscustomobject]@{ Exists = $false; Kind = $null; Value = $null }
        }
        $kind = [string]$key.GetValueKind($Name)
        $value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        return [pscustomobject]@{ Exists = $true; Kind = $kind; Value = (ConvertTo-Storable $kind $value) }
    } finally {
        $key.Close()
    }
}

function Find-RegRecord([string]$Canonical, [string]$Name) {
    foreach ($r in $script:State.Registry) {
        if ($r.Path -eq $Canonical -and $r.Name -eq $Name) { return $r }
    }
    return $null
}

# Opens (creating if needed) a key for writing, recording every key level it had to create.
function Open-RegKeyForWrite([string]$Path) {
    $s = Split-RegPath $Path
    $base = Get-BaseKey $s.Hive
    $current = ''
    $recorded = $false
    foreach ($part in ($s.SubKey -split '\\')) {
        if ([string]::IsNullOrEmpty($part)) { continue }
        $current = if ($current) { "$current\$part" } else { $part }
        $probe = $base.OpenSubKey($current, $false)
        if ($null -ne $probe) {
            $probe.Close()
        } else {
            $canonical = "$($s.HiveName)\$current"
            if ($script:State.CreatedKeys -notcontains $canonical) {
                [void]$script:State.CreatedKeys.Add($canonical)
                $recorded = $true
            }
        }
    }
    if ($recorded) { Save-State }
    $key = $base.CreateSubKey($s.SubKey)
    if ($null -eq $key) { throw "Could not open or create registry key $($s.Canonical)" }
    return $key
}

function Set-Tweak {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()]$Value,
        [ValidateSet('DWord', 'QWord', 'String', 'ExpandString', 'MultiString', 'Binary')]
        [string]$Type = 'DWord'
    )
    $s = Split-RegPath $Path
    $regName = if ($Name -eq '(default)') { '' } else { $Name }

    if ($null -eq (Find-RegRecord $s.Canonical $regName)) {
        $info = Get-RegValueInfo $Path $regName
        [void]$script:State.Registry.Add([pscustomobject]@{
            Path    = $s.Canonical
            Name    = $regName
            Existed = $info.Exists
            Kind    = $info.Kind
            Value   = $info.Value
        })
        Save-State
    }

    switch ($Type) {
        'DWord'       { $typed = [int]$Value }
        'QWord'       { $typed = [long]$Value }
        'MultiString' { $typed = [string[]]@($Value) }
        'Binary'      { $typed = [byte[]]$Value }
        default       { $typed = [string]$Value }
    }

    $key = Open-RegKeyForWrite $Path
    try {
        $key.SetValue($regName, $typed, [Microsoft.Win32.RegistryValueKind]$Type)
    } finally {
        $key.Close()
    }
    $display = if ($regName -eq '') { '(default)' } else { $regName }
    Write-Host ("      {0}\{1} = {2}" -f $s.Canonical, $display, ($Value -join ',')) -ForegroundColor DarkGray
}

function Set-ServiceDisabled([string]$ServiceName) {
    $svcKey = "HKLM\SYSTEM\CurrentControlSet\Services\$ServiceName"
    if (-not (Get-RegValueInfo $svcKey 'Start').Exists) {
        Write-Warn "Service $ServiceName not found, skipping."
        return
    }
    Set-Tweak -Path $svcKey -Name 'Start' -Value 4 -Type DWord
    if ($script:State.Services -notcontains $ServiceName) {
        [void]$script:State.Services.Add($ServiceName)
        Save-State
    }
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
}

# DirectX UserGpuPreferences values are "key=value;key=value;" strings that Windows Settings also writes,
# so update only the requested keys and keep everything else (order and unknown entries included).
function Merge-DxSettingString([string]$Existing, [hashtable]$Updates) {
    $order = New-Object System.Collections.Generic.List[string]
    $map = @{}
    foreach ($pair in ([string]$Existing -split ';')) {
        $p = $pair.Trim()
        if ($p -eq '') { continue }
        $idx = $p.IndexOf('=')
        if ($idx -lt 1) {
            if (-not $map.ContainsKey($p)) { $order.Add($p); $map[$p] = $null }
            continue
        }
        $k = $p.Substring(0, $idx).Trim()
        if (-not $map.ContainsKey($k)) { $order.Add($k) }
        $map[$k] = $p.Substring($idx + 1).Trim()
    }
    foreach ($k in @($Updates.Keys | Sort-Object)) {
        $existingKey = $null
        foreach ($o in $order) { if ($o -eq $k) { $existingKey = $o; break } }
        if ($null -eq $existingKey) { $order.Add([string]$k); $existingKey = [string]$k }
        $map[$existingKey] = [string]$Updates[$k]
    }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($k in $order) {
        if ($null -eq $map[$k]) { $parts.Add($k) } else { $parts.Add("$k=$($map[$k])") }
    }
    if ($parts.Count -eq 0) { return '' }
    return (($parts.ToArray() -join ';') + ';')
}

# Splits pasted text into paths: "quoted paths" may contain anything, unquoted ones are separated by ; or newlines.
function ConvertFrom-PathList([string]$Text) {
    $result = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    foreach ($m in [regex]::Matches($Text, '"([^"]+)"')) {
        $p = $m.Groups[1].Value.Trim()
        if ($p -and -not $result.Contains($p)) { $result.Add($p) }
    }
    $rest = [regex]::Replace($Text, '"[^"]*"', ';')
    foreach ($tok in ($rest -split '[;\r\n]+')) {
        $p = $tok.Trim().Trim("'")
        if ($p -and -not $result.Contains($p)) { $result.Add($p) }
    }
    return $result.ToArray()
}

# ---------------------------------------------------------------------------
# Power plan
# ---------------------------------------------------------------------------
function Get-FirstGuid($Text) {
    $m = [regex]::Match((@($Text) -join "`n"), $script:GuidPattern)
    if ($m.Success) { return $m.Value.ToLowerInvariant() }
    return $null
}

function Get-PowerSchemeGuids {
    $out = & powercfg.exe /list 2>$null
    $guids = @()
    foreach ($m in [regex]::Matches((@($out) -join "`n"), $script:GuidPattern)) {
        $guids += $m.Value.ToLowerInvariant()
    }
    return $guids
}

function Set-HighPerformancePowerPlan {
    if ($script:IsLaptop) {
        Write-Warn 'Battery detected: a high performance plan will increase power draw and heat.'
    }
    $active = Get-FirstGuid (& powercfg.exe /getactivescheme 2>$null)
    if (-not $script:State.PowerScheme -and $active) {
        $script:State.PowerScheme = $active
        Save-State
    }

    $schemes = @(Get-PowerSchemeGuids)
    $target = $null
    if ($script:State.CreatedScheme -and ($schemes -contains $script:State.CreatedScheme)) {
        $target = $script:State.CreatedScheme
    } elseif ($schemes -contains $script:UltimateGuid) {
        $target = $script:UltimateGuid
    } else {
        foreach ($line in @(& powercfg.exe /list 2>$null)) {
            if ($line -match 'Ultimate Performance') { $target = Get-FirstGuid $line; break }
        }
    }

    if (-not $target) {
        $dup = & powercfg.exe -duplicatescheme $script:UltimateGuid 2>$null
        $newGuid = Get-FirstGuid $dup
        if ($LASTEXITCODE -eq 0 -and $newGuid) {
            $target = $newGuid
            $script:State.CreatedScheme = $newGuid
            Save-State
        }
    }

    if ($target) {
        & powercfg.exe /setactive $target | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host "      Active power plan: Ultimate Performance ($target)" -ForegroundColor DarkGray; return }
    }

    Write-Warn 'Ultimate Performance unavailable, falling back to High Performance.'
    & powercfg.exe /setactive $script:HighPerfGuid | Out-Null
    if ($LASTEXITCODE -ne 0) {
        # Modern Standby systems hide High Performance; duplicating it usually still works.
        $newGuid = Get-FirstGuid (& powercfg.exe -duplicatescheme $script:HighPerfGuid 2>$null)
        if (-not $newGuid) { throw 'Could not enable a high performance power plan on this system.' }
        $script:State.CreatedScheme = $newGuid
        Save-State
        & powercfg.exe /setactive $newGuid | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not activate the high performance power plan.' }
        Write-Host "      Active power plan: High Performance ($newGuid)" -ForegroundColor DarkGray
    } else {
        Write-Host "      Active power plan: High Performance ($($script:HighPerfGuid))" -ForegroundColor DarkGray
    }
}

# Returns the AC value from "powercfg /q <scheme> <sub> <setting>" output, or $null.
# Non-English Windows translates the labels, so fall back to the second-to-last hex number
# (every setting ends with the AC index followed by the DC index).
function ConvertFrom-PowerCfgQuery($Lines) {
    $text = @($Lines) -join "`n"
    $m = [regex]::Match($text, 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)')
    if ($m.Success) { return [int][Convert]::ToUInt32($m.Groups[1].Value, 16) }
    $hex = [regex]::Matches($text, '0x([0-9a-fA-F]+)')
    if ($hex.Count -ge 2) { return [int][Convert]::ToUInt32($hex[$hex.Count - 2].Groups[1].Value, 16) }
    return $null
}

function Get-PowerSettingAc([string]$Scheme, [string]$Sub, [string]$Setting) {
    # /qh also lists settings that are hidden in the Power Options UI (CPMINCORES is one).
    $out = & powercfg.exe /qh $Scheme $Sub $Setting 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { $out = & powercfg.exe /q $Scheme $Sub $Setting 2>$null }
    if ($LASTEXITCODE -ne 0) { return $null }
    return (ConvertFrom-PowerCfgQuery $out)
}

function Set-PowerSettingTweak([string]$Scheme, [string]$Sub, [string]$Setting, [int]$Value, [string]$Label) {
    $known = $false
    foreach ($p in $script:State.PowerSettings) {
        if ($p.Scheme -eq $Scheme -and $p.Sub -eq $Sub -and $p.Setting -eq $Setting) { $known = $true; break }
    }
    $original = Get-PowerSettingAc $Scheme $Sub $Setting
    if ($null -eq $original) {
        Write-Warn "$Label is not available on this system, skipping."
        return
    }
    if (-not $known) {
        [void]$script:State.PowerSettings.Add([pscustomobject]@{
            Scheme  = $Scheme
            Sub     = $Sub
            Setting = $Setting
            Value   = $original
        })
        Save-State
    }
    & powercfg.exe -setacvalueindex $Scheme $Sub $Setting $Value 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warn "Could not set $Label (powercfg exit $LASTEXITCODE)."; return }
    Write-Host ("      power plan: {0} = {1} (was {2})" -f $Label, $Value, $original) -ForegroundColor DarkGray
}

function Set-GamingPowerSettings {
    Set-HighPerformancePowerPlan
    $scheme = Get-FirstGuid (& powercfg.exe /getactivescheme 2>$null)
    if (-not $scheme) { throw 'Could not determine the active power plan.' }
    Set-PowerSettingTweak $scheme 'SUB_PROCESSOR' 'CPMINCORES' 100 'Core parking minimum cores %'
    Set-PowerSettingTweak $scheme 'SUB_PROCESSOR' 'PROCTHROTTLEMIN' 100 'Minimum processor state %'
    Set-PowerSettingTweak $scheme '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226' 0 'USB selective suspend'
    Set-PowerSettingTweak $scheme 'SUB_PCIEXPRESS' 'ASPM' 0 'PCI Express link state power management'
    & powercfg.exe -setactive $scheme | Out-Null
}

# ---------------------------------------------------------------------------
# Tweak catalog
# ---------------------------------------------------------------------------
function New-Tweak {
    param(
        [string]$Id,
        [string]$Category,
        [string]$Name,
        [string]$Description,
        [bool]$Recommended,
        [int]$MinBuild = 0,
        [string]$Warning = '',
        [scriptblock]$Apply
    )
    [pscustomobject]@{
        Id          = $Id
        Category    = $Category
        Name        = $Name
        Description = $Description
        Recommended = $Recommended
        MinBuild    = $MinBuild
        Warning     = $Warning
        Apply       = $Apply
    }
}

$explorerAdv = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$cdm = 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$script:DxPrefsKey = 'HKCU\Software\Microsoft\DirectX\UserGpuPreferences'

$script:HvciWarning = @'
SECURITY WARNING - Memory Integrity (HVCI) and Virtualization-Based Security protect the Windows kernel
against malicious or vulnerable drivers. Turning them off lowers that protection.
Microsoft documents turning them off as an option for gaming performance; the gain is roughly 5-15% in
some CPU-heavy games and close to zero in many others.
Some anti-cheat systems and Windows 11 security features check for or require these protections; if a
game or feature stops working, turn this back on with Undo. A reboot is required.
If Memory Integrity was enabled by your organization or locked in UEFI, this change may not take effect.
'@

$script:Tweaks = @(
    # ---- Performance ----
    (New-Tweak -Id 'perf.powerplan' -Category 'Performance' -Name 'Ultimate/High Performance power plan' `
        -Description 'Keeps CPU clocks up and disables aggressive power saving. Not recommended on laptops.' `
        -Recommended (-not $script:IsLaptop) -Apply { Set-HighPerformancePowerPlan }),

    (New-Tweak -Id 'perf.cpupower' -Category 'Performance' -Name 'Unpark CPU cores and keep clocks/USB/PCIe awake' `
        -Description 'On the Ultimate/High Performance plan: no core parking, minimum CPU state 100%, USB selective suspend off, PCIe link power management off. Reduces clock ramp-up stutter and 1% lows. Not recommended on laptops (heat, battery).' `
        -Recommended (-not $script:IsLaptop) -Apply { Set-GamingPowerSettings }),

    (New-Tweak -Id 'perf.powerthrottle' -Category 'Performance' -Name 'Disable power throttling' `
        -Description 'Stops Windows from throttling background and minimized processes (e.g. a game while alt-tabbed, Discord, OBS) onto low clocks or efficiency cores. Most useful on hybrid Intel 12th gen+ CPUs. Not recommended on laptops.' `
        -Recommended (-not $script:IsLaptop) -Apply {
            Set-Tweak 'HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1
        }),

    (New-Tweak -Id 'perf.animations' -Category 'Performance' -Name 'Reduce UI animations' `
        -Description 'Instant menus, no minimize/maximize or taskbar animations.' -Recommended $true -Apply {
            Set-Tweak 'HKCU\Control Panel\Desktop' 'MenuShowDelay' '0' 'String'
            Set-Tweak 'HKCU\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
            Set-Tweak $explorerAdv 'TaskbarAnimations' 0
            Set-Tweak 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 3
        }),

    (New-Tweak -Id 'perf.bgapps' -Category 'Performance' -Name 'Block Store apps running in background' `
        -Description 'Policy that stops UWP/Store apps running in the background. Can delay notifications from Store apps (Teams, WhatsApp, Phone Link).' `
        -Recommended $false -Apply {
            Set-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground' 2
        }),

    (New-Tweak -Id 'perf.startupdelay' -Category 'Performance' -Name 'Remove startup app delay' `
        -Description 'Starts startup apps immediately after sign-in instead of waiting.' -Recommended $true -Apply {
            Set-Tweak 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0
        }),

    (New-Tweak -Id 'perf.mmcss' -Category 'Performance' -Name 'Prioritize games in the multimedia scheduler' `
        -Description 'MMCSS: reserve less CPU for background tasks (SystemResponsiveness=10) and raise the Games task priority.' `
        -Recommended $true -Apply {
            $mm = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
            Set-Tweak $mm 'SystemResponsiveness' 10
            Set-Tweak "$mm\Tasks\Games" 'GPU Priority' 8
            Set-Tweak "$mm\Tasks\Games" 'Priority' 6
            Set-Tweak "$mm\Tasks\Games" 'Scheduling Category' 'High' 'String'
            Set-Tweak "$mm\Tasks\Games" 'SFIO Priority' 'High' 'String'
        }),

    (New-Tweak -Id 'perf.edge' -Category 'Performance' -Name 'Stop Microsoft Edge running in the background' `
        -Description 'Policies BackgroundModeEnabled=0 and StartupBoostEnabled=0: Edge no longer preloads at sign-in or keeps running after it is closed. Edge will show "managed by your organization".' `
        -Recommended $true -Apply {
            Set-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0
            Set-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0
        }),

    (New-Tweak -Id 'perf.wsearch' -Category 'Performance' -Name 'Disable Windows Search indexing' `
        -Description 'Disables the WSearch service, which can cause disk/CPU spikes. Start menu and Explorer search get much slower and Outlook search may break.' `
        -Recommended $false -Apply {
            Set-ServiceDisabled 'WSearch'
        }),

    (New-Tweak -Id 'perf.sysmain' -Category 'Performance' -Name 'Disable SysMain (Superfetch)' `
        -Description 'Disables app prefetching into RAM. Only worth trying on SSD-only systems with background disk/CPU spikes; on HDDs apps start slower.' `
        -Recommended $false -Apply {
            Set-ServiceDisabled 'SysMain'
        }),

    # ---- Gaming ----
    (New-Tweak -Id 'game.gamemode' -Category 'Gaming' -Name 'Enable Game Mode' `
        -Description 'Lets Windows prioritize the foreground game and pause Windows Update installs while playing.' `
        -Recommended $true -Apply {
            Set-Tweak 'HKCU\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
            Set-Tweak 'HKCU\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1
        }),

    (New-Tweak -Id 'game.dvr' -Category 'Gaming' -Name 'Disable Game DVR background recording' `
        -Description 'Stops Xbox Game Bar from constantly recording gameplay in the background (frees GPU/disk). Manual capture still works when re-enabled.' `
        -Recommended $true -Apply {
            Set-Tweak 'HKCU\System\GameConfigStore' 'GameDVR_Enabled' 0
            Set-Tweak 'HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
        }),

    (New-Tweak -Id 'game.hags' -Category 'Gaming' -Name 'Hardware-accelerated GPU scheduling' `
        -Description 'Lets the GPU manage its own memory scheduling. Needs a supported GPU/driver (NVIDIA GTX 10+, AMD RX 5000+); required for DLSS Frame Generation. Reboot required.' `
        -Recommended $false -MinBuild 19041 -Apply {
            Set-Tweak 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
        }),

    (New-Tweak -Id 'game.windowed' -Category 'Gaming' -Name 'Optimizations for windowed games (Windows 11)' `
        -Description 'Runs DX10/DX11 games in windowed/borderless mode with the modern flip presentation model: lower latency and VRR/Auto HDR support. Other DirectX settings are kept.' `
        -Recommended $true -MinBuild 22000 -Apply {
            $cur = Get-RegValueInfo $script:DxPrefsKey 'DirectXUserGlobalSettings'
            $existing = if ($cur.Exists) { [string]$cur.Value } else { '' }
            $merged = Merge-DxSettingString $existing @{ SwapEffectUpgradeEnable = '1' }
            Set-Tweak $script:DxPrefsKey 'DirectXUserGlobalSettings' $merged 'String'
        }),

    (New-Tweak -Id 'game.hvci' -Category 'Gaming' -Name 'Turn off Memory Integrity (HVCI) and VBS' `
        -Description 'Removes the virtualization-based security overhead (about 5-15% in some games). Lowers protection against kernel malware. Reboot required.' `
        -Recommended $false -Warning $script:HvciWarning -Apply {
            Set-Tweak 'HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0
            Set-Tweak 'HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0
        }),

    (New-Tweak -Id 'game.mouseaccel' -Category 'Gaming' -Name 'Disable mouse acceleration' `
        -Description 'Turns off "Enhance pointer precision" for 1:1 mouse movement. Takes effect after sign-out.' `
        -Recommended $true -Apply {
            Set-Tweak 'HKCU\Control Panel\Mouse' 'MouseSpeed' '0' 'String'
            Set-Tweak 'HKCU\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'
            Set-Tweak 'HKCU\Control Panel\Mouse' 'MouseThreshold2' '0' 'String'
        }),

    (New-Tweak -Id 'game.stickykeys' -Category 'Gaming' -Name 'Disable Sticky Keys shortcut prompt' `
        -Description 'Pressing Shift 5 times no longer pops up the Sticky Keys dialog mid-game.' `
        -Recommended $true -Apply {
            Set-Tweak 'HKCU\Control Panel\Accessibility\StickyKeys' 'Flags' '506' 'String'
        }),

    # ---- Privacy / debloat ----
    (New-Tweak -Id 'priv.telemetry' -Category 'Privacy' -Name 'Minimize telemetry' `
        -Description 'Sets the diagnostic data policy to the lowest level and disables the Connected User Experiences (DiagTrack) service.' `
        -Recommended $true -Apply {
            Set-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
            Set-ServiceDisabled 'DiagTrack'
        }),

    (New-Tweak -Id 'priv.adid' -Category 'Privacy' -Name 'Disable advertising ID' `
        -Description 'Stops apps from using a per-user advertising ID for personalized ads.' -Recommended $true -Apply {
            Set-Tweak 'HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
            Set-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1
        }),

    (New-Tweak -Id 'priv.tailored' -Category 'Privacy' -Name 'Disable tailored experiences' `
        -Description 'Microsoft no longer uses diagnostic data for personalized tips and ads.' -Recommended $true -Apply {
            Set-Tweak 'HKCU\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
        }),

    (New-Tweak -Id 'priv.websearch' -Category 'Privacy' -Name 'Disable Bing/web results in Start search' `
        -Description 'Start menu search only searches your PC: faster and nothing typed is sent to Bing.' -Recommended $true -Apply {
            Set-Tweak 'HKCU\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
            Set-Tweak 'HKCU\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
        }),

    (New-Tweak -Id 'priv.suggestions' -Category 'Privacy' -Name 'Disable suggestions and silent app installs' `
        -Description 'No promoted apps in Start, no "suggested" content in Settings/lock screen, no auto-installed sponsored apps.' `
        -Recommended $true -Apply {
            foreach ($v in 'SilentInstalledAppsEnabled', 'SystemPaneSuggestionsEnabled', 'SoftLandingEnabled',
                           'PreInstalledAppsEnabled', 'OemPreInstalledAppsEnabled',
                           'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled',
                           'SubscribedContent-338393Enabled', 'SubscribedContent-353694Enabled',
                           'SubscribedContent-353696Enabled') {
                Set-Tweak $cdm $v 0
            }
        }),

    (New-Tweak -Id 'priv.copilot' -Category 'Privacy' -Name 'Turn off Windows Copilot' `
        -Description 'Policy that disables the built-in Windows Copilot sidebar/button. The newer standalone Copilot app can simply be uninstalled.' `
        -Recommended $true -Apply {
            Set-Tweak 'HKCU\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
            Set-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
        }),

    (New-Tweak -Id 'priv.widgets' -Category 'Privacy' -Name 'Disable Widgets / News and Interests' `
        -Description 'Removes the Widgets board (Windows 11) or News and Interests (Windows 10) from the taskbar.' `
        -Recommended $true -Apply {
            if ($script:OSBuild -ge 22000) {
                Set-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
            } else {
                Set-Tweak 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0
            }
        }),

    # ---- Quality of life ----
    (New-Tweak -Id 'qol.extensions' -Category 'Quality of life' -Name 'Show file extensions' `
        -Description 'Shows .exe/.pdf/etc. in Explorer, which also helps spot disguised malware like invoice.pdf.exe.' `
        -Recommended $true -Apply {
            Set-Tweak $explorerAdv 'HideFileExt' 0
        }),

    (New-Tweak -Id 'qol.hidden' -Category 'Quality of life' -Name 'Show hidden files' `
        -Description 'Shows hidden files and folders such as AppData in Explorer.' -Recommended $false -Apply {
            Set-Tweak $explorerAdv 'Hidden' 1
        }),

    (New-Tweak -Id 'qol.thispc' -Category 'Quality of life' -Name 'Open Explorer to This PC' `
        -Description 'File Explorer opens to This PC (drives) instead of Home/Quick access.' -Recommended $true -Apply {
            Set-Tweak $explorerAdv 'LaunchTo' 1
        }),

    (New-Tweak -Id 'qol.contextmenu' -Category 'Quality of life' -Name 'Classic right-click menu (Windows 11)' `
        -Description 'Restores the full Windows 10 style context menu without needing "Show more options".' `
        -Recommended $true -MinBuild 22000 -Apply {
            Set-Tweak 'HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '(default)' '' 'String'
        })
)

function Test-TweakSupported($Tweak) {
    return ($script:OSBuild -ge $Tweak.MinBuild)
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
function New-SafeRestorePoint {
    if ($script:RestorePointDone) { return $true }
    Write-Info 'Creating a System Restore point (this can take a minute)...'
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        Checkpoint-Computer -Description ("{0} - before tweaks {1}" -f $script:AppName, (Get-Date -Format 'yyyy-MM-dd HH:mm')) `
            -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Ok 'Restore point requested. (Windows allows only one per 24h; if one was made recently, it is reused.)'
    } catch {
        Write-Warn "Could not create a restore point: $($_.Exception.Message)"
        Write-Warn "$($script:AppName) still backs up every change to state.json, so Undo will work."
        if ($script:Interactive -and -not (Read-YesNo 'Continue without a restore point?' $true)) {
            return $false
        }
    }
    $script:RestorePointDone = $true
    return $true
}

function Invoke-Tweaks($List, [string[]]$PreConfirmed = @()) {
    $List = @($List)
    if ($List.Count -eq 0) { Write-Warn 'Nothing selected.'; return }

    $confirmed = @($PreConfirmed)
    foreach ($t in $List) {
        if (-not $t.Warning -or $confirmed -contains $t.Id) { continue }
        Write-Host ''
        Write-Warn $t.Name
        Write-Host $t.Warning -ForegroundColor Yellow
        if ($script:Interactive -and (Read-YesNo "Apply '$($t.Name)' anyway?" $false)) { $confirmed += $t.Id }
    }

    if (-not (New-SafeRestorePoint)) { Write-Warn 'Aborted.'; return }

    $ok = 0; $failed = 0; $skipped = 0
    foreach ($t in $List) {
        if (-not (Test-TweakSupported $t)) {
            Write-Warn "Skipping '$($t.Name)': requires Windows build $($t.MinBuild)+ (this PC: $($script:OSBuild))."
            $skipped++
            continue
        }
        if ($t.Warning -and $confirmed -notcontains $t.Id) {
            Write-Warn "Skipping '$($t.Name)': not confirmed."
            $skipped++
            continue
        }
        Write-Info "Applying: $($t.Name)"
        try {
            & $t.Apply
            if ($script:State.Applied -notcontains $t.Id) { [void]$script:State.Applied.Add($t.Id) }
            Save-State
            $ok++
        } catch {
            Write-Err "Failed '$($t.Name)': $($_.Exception.Message)"
            $failed++
        }
    }
    Write-Host ''
    Write-Ok "Done. Applied: $ok  Failed: $failed  Skipped: $skipped"
    Complete-Changes
}

function Undo-AllTweaks {
    $hasWork = ($script:State.Registry.Count -gt 0) -or ($script:State.PowerSettings.Count -gt 0) -or
        $script:State.PowerScheme -or $script:State.CreatedScheme
    if (-not $hasWork) { Write-Info 'Nothing to undo - no recorded changes.'; return }

    Write-Info "Restoring $($script:State.Registry.Count) registry value(s)..."
    $errors = 0
    $records = @($script:State.Registry)
    for ($i = $records.Count - 1; $i -ge 0; $i--) {
        $r = $records[$i]
        $display = if ($r.Name -eq '') { '(default)' } else { $r.Name }
        try {
            $s = Split-RegPath $r.Path
            $base = Get-BaseKey $s.Hive
            if ($r.Existed) {
                if ($r.Kind -eq 'Unknown') { Write-Warn "Cannot restore $($r.Path)\$display (unknown type), skipping."; continue }
                $key = $base.CreateSubKey($s.SubKey)
                try {
                    $key.SetValue($r.Name, (ConvertFrom-Storable $r.Kind $r.Value), [Microsoft.Win32.RegistryValueKind]$r.Kind)
                } finally { $key.Close() }
                Write-Host "      restored $($r.Path)\$display" -ForegroundColor DarkGray
            } else {
                $key = $base.OpenSubKey($s.SubKey, $true)
                if ($null -ne $key) {
                    try { $key.DeleteValue($r.Name, $false) } finally { $key.Close() }
                }
                Write-Host "      removed  $($r.Path)\$display" -ForegroundColor DarkGray
            }
        } catch {
            Write-Err "Failed to restore $($r.Path)\$display : $($_.Exception.Message)"
            $errors++
        }
    }

    $keys = @($script:State.CreatedKeys | Sort-Object -Property @{ Expression = { ($_ -split '\\').Count } } -Descending)
    foreach ($k in $keys) {
        try {
            $s = Split-RegPath $k
            $base = Get-BaseKey $s.Hive
            $key = $base.OpenSubKey($s.SubKey, $false)
            if ($null -eq $key) { continue }
            $empty = ($key.SubKeyCount -eq 0 -and $key.ValueCount -eq 0)
            $key.Close()
            if ($empty) {
                $base.DeleteSubKey($s.SubKey, $false)
                Write-Host "      deleted key $k" -ForegroundColor DarkGray
            } else {
                Write-Host "      kept key $k (not empty)" -ForegroundColor DarkGray
            }
        } catch {
            Write-Err "Failed to delete key $k : $($_.Exception.Message)"
            $errors++
        }
    }

    foreach ($svc in @($script:State.Services)) {
        $start = Get-RegValueInfo "HKLM\SYSTEM\CurrentControlSet\Services\$svc" 'Start'
        if ($start.Exists -and [int]$start.Value -eq 2) {
            Start-Service -Name $svc -ErrorAction SilentlyContinue
        }
    }

    $existingSchemes = @(Get-PowerSchemeGuids)
    $powerRecords = @($script:State.PowerSettings)
    for ($i = $powerRecords.Count - 1; $i -ge 0; $i--) {
        $p = $powerRecords[$i]
        # The plan created by the tool is deleted below, so there is nothing to restore in it.
        if ($p.Scheme -eq $script:State.CreatedScheme -or $existingSchemes -notcontains $p.Scheme) { continue }
        & powercfg.exe -setacvalueindex $p.Scheme $p.Sub $p.Setting ([int]$p.Value) 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "      restored power setting $($p.Sub)\$($p.Setting) = $($p.Value) on $($p.Scheme)" -ForegroundColor DarkGray
        } else {
            Write-Err "Failed to restore power setting $($p.Sub)\$($p.Setting) on $($p.Scheme)"
            $errors++
        }
    }

    if ($script:State.PowerScheme) {
        & powercfg.exe /setactive $script:State.PowerScheme | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok "Power plan restored ($($script:State.PowerScheme))." }
        else { Write-Err 'Could not restore the original power plan.'; $errors++ }
    }
    if ($script:State.CreatedScheme -and $script:State.CreatedScheme -ne $script:State.PowerScheme) {
        & powercfg.exe /delete $script:State.CreatedScheme | Out-Null
    }

    if ($errors -eq 0) {
        $archive = Join-Path $script:StateDir ("state.undone-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Move-Item -LiteralPath $script:StateFile -Destination $archive -Force -ErrorAction SilentlyContinue
        $script:State = New-EmptyState
        Write-Ok "Everything reverted. Old backup archived to $archive"
    } else {
        Save-State
        Write-Warn "$errors item(s) could not be reverted; state.json kept so you can retry. You can also use System Restore."
    }
    Complete-Changes
}

function Complete-Changes {
    Write-Info 'Some changes need an Explorer restart; mouse, HAGS, Memory Integrity/VBS, power throttling and policy changes need a sign-out or reboot.'
    if ($script:Interactive -and (Read-YesNo 'Restart Explorer now?' $false)) {
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
        Write-Ok 'Explorer restarted.'
    }
}

function Get-FolderSize([string]$Path) {
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return 0 }
    return [long]$sum
}

function Invoke-Maintenance([bool]$Deep) {
    Write-Info 'Maintenance 1/5: cleaning temp folders (files older than 24h, locked files skipped)...'
    $cutoff = (Get-Date).AddHours(-24)
    $targets = @($env:TEMP, (Join-Path $env:SystemRoot 'Temp')) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
    foreach ($dir in $targets) {
        $before = Get-FolderSize $dir
        $skipped = 0
        Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object {
                try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop }
                catch { $skipped++ }
            }
        $freed = [math]::Max(0, $before - (Get-FolderSize $dir))
        Write-Ok ("{0}: freed {1:N1} MB ({2} item(s) in use, skipped)" -f $dir, ($freed / 1MB), $skipped)
    }

    Write-Info 'Maintenance 2/5: cleaning up superseded Windows components (DISM)...'
    & "$env:SystemRoot\System32\dism.exe" /Online /Cleanup-Image /StartComponentCleanup
    if ($LASTEXITCODE -eq 0) { Write-Ok 'Component cleanup finished.' } else { Write-Warn "DISM exited with code $LASTEXITCODE." }

    if ($Deep) {
        Write-Info 'Deep repair: DISM /RestoreHealth (may take 10-30 minutes)...'
        & "$env:SystemRoot\System32\dism.exe" /Online /Cleanup-Image /RestoreHealth
        if ($LASTEXITCODE -ne 0) { Write-Warn "DISM RestoreHealth exited with code $LASTEXITCODE." }
        Write-Info 'Deep repair: sfc /scannow...'
        & "$env:SystemRoot\System32\sfc.exe" /scannow
    }

    Write-Info 'Maintenance 3/5: optimizing fixed drives (TRIM for SSDs, defrag for HDDs)...'
    $volumes = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter })
    foreach ($v in $volumes) {
        $letter = [string]$v.DriveLetter
        $media = 'Unspecified'
        try {
            $diskNumber = (Get-Partition -DriveLetter $letter -ErrorAction Stop | Select-Object -First 1).DiskNumber
            $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.DeviceId -eq [string]$diskNumber } | Select-Object -First 1
            if ($pd) { $media = [string]$pd.MediaType }
        } catch { }
        try {
            switch ($media) {
                'SSD'   { Write-Host "      ${letter}: SSD -> ReTrim" -ForegroundColor DarkGray; Optimize-Volume -DriveLetter $letter -ReTrim -ErrorAction Stop }
                'HDD'   { Write-Host "      ${letter}: HDD -> Defrag" -ForegroundColor DarkGray; Optimize-Volume -DriveLetter $letter -Defrag -ErrorAction Stop }
                default { Write-Host "      ${letter}: $media -> default optimization" -ForegroundColor DarkGray; Optimize-Volume -DriveLetter $letter -ErrorAction Stop }
            }
            Write-Ok "${letter}: optimized."
        } catch {
            Write-Warn "${letter}: $($_.Exception.Message)"
        }
    }

    Write-Info 'Maintenance 4/5: flushing DNS cache...'
    & ipconfig.exe /flushdns | Out-Null
    Write-Ok 'DNS cache flushed.'

    Write-Info 'Maintenance 5/5: startup apps (disable unneeded ones in Task Manager > Startup apps):'
    $startup = @(Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction SilentlyContinue)
    if ($startup.Count -eq 0) {
        Write-Host '      (none found)'
    } else {
        $startup | Sort-Object Name | Format-Table -AutoSize -Property Name, Location, Command |
            Out-String -Width 220 | Write-Host
    }
    Write-Ok 'Maintenance complete.'
}

function Show-Status {
    $edition = ''
    try { $edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).EditionID } catch { }
    $active = (& powercfg.exe /getactivescheme 2>$null) -join ' '
    Write-Host ''
    Write-Host "Windows build : $($script:OSBuild) $edition"
    Write-Host "Laptop        : $($script:IsLaptop)"
    Write-Host "Power plan    : $active"
    Write-Host "State file    : $($script:StateFile) ($($script:State.Registry.Count) registry backup(s))"
    Write-Host ''
    foreach ($group in ($script:Tweaks | Group-Object Category)) {
        Write-Host "  $($group.Name)" -ForegroundColor White
        foreach ($t in $group.Group) {
            if (-not (Test-TweakSupported $t)) { $mark = 'n/a'; $color = 'DarkGray' }
            elseif ($script:State.Applied -contains $t.Id) { $mark = 'ON '; $color = 'Green' }
            else { $mark = '-  '; $color = 'Gray' }
            Write-Host ("    [{0}] {1}" -f $mark, $t.Name) -ForegroundColor $color
        }
    }
    Write-Host ''
}

function Set-GameGpuPreference {
    Write-Host ''
    Write-Info 'Forces games onto the high-performance (discrete) GPU. This matters most on laptops with integrated + NVIDIA/AMD graphics.'
    Write-Host '  Paste the full path of a game .exe. Several paths can be pasted on one line, each in "quotes" or separated by ;' -ForegroundColor DarkGray
    Write-Host '  Enter one line at a time; an empty line finishes.' -ForegroundColor DarkGray
    $paths = New-Object System.Collections.Generic.List[string]
    while ($true) {
        $line = Read-Host 'Game .exe path'
        if ([string]::IsNullOrWhiteSpace($line)) { break }
        foreach ($p in (ConvertFrom-PathList $line)) { if (-not $paths.Contains($p)) { $paths.Add($p) } }
    }
    $valid = @()
    foreach ($p in $paths) {
        if ($p -notmatch '\.exe$') { Write-Warn "Not an .exe, skipping: $p"; continue }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
            if (-not (Read-YesNo "File not found: $p  Add it anyway?" $false)) { continue }
        }
        $valid += $p
    }
    if ($valid.Count -eq 0) { Write-Warn 'Nothing to do.'; return }
    if (-not (New-SafeRestorePoint)) { Write-Warn 'Aborted.'; return }
    foreach ($p in $valid) {
        try {
            $cur = Get-RegValueInfo $script:DxPrefsKey $p
            $existing = if ($cur.Exists) { [string]$cur.Value } else { '' }
            Set-Tweak $script:DxPrefsKey $p (Merge-DxSettingString $existing @{ GpuPreference = '2' }) 'String'
            Write-Ok "High-performance GPU set for $p"
        } catch {
            Write-Err "Failed for ${p}: $($_.Exception.Message)"
        }
    }
    Write-Info 'Restart the game for this to take effect. You can review it in Settings > System > Display > Graphics.'
}

# ---------------------------------------------------------------------------
# FPS Health Check (read-only)
# ---------------------------------------------------------------------------
function Write-Check([string]$Level, [string]$Label, [string]$Message, [string]$Fix = '') {
    $color = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } default { 'Cyan' } }
    Write-Host ("  [{0,-4}] {1,-16} {2}" -f $Level, $Label, $Message) -ForegroundColor $color
    if ($Fix) { Write-Host ("                          -> {0}" -f $Fix) -ForegroundColor DarkGray }
}

function Get-GpuKind([string]$Name) {
    if ($Name -match 'Basic Display|Basic Render|Remote Display|Virtual|Hyper-V|VMware|VirtualBox|Parsec|Citrix|DisplayLink|Mirage|Dameware') { return 'Virtual' }
    if ($Name -match 'NVIDIA|GeForce|Quadro|Radeon RX|Radeon Pro|Radeon VII|FirePro|Arc\S* A\d{3}|Arc\S* B\d{3}') { return 'Discrete' }
    if ($Name -match 'Intel|Radeon\S* Graphics|Radeon\S* \d{3}M|Vega \d+') { return 'Integrated' }
    return 'Unknown'
}

# $MemoryType is Win32_PhysicalMemory.SMBIOSMemoryType (26 = DDR4, 34 = DDR5).
function Get-RamVerdict([int]$Rated, [int]$Configured, [int]$MemoryType) {
    if ($Configured -gt 0 -and $Rated -gt 0 -and $Configured -lt $Rated) {
        return [pscustomobject]@{ Level = 'WARN'; Message = "running at $Configured MT/s, module is rated $Rated MT/s" }
    }
    if ($MemoryType -eq 26 -and $Configured -gt 0 -and $Configured -le 2666) {
        return [pscustomobject]@{ Level = 'WARN'; Message = "DDR4 at $Configured MT/s looks like the JEDEC default (most gaming kits are 3200-3600) - heuristic" }
    }
    if ($MemoryType -eq 34 -and $Configured -gt 0 -and $Configured -le 4800) {
        return [pscustomobject]@{ Level = 'WARN'; Message = "DDR5 at $Configured MT/s looks like the JEDEC default (most gaming kits are 5600-6400) - heuristic" }
    }
    if ($Configured -le 0) { return [pscustomobject]@{ Level = 'INFO'; Message = 'speed not reported' } }
    return [pscustomobject]@{ Level = 'OK'; Message = "running at $Configured MT/s" }
}

function Invoke-FpsHealthCheck {
    Write-Host ''
    Write-Host '  FPS HEALTH CHECK (read-only, nothing is changed)' -ForegroundColor White
    Write-Host '  The biggest real FPS gains are usually hardware/driver settings found here, not registry tweaks.' -ForegroundColor DarkGray
    Write-Host ''

    # Windows
    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $ver = "build $($script:OSBuild).$($cv.UBR) $($cv.DisplayVersion) $($cv.EditionID)"
        if ($script:OSBuild -ge 22000) { Write-Check 'OK' 'Windows' "Windows 11 $ver" }
        else { Write-Check 'INFO' 'Windows' "Windows 10 $ver" 'Windows 10 support ended Oct 2025; Windows 11 adds windowed-game optimizations.' }
    } catch { Write-Check 'INFO' 'Windows' "build $($script:OSBuild)" }

    # RAM
    try {
        $dimms = @(Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop)
        if ($dimms.Count -eq 0) { throw 'no memory modules reported' }
        $totalGb = [math]::Round((($dimms | Measure-Object -Property Capacity -Sum).Sum) / 1GB, 1)
        $worst = $null
        foreach ($d in $dimms) {
            $v = Get-RamVerdict ([int]$d.Speed) ([int]$d.ConfiguredClockSpeed) ([int]$d.SMBIOSMemoryType)
            if ($null -eq $worst -or $v.Level -eq 'WARN') { $worst = $v }
        }
        $fix = if ($worst.Level -eq 'WARN') {
            if ($script:IsLaptop) { 'Most laptops cannot change this. On desktops: enable XMP (Intel) / EXPO or DOCP (AMD) in BIOS: +10-20% in CPU-bound games.' }
            else { 'Enable XMP (Intel) / EXPO or DOCP (AMD) in BIOS. Often +10-20% FPS in CPU-bound games.' }
        } else { '' }
        Write-Check $worst.Level 'RAM speed' "$($worst.Message) ($totalGb GB total)" $fix
        if ($dimms.Count -eq 1) {
            Write-Check 'WARN' 'RAM channels' 'only 1 memory module found: probably single-channel' 'Dual-channel (2 matching sticks) can add 10-30% in CPU-bound games and on integrated GPUs.'
        } else {
            Write-Check 'OK' 'RAM channels' "$($dimms.Count) modules (dual-channel likely if they are in the right slots - see motherboard manual)"
        }
        if ($totalGb -lt 15) { Write-Check 'WARN' 'RAM size' "$totalGb GB" '16 GB is the practical minimum for modern games.' }
    } catch { Write-Check 'INFO' 'RAM' "could not read memory info: $($_.Exception.Message)" }

    # GPU, driver and refresh rate
    try {
        $gpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)
        $hasDiscrete = $false; $discreteDrivesDisplay = $false; $integratedDrivesDisplay = $false
        foreach ($g in $gpus) {
            $name = [string]$g.Name
            $kind = Get-GpuKind $name
            if ($kind -eq 'Virtual') { continue }
            $hasDisplay = ([int]$g.CurrentRefreshRate -gt 1)
            if ($kind -eq 'Discrete') { $hasDiscrete = $true; if ($hasDisplay) { $discreteDrivesDisplay = $true } }
            if ($kind -eq 'Integrated' -and $hasDisplay) { $integratedDrivesDisplay = $true }

            $drvDate = $g.DriverDate
            if ($drvDate -and -not ($drvDate -is [datetime])) {
                try { $drvDate = [Management.ManagementDateTimeConverter]::ToDateTime([string]$drvDate) } catch { $drvDate = $null }
            }
            $dateText = if ($drvDate -is [datetime]) { $drvDate.ToString('yyyy-MM-dd') } else { 'unknown date' }
            $msg = "$name ($kind) driver $($g.DriverVersion), $dateText"
            if ($name -match 'Basic Display') {
                Write-Check 'WARN' 'GPU driver' $msg 'No real GPU driver installed. Install it from NVIDIA / AMD / Intel.'
            } elseif ($drvDate -is [datetime] -and $drvDate -lt (Get-Date).AddMonths(-6)) {
                Write-Check 'WARN' 'GPU driver' $msg 'Driver is older than 6 months. Update from nvidia.com / amd.com / intel.com (new drivers often fix FPS in new games).'
            } else {
                Write-Check 'OK' 'GPU driver' $msg
            }

            if ($hasDisplay) {
                $cur = [int]$g.CurrentRefreshRate; $max = [int]$g.MaxRefreshRate
                if ($max -gt $cur + 1) {
                    Write-Check 'WARN' 'Refresh rate' "$cur Hz on $name, up to $max Hz reported (best-effort)" 'Settings > System > Display > Advanced display > choose the highest refresh rate. Use DisplayPort or HDMI 2.0+.'
                } else {
                    Write-Check 'OK' 'Refresh rate' "$cur Hz on $name"
                }
            }
        }
        if ($hasDiscrete -and $integratedDrivesDisplay -and -not $discreteDrivesDisplay) {
            if ($script:IsLaptop) {
                Write-Check 'INFO' 'Display output' 'display runs through the integrated GPU (normal on most laptops) - heuristic' 'Use [5] "Set games to use the high-performance GPU" so games render on the discrete GPU.'
            } else {
                Write-Check 'WARN' 'Display output' 'monitor seems connected to the motherboard (integrated GPU) while a graphics card exists - heuristic' 'Plug the monitor cable into the graphics card, not the motherboard. This can be a 2-5x FPS difference.'
            }
        }
    } catch { Write-Check 'INFO' 'GPU' "could not read GPU info: $($_.Exception.Message)" }

    # Power plan
    try {
        $activeLine = (& powercfg.exe /getactivescheme 2>$null) -join ' '
        $guid = Get-FirstGuid $activeLine
        $planName = if ($activeLine -match '\(([^)]+)\)\s*$') { $Matches[1] } else { $guid }
        if ($guid -in '381b4222-f694-41f0-9685-ff5bb260df2e', 'a1841308-3541-4fab-bc81-f71556f20b4a') {
            $lvl = if ($script:IsLaptop) { 'INFO' } else { 'WARN' }
            Write-Check $lvl 'Power plan' $planName 'Desktop: use the Ultimate/High Performance tweak. Laptop: keep Balanced but set the power mode slider to Best performance while plugged in.'
        } else {
            Write-Check 'OK' 'Power plan' $planName
        }
    } catch { Write-Check 'INFO' 'Power plan' 'could not read the active power plan' }

    # Game Mode / HAGS
    $gm = Get-RegValueInfo 'HKCU\Software\Microsoft\GameBar' 'AutoGameModeEnabled'
    if ($gm.Exists -and [int]$gm.Value -eq 0) { Write-Check 'WARN' 'Game Mode' 'OFF' 'Turn on Game Mode (tweak "Enable Game Mode").' }
    else { Write-Check 'OK' 'Game Mode' $(if ($gm.Exists) { 'ON' } else { 'ON (Windows default)' }) }

    $hags = Get-RegValueInfo 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
    if ($hags.Exists -and [int]$hags.Value -eq 2) { Write-Check 'OK' 'HW GPU sched.' 'ON' }
    else { Write-Check 'INFO' 'HW GPU sched.' 'OFF or default' 'Optional: turn on for supported GPUs (required for DLSS Frame Generation).' }

    # Memory Integrity / VBS
    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
        $hvciOn = (@($dg.SecurityServicesRunning) | Where-Object { [int]$_ -eq 2 }).Count -gt 0
        $vbsOn = ([int]$dg.VirtualizationBasedSecurityStatus -eq 2)
        if ($hvciOn) {
            Write-Check 'INFO' 'Memory Integr.' "ON (VBS running: $vbsOn)" 'Costs ~5-15% in some games. Optional opt-in tweak to turn off - read its security warning first.'
        } else {
            Write-Check 'OK' 'Memory Integr.' "OFF (VBS running: $vbsOn)"
        }
    } catch { Write-Check 'INFO' 'Memory Integr.' 'status not available on this system' }

    # Disk space
    try {
        $sys = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -ErrorAction Stop
        if ($sys -and [double]$sys.Size -gt 0) {
            $pct = [math]::Round(100 * [double]$sys.FreeSpace / [double]$sys.Size, 1)
            $freeGb = [math]::Round([double]$sys.FreeSpace / 1GB, 1)
            if ($pct -lt 15) { Write-Check 'WARN' 'System drive' "$($env:SystemDrive) $freeGb GB free ($pct%)" 'Free up space (Maintenance, uninstall unused games). Low space slows updates, shader caches and the page file.' }
            else { Write-Check 'OK' 'System drive' "$($env:SystemDrive) $freeGb GB free ($pct%)" }
        }
    } catch { Write-Check 'INFO' 'System drive' 'could not read free space' }

    # Top processes
    Write-Host ''
    Write-Host '  Top 5 processes by CPU right now:' -ForegroundColor White
    try {
        $cores = [Environment]::ProcessorCount
        $perf = @(Get-CimInstance -ClassName Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop |
            Where-Object { $_.Name -notin '_Total', 'Idle' } |
            Sort-Object -Property PercentProcessorTime -Descending | Select-Object -First 5)
        foreach ($p in $perf) {
            Write-Host ("    {0,-36} {1,6:N1} %" -f $p.Name, ([double]$p.PercentProcessorTime / $cores))
        }
    } catch {
        Write-Host '    (live CPU counters unavailable; showing total CPU time since start)' -ForegroundColor DarkGray
        Get-Process -ErrorAction SilentlyContinue | Sort-Object -Property CPU -Descending | Select-Object -First 5 |
            ForEach-Object { Write-Host ("    {0,-36} {1,8:N0} s" -f $_.ProcessName, $_.CPU) }
    }
    Write-Host '  Top 5 processes by RAM:' -ForegroundColor White
    Get-Process -ErrorAction SilentlyContinue | Sort-Object -Property WorkingSet64 -Descending | Select-Object -First 5 |
        ForEach-Object { Write-Host ("    {0,-36} {1,8:N0} MB" -f $_.ProcessName, ($_.WorkingSet64 / 1MB)) }

    Write-Host ''
    Write-Host '  BIOS / driver checklist (cannot be checked or changed from Windows reliably):' -ForegroundColor White
    Write-Host '    - XMP / EXPO / DOCP memory profile enabled in BIOS'
    Write-Host '    - Resizable BAR (Re-Size BAR / Smart Access Memory) enabled in BIOS + Above 4G decoding'
    Write-Host '    - Latest BIOS, chipset driver and GPU driver from the vendor'
    Write-Host '    - Monitor plugged into the graphics card, highest refresh rate selected, G-Sync/FreeSync on'
    Write-Host '    - Good CPU/GPU temperatures (clean dust, check fans): thermal throttling costs a lot of FPS'
    Write-Host ''
}

function Invoke-MaxFpsPreset {
    $list = @($script:Tweaks | Where-Object { $_.Recommended -and (Test-TweakSupported $_) })
    $powerIds = 'perf.powerplan', 'perf.cpupower', 'perf.powerthrottle'
    if ($script:IsLaptop) {
        Write-Warn 'Laptop detected: the power plan, core unparking and power throttling tweaks are skipped (heat, battery life).'
        if (Read-YesNo 'Apply them anyway (only sensible if the laptop is always plugged in)?' $false) {
            $list += @($script:Tweaks | Where-Object { $powerIds -contains $_.Id -and $list -notcontains $_ })
        }
    }
    $preConfirmed = @()
    $hvci = $script:Tweaks | Where-Object { $_.Id -eq 'game.hvci' } | Select-Object -First 1
    Write-Host ''
    Write-Host $script:HvciWarning -ForegroundColor Yellow
    if (Read-YesNo 'Also turn off Memory Integrity (HVCI) and VBS?' $false) {
        $list += $hvci
        $preConfirmed += $hvci.Id
    }
    Write-Host ''
    foreach ($t in $list) { Write-Host "  - $($t.Name)" }
    if (-not (Read-YesNo "Apply these $($list.Count) tweaks?" $true)) { return }
    Invoke-Tweaks $list $preConfirmed
    Write-Info 'Next: run [4] FPS Health Check, and on laptops use [5] to put games on the discrete GPU.'
}

function ConvertFrom-Selection([string]$Text, [int]$Max) {
    $result = New-Object System.Collections.Generic.List[int]
    foreach ($tok in ($Text -split '[,\s]+')) {
        if ($tok -match '^(\d+)-(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            if ($a -gt $b) { $tmp = $a; $a = $b; $b = $tmp }
            for ($i = $a; $i -le $b; $i++) { if ($i -ge 1 -and $i -le $Max -and -not $result.Contains($i)) { $result.Add($i) } }
        } elseif ($tok -match '^\d+$') {
            $i = [int]$tok
            if ($i -ge 1 -and $i -le $Max -and -not $result.Contains($i)) { $result.Add($i) }
        }
    }
    return $result.ToArray()
}

function Show-PickMenu {
    $available = @($script:Tweaks | Where-Object { Test-TweakSupported $_ })
    Write-Host ''
    Write-Host '  [R] = recommended   [ON] = already applied   (!) = asks for confirmation first' -ForegroundColor DarkGray
    $lastCategory = ''
    for ($i = 0; $i -lt $available.Count; $i++) {
        $t = $available[$i]
        if ($t.Category -ne $lastCategory) {
            Write-Host ''
            Write-Host "  $($t.Category)" -ForegroundColor White
            $lastCategory = $t.Category
        }
        $rec = if ($t.Recommended) { '[R]' } else { '   ' }
        $on  = if ($script:State.Applied -contains $t.Id) { '[ON]' } else { '    ' }
        $warn = if ($t.Warning) { ' (!)' } else { '' }
        Write-Host ("  {0,3}. {1} {2} {3}{4}" -f ($i + 1), $rec, $on, $t.Name, $warn)
        Write-Host ("            {0}" -f $t.Description) -ForegroundColor DarkGray
    }
    Write-Host ''
    $answer = Read-Host 'Enter numbers to apply (e.g. 1,3,5-7), A = all recommended, blank = back'
    if ([string]::IsNullOrWhiteSpace($answer)) { return }
    if ($answer.Trim() -match '^(a|all)$') {
        Invoke-Tweaks ($available | Where-Object { $_.Recommended })
        return
    }
    $picked = @(ConvertFrom-Selection $answer $available.Count)
    Invoke-Tweaks ($picked | ForEach-Object { $available[$_ - 1] })
}

function Show-MainMenu {
    while ($true) {
        Write-Host ''
        Write-Host '  +========================================================+' -ForegroundColor DarkCyan
        Write-Host '  |                                                        |' -ForegroundColor DarkCyan
        Write-Host '  |           ### ##### ##### #   #  ###  #   #            |' -ForegroundColor Cyan
        Write-Host '  |            #    #      #  #   # #   # #  #             |' -ForegroundColor Cyan
        Write-Host '  |            #    #     #   ##### ##### ###              |' -ForegroundColor Cyan
        Write-Host '  |            #    #    #    #   # #   # #  #             |' -ForegroundColor Cyan
        Write-Host '  |           ###   #   ##### #   # #   # #   #            |' -ForegroundColor Cyan
        Write-Host '  |                                                        |' -ForegroundColor DarkCyan
        Write-Host '  |                    ITZHAK PC TWEAKS                    |' -ForegroundColor White
        Write-Host '  |         performance - gaming - privacy - undo          |' -ForegroundColor DarkGray
        Write-Host '  +========================================================+' -ForegroundColor DarkCyan
        Write-Host "  Windows build $($script:OSBuild)$(if ($script:IsLaptop) { '  (laptop detected)' })"
        Write-Host ''
        Write-Host '  [1] Apply recommended tweaks'
        Write-Host '  [2] MAX FPS preset (recommended + desktop power tweaks + optional Memory Integrity off)'
        Write-Host '  [3] Pick tweaks individually'
        Write-Host '  [4] FPS Health Check (read-only: RAM/XMP, refresh rate, GPU driver...)'
        Write-Host '  [5] Set games to use the high-performance GPU'
        Write-Host '  [6] Maintenance (cleanup, drive optimization)'
        Write-Host '  [7] Undo all tweaks'
        Write-Host '  [8] Status'
        Write-Host '  [Q] Quit'
        Write-Host ''
        $choice = (Read-Host 'Choose').Trim().ToUpperInvariant()
        switch ($choice) {
            '1' {
                $list = @($script:Tweaks | Where-Object { $_.Recommended -and (Test-TweakSupported $_) })
                Write-Host ''
                foreach ($t in $list) { Write-Host "  - $($t.Name)" }
                if (Read-YesNo "Apply these $($list.Count) tweaks?" $true) { Invoke-Tweaks $list }
            }
            '2' { Invoke-MaxFpsPreset }
            '3' { Show-PickMenu }
            '4' { Invoke-FpsHealthCheck }
            '5' { Set-GameGpuPreference }
            '6' {
                $deep = Read-YesNo 'Also run DISM RestoreHealth + SFC system file repair (slow, 10-30 min)?' $false
                Invoke-Maintenance $deep
            }
            '7' {
                if (Read-YesNo "Revert every change $($script:AppName) has made?" $false) { Undo-AllTweaks }
            }
            '8' { Show-Status }
            'Q' { return }
            default { Write-Warn 'Unknown option.' }
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$logFile = Join-Path $script:StateDir ("ItzhakPCTweaks-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$transcribing = $false
try { Start-Transcript -LiteralPath $logFile -ErrorAction Stop | Out-Null; $transcribing = $true } catch { }
Write-Info "$($script:AppName) started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

try {
    if ($script:Interactive) {
        Show-MainMenu
    } else {
        if ($Undo) {
            Undo-AllTweaks
        } elseif ($Recommended) {
            Invoke-Tweaks ($script:Tweaks | Where-Object { $_.Recommended -and (Test-TweakSupported $_) })
        }
        if ($Maintenance) {
            Invoke-Maintenance ([bool]$DeepRepair)
        }
        if ($HealthCheck) {
            Invoke-FpsHealthCheck
        }
    }
} finally {
    if ($transcribing) { Stop-Transcript | Out-Null }
}
Write-Host "$($script:AppName) log: $logFile"
