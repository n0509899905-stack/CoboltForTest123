<#
.SYNOPSIS
    ITZHAK PC TWEAKS - safe, reversible performance / gaming / privacy / quality-of-life tweaks for Windows 10/11.

.DESCRIPTION
    Interactive menu (run with no parameters) or non-interactive via switches.
    Every registry change is backed up to $env:ProgramData\ItzhakPCTweaks\state.json before it is made,
    so "Undo all" can restore the original values, remove values that did not exist, and delete
    registry keys the tool created. A System Restore point is created before the first change.
    State from older versions ($env:ProgramData\PCTweaks\state.json) is migrated automatically.

.PARAMETER Recommended
    Apply all tweaks marked as recommended, without prompting.

.PARAMETER Undo
    Revert every change recorded in state.json, without prompting.

.PARAMETER Maintenance
    Run the maintenance routine (temp cleanup, component store cleanup, drive optimization, DNS flush).

.PARAMETER DeepRepair
    With -Maintenance: also run DISM /RestoreHealth and sfc /scannow (slow).

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
    [switch]$DeepRepair
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

$script:Interactive = -not ($Recommended -or $Undo -or $Maintenance)
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
        [scriptblock]$Apply
    )
    [pscustomobject]@{
        Id          = $Id
        Category    = $Category
        Name        = $Name
        Description = $Description
        Recommended = $Recommended
        MinBuild    = $MinBuild
        Apply       = $Apply
    }
}

$explorerAdv = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$cdm = 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'

$script:Tweaks = @(
    # ---- Performance ----
    (New-Tweak -Id 'perf.powerplan' -Category 'Performance' -Name 'Ultimate/High Performance power plan' `
        -Description 'Keeps CPU clocks up and disables aggressive power saving. Not recommended on laptops.' `
        -Recommended (-not $script:IsLaptop) -Apply { Set-HighPerformancePowerPlan }),

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

function Invoke-Tweaks($List) {
    $List = @($List)
    if ($List.Count -eq 0) { Write-Warn 'Nothing selected.'; return }
    if (-not (New-SafeRestorePoint)) { Write-Warn 'Aborted.'; return }

    $ok = 0; $failed = 0; $skipped = 0
    foreach ($t in $List) {
        if (-not (Test-TweakSupported $t)) {
            Write-Warn "Skipping '$($t.Name)': requires Windows build $($t.MinBuild)+ (this PC: $($script:OSBuild))."
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
    $hasWork = ($script:State.Registry.Count -gt 0) -or $script:State.PowerScheme -or $script:State.CreatedScheme
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
    Write-Info 'Some changes need an Explorer restart; mouse, HAGS and policy changes need a sign-out or reboot.'
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
    Write-Host '  [R] = recommended   [ON] = already applied' -ForegroundColor DarkGray
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
        Write-Host ("  {0,3}. {1} {2} {3}" -f ($i + 1), $rec, $on, $t.Name)
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
        Write-Host '  [2] Pick tweaks individually'
        Write-Host '  [3] Maintenance (cleanup, drive optimization)'
        Write-Host '  [4] Undo all tweaks'
        Write-Host '  [5] Status'
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
            '2' { Show-PickMenu }
            '3' {
                $deep = Read-YesNo 'Also run DISM RestoreHealth + SFC system file repair (slow, 10-30 min)?' $false
                Invoke-Maintenance $deep
            }
            '4' {
                if (Read-YesNo "Revert every change $($script:AppName) has made?" $false) { Undo-AllTweaks }
            }
            '5' { Show-Status }
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
    }
} finally {
    if ($transcribing) { Stop-Transcript | Out-Null }
}
Write-Host "$($script:AppName) log: $logFile"
