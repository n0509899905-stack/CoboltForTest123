# ITZHAK PC TWEAKS

A safe, reversible tweak tool for Windows 10/11. It covers performance, gaming, privacy/debloat and quality-of-life settings, plus a maintenance routine. Every change is backed up and can be undone.

It contains no placebo tweaks. It does **not** disable Defender, Windows Update, UAC or CPU security mitigations. The only security-related option, turning off Memory Integrity, is opt-in and comes with a warning.

## How to run

1. Download the `ItzhakPCTweaks` folder.
2. Double-click **`Run-ItzhakPCTweaks.bat`** and accept the UAC prompt.
3. Pick an option from the menu:

```
[1] Apply recommended tweaks
[2] MAX FPS preset (recommended + desktop power tweaks + optional Memory Integrity off)
[3] Pick tweaks individually
[4] FPS Health Check (read-only: RAM/XMP, refresh rate, GPU driver...)
[5] Set games to use the high-performance GPU
[6] Maintenance (cleanup, drive optimization)
[7] Undo all tweaks
[8] Status
[Q] Quit
```

Non-interactive use (from an elevated PowerShell, or pass the same switches to the `.bat`):

```powershell
powershell -ExecutionPolicy Bypass -File .\ItzhakPCTweaks.ps1 -Recommended
powershell -ExecutionPolicy Bypass -File .\ItzhakPCTweaks.ps1 -Maintenance [-DeepRepair]
powershell -ExecutionPolicy Bypass -File .\ItzhakPCTweaks.ps1 -HealthCheck
powershell -ExecutionPolicy Bypass -File .\ItzhakPCTweaks.ps1 -Undo
```

## Getting more FPS: what actually helps

Be realistic: Windows tweaks usually give **0-10%**, mostly in 1% lows and stutter, and mostly in CPU-bound games. The large wins usually come from hardware and driver settings that are wrong out of the box. **Run [4] FPS Health Check first.** It checks:

| Check | Why it matters | Typical gain when fixed |
|---|---|---|
| RAM running below its rated speed (XMP/EXPO off) | Most PCs run RAM at the slow JEDEC default until XMP/EXPO is enabled in BIOS | +10-20% in CPU-bound games |
| Only one RAM stick (single-channel) | Halves memory bandwidth | +10-30% in CPU-bound games and on integrated GPUs |
| Monitor below its max refresh rate | Windows often defaults to 60 Hz on a 144/165/240 Hz monitor | Smoother and lower latency (FPS above 60 becomes visible) |
| Monitor plugged into the motherboard instead of the graphics card (desktop) | The game may run on, or be copied through, the integrated GPU | Can be 2-5x |
| GPU driver older than ~6 months, or no driver | New drivers include per-game fixes | 0-20% in new games |
| Balanced/Power saver plan, Game Mode off, Memory Integrity on, low disk space, heavy background processes | Each one is reported with a fix | Small to moderate |

The refresh-rate and display-output checks are best-effort heuristics (Windows does not always report these reliably), and they're labeled that way in the report.

### BIOS / driver checklist

- Enable **XMP** (Intel) or **EXPO / DOCP** (AMD) for the RAM.
- Enable **Resizable BAR** (also called Re-Size BAR or Smart Access Memory) and **Above 4G decoding**.
- Install the latest **BIOS**, **chipset driver** and **GPU driver** from the manufacturer (nvidia.com, amd.com, intel.com), not just Windows Update.
- Plug the monitor into the **graphics card**, select its highest refresh rate in Display settings, and turn on G-Sync/FreeSync.
- Keep CPU/GPU temperatures in check: clean dust and check the fans. Thermal throttling costs a lot of FPS.
- Laptops: game while plugged in, set the Windows power mode to "Best performance", and use [5] so games run on the discrete GPU.

### MAX FPS preset [2]

Applies every recommended tweak. On desktops that includes the power plan, core unparking and power-throttling tweaks; on laptops they're skipped unless you confirm. It then asks separately (default **No**) whether to turn off Memory Integrity/VBS, showing the security warning first. Everything it does can be undone with [7].

### Set games to use the high-performance GPU [5]

