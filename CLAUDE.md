# CLAUDE.md - Project Guidelines for CopyNewFilesFromMTP

## Project Overview

PowerShell script that copies files from an MTP-connected Android phone to a Windows PC, skipping files that already exist in specified backup locations. Includes a `.bat` wrapper and GitHub Actions workflow to build a self-contained `.exe` via ps2exe.

## Requirements

### Core Functionality
- Copy files from an Android phone connected via MTP to a target backup folder on Windows
- Deduplicate: skip files that already exist (matched by filename + file size) in one or more specified ignore folders
- The ignore folders parameter is called `-IgnoreFilesInFoldersBySizeAndName` and accepts a single path or an array of paths
- Also skip files that already exist in the target folder with the same name and size
- Preserve folder structure from the MTP source when copying

### Performance & Efficiency
- Must handle huge datasets: 500 GB+, hundreds of thousands of files
- Use HashSet for O(1) file lookups in the ignore index
- Use streaming I/O (StreamWriter) for index file creation
- Must NOT overload the PC: run at BelowNormal process priority with configurable throttle delay between operations

### Resume Support
- The user may unplug their phone and come back later
- State file tracks every processed file; re-running with the same parameters resumes from where it stopped
- MTP device scan results are cached to avoid re-scanning the phone on resume
- No file should be lost or skipped incorrectly during resume

### Progress Reporting
- Pre-scan the MTP source folder to count all files
- Show progress with each file: `[current/total | remaining | ETA]`
- Show file sizes in human-readable format

### MTP Path Discovery
- If a path segment is not found on the MTP device, list available items at the last valid parent level
- This helps users discover the correct path interactively

### Safety Checks
- If any specified ignore folder does not exist, is empty, or the generated index is empty: warn the user and ask for confirmation before continuing
- This prevents accidental full copies when the user made a typo in the folder path

### No-Arguments Help Display
- When the script is run without any arguments, display a help screen showing:
  - What the script does (description)
  - Version number
  - Build date
  - Usage examples
  - All available parameters
- Do NOT prompt for mandatory parameters; just show help and exit

### Disconnect/Retry Handling
- The user may disconnect the phone at any time, even mid-copy
- On any MTP error, the script enters a retry loop with exponential backoff (wait time doubles each attempt, capped at 10 minutes)
- During retry, the script attempts to reconnect to the MTP device and re-navigate to the source folder
- Configurable via:
  - `-RetryCount` (default: 30): maximum retries per file before escalating
  - `-RetryWaitSeconds` (default: 10): initial wait between retries, doubles each time
  - `-OnFinalFailure` (default: WaitForever): behavior after all retries exhausted
    - `WaitForever`: reset retry counter and keep trying indefinitely (user may plug phone back in later)
    - `Ask`: prompt the user to Skip, Retry, or Wait forever
    - `Skip`: automatically skip the file and continue
- The default `WaitForever` means the script never gives up on its own — it patiently waits for the phone to be reconnected
- When reconnect succeeds, retry immediately — do NOT wait out the remaining backoff timer

### Safe Copy with ~.tmp Files (Cloud-Sync Safe)
- Files are never kept at their final name until fully verified
- Flow: MTP CopyHere to target dir -> immediately rename to `~filename.tmp` -> set `Hidden` + `Temporary` attributes -> verify size -> clear attributes -> rename to final name
- `FILE_ATTRIBUTE_TEMPORARY` + `FILE_ATTRIBUTE_HIDDEN` causes Dropbox and OneDrive to ignore the file during sync
- The `~` prefix + `.tmp` extension matches Office temp file patterns, which cloud sync services also skip
- No separate temp folder is used — the `.tmp` file lives on the same volume as the target (atomic rename)
- Do NOT use `%TEMP%` or a temp folder on a different drive — the final move would not be atomic
- If the copy is interrupted, the `~.tmp` file is cleaned up before retrying
- This prevents broken/incomplete files from appearing in the backup or being synced to cloud

