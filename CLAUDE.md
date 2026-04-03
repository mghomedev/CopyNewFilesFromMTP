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

### Scan-Only Mode
- `-ScanOnly` flag: only connect to MTP device, scan the source folder, list all files with sizes, and exit
- Does not require `-IgnoreFilesInFoldersBySizeAndName` or `-TargetFolder`
- Useful for testing MTP connection and path before running a full copy

## Versioning

- Version is stored in `$script:AppVersion` in the script (e.g., `"1.1.0"`)
- Build date is stored in `$script:AppBuildDate` (e.g., `"2026-04-03"`)
- **On every code change, increment at least the patch (last) digit of the version**
- The GitHub Actions release workflow stamps the tag version and current date into the script before building the EXE

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
