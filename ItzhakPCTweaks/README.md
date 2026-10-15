# ITZHAK PC TWEAKS

A safe, reversible tweak tool for Windows 10/11. It covers performance, gaming, privacy/debloat and quality-of-life settings, plus a maintenance routine. Every change is backed up and can be undone.

It contains no placebo or risky tweaks. It does **not** disable Defender, Windows Update, UAC or CPU security mitigations.

## How to run

1. Download the `ItzhakPCTweaks` folder.
2. Double-click **`Run-ItzhakPCTweaks.bat`** and accept the UAC prompt.
3. Pick an option from the menu:

```
[1] Apply recommended tweaks
[2] Pick tweaks individually
[3] Maintenance (cleanup, drive optimization)
[4] Undo all tweaks
[5] Status
[Q] Quit
```

Non-interactive use (from an elevated PowerShell, or pass the same switches to the `.bat`):

```powershell
powershell -ExecutionPolicy Bypass -File .\ItzhakPCTweaks.ps1 -Recommended
powershell -ExecutionPolicy Bypass -File .\ItzhakPCTweaks.ps1 -Maintenance [-DeepRepair]
powershell -ExecutionPolicy Bypass -File .\ItzhakPCTweaks.ps1 -Undo
```

Before the first change, ITZHAK PC TWEAKS creates a System Restore point. Logs and the backup file are written to `C:\ProgramData\ItzhakPCTweaks\`.

## Tweaks

`R` = included in "Apply recommended".

| Category | Tweak | R | What it does |
|---|---|---|---|
| Performance | Ultimate/High Performance power plan | R* | Activates a copy of the Ultimate Performance plan, or High Performance as a fallback. *Skipped on laptops. |
| Performance | Reduce UI animations | R | `MenuShowDelay=0`, no minimize/maximize or taskbar animations. |
| Performance | Block Store apps in background | | Policy `LetAppsRunInBackground=2`. Can delay notifications from Store apps. |
| Performance | Remove startup app delay | R | `Serialize\StartupDelayInMSec=0` |
| Performance | Prioritize games in MMCSS | R | `SystemResponsiveness=10`; Games task: GPU Priority 8, Priority 6, Scheduling/SFIO High. |
| Gaming | Game Mode on | R | `AutoGameModeEnabled=1` |
| Gaming | Disable Game DVR background recording | R | `GameDVR_Enabled=0`, `AppCaptureEnabled=0` |
| Gaming | Hardware-accelerated GPU scheduling | | `HwSchMode=2` (build 19041+). Needs a supported GPU/driver. Reboot required. |
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

### Maintenance (cannot be undone, and doesn't need to be)

- Deletes files older than 24 hours from your user `%TEMP%` and `C:\Windows\Temp`. Locked files are skipped.
- Runs `DISM /StartComponentCleanup` to remove superseded Windows Update components.
- Optional deep repair: runs `DISM /RestoreHealth` and `sfc /scannow`.
- Runs `Optimize-Volume` on fixed drives: TRIM on SSDs, defrag on HDDs.
- Runs `ipconfig /flushdns`.
- Lists your startup apps so you can disable unneeded ones in Task Manager > Startup apps.

## Undo

Menu option **[4]** or `-Undo` reverts everything recorded in `C:\ProgramData\ItzhakPCTweaks\state.json`:

- Registry values that existed before are restored with their original value and type.
- Values that didn't exist before are deleted.
- Registry keys the tool created are deleted, but only if they are empty.
- Services get their original startup type back.
- The original power plan is re-activated, and the plan the tool created is deleted.

If you used an older version of the tool (named PCTweaks), its backup at `C:\ProgramData\PCTweaks\state.json` is migrated to the new folder automatically on the next run, so Undo still covers those changes.

After a successful undo, the backup is archived as `state.undone-<date>.json`. You can also roll back with System Restore, using the restore point named "ITZHAK PC TWEAKS - before tweaks ...".

## Caveats

- **HKCU settings apply to the account that runs the elevated script.** If you sign in as a standard user and type an admin's credentials at the UAC prompt, the per-user tweaks go to the admin's profile. Run it from an account that is itself an administrator.
- **`AllowTelemetry=0` (Security level) only fully applies on Enterprise, Education and Server.** On Home and Pro, Windows treats it as "Required diagnostic data". Disabling DiagTrack still cuts most telemetry traffic.
- Some changes need an Explorer restart; the tool offers to do it. Mouse, HAGS and policy changes need a sign-out or reboot.
- Laptop detection uses `Win32_Battery`, so a desktop with a UPS may be treated as a laptop. You can still pick the power plan manually in [2].
- Windows creates at most one restore point per 24 hours by default. If one was made recently, a new one isn't created, but `state.json` still lets you undo.
- Windows feature updates sometimes reset some of these settings. Just run the tool again.
- Policy keys (`HKLM\SOFTWARE\Policies\...`) may make Settings show "Some settings are managed by your organization". This is expected and goes away after undo.