### Resume / Fresh Start Prompt
- When state files (index, scan cache, resume state) exist from a previous run, the user is asked whether to continue or start fresh
- Configurable via `-ResumeMode` (default: Ask):
  - `Ask`: prompt the user interactively (C to continue, F for fresh)
  - `Continue`: automatically resume without asking
  - `Fresh`: automatically clear all state files and start from scratch
- "Start fresh" deletes: file index, MTP scan cache, resume state, and any leftover `~*.tmp` files in the target
- The default for Continue is pressing Enter (no input needed)

### Scan-Only Mode
- `-ScanOnly` flag: only connect to MTP device, scan the source folder, list all files with sizes, and exit
- Does not require `-IgnoreFilesInFoldersBySizeAndName` or `-TargetFolder`
- Useful for testing MTP connection and path before running a full copy

## Versioning

- Version is stored in `$script:AppVersion` in the script (e.g., `"1.1.0"`)
- Build date is stored in `$script:AppBuildDate` (e.g., `"2026-04-03"`)
- **On every code change, increment at least the patch (last) digit of the version**
- The GitHub Actions release workflow stamps the tag version and current date into the script before building the EXE

## Timing Configuration

All timing values are defined as `$script:` variables in a single block near the top of the script (after version info). This is the single source of truth — do NOT hard-code timing values elsewhere.

| Variable | Default | Description |
|---|---|---|
| `CopyPollMs` | 50 | How often to check if a file has appeared/finished copying (ms) |
| `CopyProgressMs` | 500 | How often to update the spinner/percentage on screen (ms) |
| `CopyTimeoutMinutes` | 30 | Max time to wait for a single file copy before giving up |
| `StabilityCheckMs` | 200 | For unknown-size files: pause before re-checking if size stopped growing |
| `RetryBackoffMaxSeconds` | 600 | Cap for exponential backoff between retries (10 minutes) |
| `ScanYieldInterval` | 500 | Yield CPU every N files during MTP scan |
| `ScanYieldMs` | 1 | Duration of each yield pause during scan (ms) |

Retry wait times (`-RetryWaitSeconds`, `-RetryCount`) are command-line parameters, not in this block.

## Technical Constraints

### PowerShell 5.1 Compatibility
- The script must run on PowerShell 5.1 (pre-installed on Windows 10/11)
- Do NOT use `[System.IO.EnumerationOptions]` — it requires .NET Core / .NET 5+; use `Get-ChildItem -Recurse` instead
- The script file MUST have a UTF-8 BOM (`EF BB BF`) — PowerShell 5.1 reads files without BOM as ANSI, which corrupts non-ASCII characters (box-drawing, em-dashes) and causes parse errors
- Avoid `"|"` pipe characters inside `"$(...)|$(...)"` double-quoted string interpolation — use string concatenation (`$a + "|" + $b`) instead
- Avoid parentheses inside double-quoted strings passed to function parameters — use single-quoted strings instead

### MTP Access
- MTP devices are accessed via the `Shell.Application` COM interface, not regular file paths
- File sizes from MTP use `ExtendedProperty("System.Size")` with fallback to `GetDetailsOf` parsing
- `CopyHere` is used for file transfers with flags `0x414` (no UI dialogs)

## File Structure

- `CopyNewFilesFromMTP.ps1` — main script
- `CopyNewFilesFromMTP.bat` — wrapper for users unfamiliar with PowerShell execution policies
- `.github/workflows/release.yml` — GitHub Actions: builds EXE via ps2exe on tag push
- `README.md` — user documentation
- `CLAUDE.md` — this file (development guidelines)

## Release Process

1. Update `$script:AppVersion` in the script (increment at least patch digit)
2. Commit and push
3. Create and push a git tag matching the version: `git tag v1.1.0 && git push origin v1.1.0`
4. GitHub Actions builds the EXE and creates a GitHub Release with downloadable assets
