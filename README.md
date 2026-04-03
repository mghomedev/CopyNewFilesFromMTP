# CopyNewFilesFromMTP

A PowerShell script that copies files from an MTP-connected Android phone to a Windows PC, **skipping files that already exist** in specified backup folders. Designed for large-scale backups (500 GB+, hundreds of thousands of files) with resume support.

## Background

This script was developed by [mghomedev](https://github.com/mghomedev) with [Claude Code](https://claude.ai/claude-code) (Anthropic's AI coding assistant) to solve a specific problem: backing up an Android phone over MTP while avoiding duplication across multiple existing backup locations.

### Requirements that drove the design

- **Deduplication**: Files that already exist in previous backup folders (matched by filename and size) must not be copied again
- **Huge datasets**: Must handle 500 GB+ with hundreds of thousands of files efficiently
- **Low system impact**: Must run smoothly in the background without overloading the PC (long-running operation)
- **Resume support**: The user may unplug their phone and come back later — the script must remember where it stopped and continue without losing files
- **Progress reporting**: Pre-scan the source, estimate duration, and show remaining file count with each operation
- **MTP access**: Android phones connected via USB use MTP (Media Transfer Protocol), which does not expose normal file paths — the script uses Windows Shell COM to access the device

## Features

- **Smart deduplication** via a file index (filename + size) with O(1) HashSet lookups
- **Two-layer skip logic**: checks both the in-memory index and the actual target folder before copying
- **Resume after interruption** — state file tracks processed files; just re-run with the same parameters
- **MTP device scan caching** — avoids re-scanning the phone on resume
- **Progress with ETA** — shows `[current/total | remaining | ETA]` for every file
- **Low priority execution** — process runs at `BelowNormal` priority with configurable throttle delay
- **Scan-only mode** (`-ScanOnly`) — test MTP connection and list files without copying anything
- **Path discovery** — if a path is not found on the device, lists available items at the last valid level
- **Safety prompts** — warns if ignore folders are missing/empty or the index is empty

## Requirements

- **Windows 10/11** with PowerShell 5.1 (pre-installed)
- Android phone connected via USB with **MTP/File Transfer** mode enabled
- The phone must appear as a device under "This PC" in Windows Explorer

## Usage

### First: Test your MTP connection

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\CopyNewFilesFromMTP.ps1 `
    -DeviceName "Galaxy S24" `
    -SourcePath "Internal storage\DCIM" `
    -ScanOnly
```

This lists all files on the device with sizes and exits. Use it to verify:
- The device name is correct (as shown in Windows Explorer)
- The source path exists (if not, the script shows available folders at the last valid level)

### Copy with a single ignore folder

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\CopyNewFilesFromMTP.ps1 `
    -DeviceName "Galaxy S24" `
    -SourcePath "Internal storage\DCIM" `
    -IgnoreFilesInFoldersBySizeAndName "D:\Backup\Phone2024" `
    -TargetFolder "D:\Backup\Phone2025"
```

### Copy with multiple ignore folders

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\CopyNewFilesFromMTP.ps1 `
    -DeviceName "Galaxy S24" `
    -SourcePath "Internal storage\DCIM" `
    -IgnoreFilesInFoldersBySizeAndName @("D:\Backup\Phone2023", "D:\Backup\Phone2024") `
    -TargetFolder "D:\Backup\Phone2025"
```

### Resume after interruption

Just run the exact same command again. The script detects the state file and scan cache in the target folder and picks up where it left off.

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-DeviceName` | Yes | MTP device name as shown in Windows Explorer |
| `-SourcePath` | Yes | Path on the device (e.g., `"Internal storage\DCIM"`) |
| `-IgnoreFilesInFoldersBySizeAndName` | For copy | One or more local folder paths to index for deduplication |
| `-TargetFolder` | For copy | Destination folder for new files |
| `-ScanOnly` | No | Only scan and list device files, then exit |
| `-RebuildIndex` | No | Force rebuilding the ignore index |
| `-Rescan` | No | Force rescanning the MTP device |
| `-IndexFile` | No | Custom path for the index file |
| `-StateFile` | No | Custom path for the resume state file |
| `-ScanCacheFile` | No | Custom path for the MTP scan cache |
| `-ThrottleDelayMs` | No | Delay between operations in ms (default: 5) |

## How it works

### Step 1: Build the ignore index

Scans all folders specified in `-IgnoreFilesInFoldersBySizeAndName` and creates a TSV file listing every filename and its size. This index is loaded into a HashSet for O(1) lookups. The index is reused on subsequent runs unless `-RebuildIndex` is specified.

If any specified folder does not exist, is empty, or the resulting index contains zero files, the script warns the user and asks for confirmation before continuing.

### Step 2: Scan the MTP device

Connects to the Android phone via the Windows Shell COM interface and recursively enumerates all files in the specified source path. The scan results are cached to a file so that on resume, the phone does not need to be re-scanned (use `-Rescan` to force).

### Step 3: Copy new files

For each file on the device:
1. **Check resume state** — skip if already processed in a previous run
2. **Check ignore index** — if `filename + size` matches an entry, skip it and log where the duplicate lives
3. **Check target folder** — if the file already exists at the target path with the same size, skip it
4. **Copy** — creates the directory structure and copies via Shell COM, then verifies the result

Each processed file is immediately written to the state file for crash safety.

## Output files

The script creates these metadata files in the target folder (prefixed with `_`):

| File | Purpose |
|---|---|
| `_file_index.tsv` | Index of all files in ignore folders (filename, size, path) |
| `_mtp_scan_cache.tsv` | Cached list of all files on the MTP device |
| `_resume_state.txt` | List of already-processed file paths for resume |

## Notes

- **Execution Policy**: Windows may block PowerShell scripts by default. Use `powershell.exe -ExecutionPolicy Bypass -File ...` to run without changing system settings.
- **Device name**: The device name must match what Windows Explorer shows under "This PC". If the name is wrong, the script lists all available devices.
- **Path on device**: The path uses backslashes (e.g., `"Internal storage\DCIM"`). If a segment is not found, the script lists available items at that level so you can discover the correct path.
- **MTP performance**: MTP is inherently slower than direct file system access. Scanning 28,000+ files takes about 40 seconds; copying depends on file sizes and USB speed.

## License

MIT

---

*Developed with [Claude Code](https://claude.ai/claude-code) by Anthropic*