Paste the full path of one or more game `.exe` files: one per line, or several on one line in `"quotes"` or separated by `;`. The tool writes `GpuPreference=2;` for each one to `HKCU\Software\Microsoft\DirectX\UserGpuPreferences`, which is the same setting as Settings > System > Display > Graphics. Other settings already stored for that exe are kept. This is a big deal on laptops with integrated + NVIDIA/AMD graphics, where games sometimes start on the integrated GPU. Undo removes or restores these values too.

Before the first change, ITZHAK PC TWEAKS creates a System Restore point. Logs and the backup file are written to `C:\ProgramData\ItzhakPCTweaks\`.

## Tweaks

`R` = included in "Apply recommended".

| Category | Tweak | R | What it does |
|---|---|---|---|
| Performance | Ultimate/High Performance power plan | R* | Activates a copy of the Ultimate Performance plan, or High Performance as a fallback. *Skipped on laptops. |
| Performance | Unpark CPU cores, keep clocks/USB/PCIe awake | R* | On that power plan (AC): `CPMINCORES=100`, `PROCTHROTTLEMIN=100`, USB selective suspend off, PCIe `ASPM=0`. The original values are backed up. Helps clock ramp-up stutter and 1% lows (roughly 0-5%). *Skipped on laptops. |
| Performance | Disable power throttling | R* | `Control\Power\PowerThrottling\PowerThrottlingOff=1`. Stops Windows from throttling background/minimized apps (a game while alt-tabbed, OBS, Discord). Mostly matters on hybrid Intel 12th gen+ CPUs. Reboot required. *Skipped on laptops. |
| Performance | Reduce UI animations | R | `MenuShowDelay=0`, no minimize/maximize or taskbar animations. |
| Performance | Block Store apps in background | | Policy `LetAppsRunInBackground=2`. Can delay notifications from Store apps. |
| Performance | Remove startup app delay | R | `Serialize\StartupDelayInMSec=0` |
| Performance | Prioritize games in MMCSS | R | `SystemResponsiveness=10`; Games task: GPU Priority 8, Priority 6, Scheduling/SFIO High. |
| Performance | Stop Edge running in the background | R | Policies `Edge\BackgroundModeEnabled=0`, `StartupBoostEnabled=0`. Frees RAM/CPU used by a hidden Edge. Edge shows "managed by your organization". |
| Performance | Disable Windows Search indexing | | Disables the `WSearch` service. Start/Explorer search becomes much slower. Only if indexing causes disk/CPU spikes. |
| Performance | Disable SysMain (Superfetch) | | Disables the `SysMain` service. Only worth trying on SSD-only systems; on HDDs apps start slower. |
| Gaming | Game Mode on | R | `AutoGameModeEnabled=1` |
| Gaming | Disable Game DVR background recording | R | `GameDVR_Enabled=0`, `AppCaptureEnabled=0` |
| Gaming | Hardware-accelerated GPU scheduling | | `HwSchMode=2` (build 19041+). Needs a supported GPU/driver. Reboot required. |
| Gaming | Optimizations for windowed games (Win11) | R | Adds `SwapEffectUpgradeEnable=1` to `DirectXUserGlobalSettings` and keeps the other entries. DX10/11 games in windowed/borderless mode get flip-model presentation: lower latency, VRR and Auto HDR work. Build 22000+. |
| Gaming | Turn off Memory Integrity (HVCI) and VBS | (!) | `HypervisorEnforcedCodeIntegrity\Enabled=0`, `DeviceGuard\EnableVirtualizationBasedSecurity=0`. See the warning below. Reboot required. |
| Gaming | Disable mouse acceleration | R | Turns off "Enhance pointer precision". |
| Gaming | Disable Sticky Keys prompt | R | Pressing Shift 5 times no longer opens the Sticky Keys dialog. |
| Privacy | Minimize telemetry | R | `AllowTelemetry=0` policy and disables the DiagTrack service. |
| Privacy | Disable advertising ID | R | Turns off the per-user advertising ID (user setting and policy). |
| Privacy | Disable tailored experiences | R | Stops tips and ads based on diagnostic data. |
| Privacy | Disable Bing in Start search | R | `BingSearchEnabled=0`, `DisableSearchBoxSuggestions=1` |
| Privacy | Disable suggestions / silent app installs | R | ContentDeliveryManager: no promoted or auto-installed apps, no "suggested" content. |
| Privacy | Turn off Windows Copilot | R | `TurnOffWindowsCopilot=1` policy (HKCU and HKLM). |
| Privacy | Disable Widgets / News and Interests | R | Win11: `Dsh\AllowNewsAndInterests=0`. Win10: `Windows Feeds\EnableFeeds=0`. |
| QoL | Show file extensions | R | `HideFileExt=0` |
| QoL | Show hidden files | | `Hidden=1` |
| QoL | Explorer opens to This PC | R | `LaunchTo=1` |
| QoL | Classic right-click menu (Win11) | R | Restores the full context menu (build 22000+). |

`(!)` = never applied automatically. It shows a warning and asks for confirmation (default No).

### Memory Integrity / VBS: security trade-off

Memory Integrity (HVCI) and Virtualization-Based Security protect the Windows kernel against malicious or vulnerable drivers. Microsoft itself documents turning them off as an option for gaming performance. The gain is roughly 5-15% in some CPU-heavy games and close to zero in many others. Turning them off lowers your protection against kernel-level malware. Some anti-cheat systems and Windows 11 security features check for or require these protections, so if a game or feature stops working, turn them back on with Undo. If Memory Integrity was turned on by your organization or locked in UEFI, the registry change may not take effect. The FPS Health Check shows the current state.

### Not included on purpose

The tool does not include tweaks that are placebo or that trade safety for nothing measurable: Nagle/TCP "gaming" tweaks, timer resolution changes, bcdedit tricks (`disabledynamictick`, `useplatformclock`...), or disabling Defender, Windows Update or Spectre/Meltdown mitigations.

### Maintenance (cannot be undone, and doesn't need to be)

- Deletes files older than 24 hours from your user `%TEMP%` and `C:\Windows\Temp`. Locked files are skipped.
- Runs `DISM /StartComponentCleanup` to remove superseded Windows Update components.
- Optional deep repair: runs `DISM /RestoreHealth` and `sfc /scannow`.
- Runs `Optimize-Volume` on fixed drives: TRIM on SSDs, defrag on HDDs.
- Runs `ipconfig /flushdns`.
- Lists your startup apps so you can disable unneeded ones in Task Manager > Startup apps.

## Undo

Menu option **[7]** or `-Undo` reverts everything recorded in `C:\ProgramData\ItzhakPCTweaks\state.json`:

- Registry values that existed before are restored with their original value and type. This includes `DirectXUserGlobalSettings` and per-game GPU preferences.
- Values that didn't exist before are deleted.
- Registry keys the tool created are deleted, but only if they are empty.
- Services get their original startup type back.
- Power plan settings changed on a plan that already existed (core parking, minimum CPU state, USB suspend, PCIe ASPM) get their original values back.
- The original power plan is re-activated, and the plan the tool created is deleted.

If you used an older version of the tool (named PCTweaks), its backup at `C:\ProgramData\PCTweaks\state.json` is migrated to the new folder automatically on the next run, so Undo still covers those changes.

After a successful undo, the backup is archived as `state.undone-<date>.json`. You can also roll back with System Restore, using the restore point named "ITZHAK PC TWEAKS - before tweaks ...".

## Caveats

- **HKCU settings apply to the account that runs the elevated script.** If you sign in as a standard user and type an admin's credentials at the UAC prompt, the per-user tweaks go to the admin's profile. Run it from an account that is itself an administrator.
- **`AllowTelemetry=0` (Security level) only fully applies on Enterprise, Education and Server.** On Home and Pro, Windows treats it as "Required diagnostic data". Disabling DiagTrack still cuts most telemetry traffic.
- Some changes need an Explorer restart; the tool offers to do it. Mouse, HAGS, Memory Integrity/VBS, power throttling and policy changes need a sign-out or reboot.
- Laptop detection uses `Win32_Battery`, so a desktop with a UPS may be treated as a laptop. You can still pick the power tweaks manually in [3], or confirm them in [2].
- Windows creates at most one restore point per 24 hours by default. If one was made recently, a new one isn't created, but `state.json` still lets you undo.
- Windows feature updates sometimes reset some of these settings. Just run the tool again.
- Policy keys (`HKLM\SOFTWARE\Policies\...`) may make Settings show "Some settings are managed by your organization". This is expected and goes away after undo.
