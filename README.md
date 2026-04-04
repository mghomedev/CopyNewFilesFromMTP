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
- **Disconnect-safe** — automatically retries with exponential backoff when the phone is disconnected mid-operation; by default waits indefinitely for the phone to be reconnected

## Installation

### Option 1: Download the EXE (easiest)

Download **`CopyNewFilesFromMTP.exe`** from the [latest release](../../releases/latest). No installation or configuration required — just run it from the command line.

### Option 2: Download the script

Download the repository and use either:
- **`CopyNewFilesFromMTP.bat`** — double-click friendly wrapper, no PowerShell configuration needed
- **`CopyNewFilesFromMTP.ps1`** — run directly with `powershell.exe -ExecutionPolicy Bypass -File .\CopyNewFilesFromMTP.ps1 ...`

## Requirements

- **Windows 10/11** with PowerShell 5.1 (pre-installed)
- Android phone connected via USB with **MTP/File Transfer** mode enabled
- The phone must appear as a device under "This PC" in Windows Explorer

## Usage

> **Tip:** If you are not familiar with PowerShell execution policies, use the included **`CopyNewFilesFromMTP.bat`** wrapper instead of calling the `.ps1` script directly. It handles everything for you. Just replace `powershell.exe -ExecutionPolicy Bypass -File .\CopyNewFilesFromMTP.ps1` with `CopyNewFilesFromMTP.bat` in the examples below.

### First: Test your MTP connection

```cmd
CopyNewFilesFromMTP.bat -DeviceName "Galaxy S24" -SourcePath "Internal storage\DCIM" -ScanOnly
```

Or with PowerShell directly:

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
| `-RetryCount` | No | Max retries when device disconnects (default: 30) |
| `-RetryWaitSeconds` | No | Initial seconds between retries, doubles each time (default: 10) |
| `-OnFinalFailure` | No | After all retries: `Ask`, `Skip`, or `WaitForever` (default: `WaitForever`) |
| `-ResumeMode` | No | On existing state: `Ask`, `Continue`, or `Fresh` (default: `Ask`) |

### Timing Configuration

Internal timing values can be adjusted by editing the `$script:` variables at the top of the `.ps1` script:

| Variable | Default | Description |
|---|---|---|
| `CopyPollMs` | 50 | How often to check if a file has appeared/finished copying (ms) |
| `CopyProgressMs` | 500 | How often to update the spinner/percentage on screen (ms) |
| `CopyTimeoutMinutes` | 30 | Max time to wait for a single file copy before giving up |
| `StabilityCheckMs` | 200 | For unknown-size files: pause before re-checking if size stopped growing |
| `RetryBackoffMaxSeconds` | 600 | Cap for exponential backoff between retries (10 minutes) |
| `ScanYieldInterval` | 500 | Yield CPU every N files during MTP scan |
| `ScanYieldMs` | 1 | Duration of each yield pause during scan (ms) |

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

## Cache files

The script creates these cache/state files in the target folder. All filenames start with `_cache_CopyNewFilesFromMTP_` to clearly identify them as generated by this tool. They can be safely deleted to force a fresh start (or use `-ResumeMode Fresh`).

| File | Description |
|---|---|
| `_cache_CopyNewFilesFromMTP_local_backup_file_index.tsv` | **Local backup file index.** Tab-separated list of every file found in the `-IgnoreFilesInFoldersBySizeAndName` folders (filename, size in bytes, full path). Loaded into memory as a HashSet for O(1) deduplication lookups. Rebuilt with `-RebuildIndex`. |
| `_cache_CopyNewFilesFromMTP_mtp_device_file_list.tsv` | **MTP device file list.** Tab-separated list of every file found on the phone during the MTP scan (relative path, size in bytes). Cached so the phone doesn't need to be re-scanned on resume. Rebuilt with `-Rescan`. |
| `_cache_CopyNewFilesFromMTP_resume_progress.txt` | **Resume progress tracker.** One line per processed file (relative path). On restart, files listed here are skipped. This is what enables unplug-and-resume. |

## Notes

- **Execution Policy**: Windows may block PowerShell scripts by default. Use `powershell.exe -ExecutionPolicy Bypass -File ...` to run without changing system settings.
- **Device name**: The device name must match what Windows Explorer shows under "This PC". If the name is wrong, the script lists all available devices.
- **Path on device**: The path uses backslashes (e.g., `"Internal storage\DCIM"`). If a segment is not found, the script lists available items at that level so you can discover the correct path.
- **MTP performance**: MTP (Media Transfer Protocol) is significantly slower than direct file system access, especially for many small files. Each file transfer involves a per-file protocol overhead of roughly 1-2 seconds for session negotiation, object handle allocation, and metadata exchange — regardless of the file's actual size. This means a 2 MB photo and an 8 MB photo may take a similar amount of time to transfer, because the overhead dominates the actual data transfer. This is a fundamental limitation of the MTP protocol and cannot be fixed in software. For background on MTP's design and performance characteristics, see the [USB.org MTP specification](https://www.usb.org/document-library/media-transfer-protocol-v11-spec-and-mtp-v11-adopters-agreement) and [Android's MTP documentation](https://source.android.com/docs/core/connect/mtp). Scanning 28,000+ files takes about 40 seconds; copying throughput depends on file sizes and USB speed, but expect 3-15 MB/s effective throughput per file due to the per-file overhead.

## Performance and benchmarking

Performance and speed are critical. The script must not introduce noticeable additional overhead over the known MTP file copy speed limitations through USB.

To ensure this:

- **Timestamps in every log line**: All output lines include an absolute timestamp (`HH:mm:ss`) so that wall-clock time between operations is visible in the log. This makes it easy to spot delays.
- **`-Benchmark` mode**: Pass `-Benchmark` to enable detailed per-statement timing output for every I/O operation in the copy loop (MTP navigation, ParseName, CopyHere, file verification, etc.). This allows developers and AI tools like Claude to identify bottlenecks or performance regressions by reading the log output.
- **`-MaxCopyCount N`**: Limits the number of files actually copied (useful for quick benchmarking without running the full operation).

Example benchmark run:
```powershell
.\CopyNewFilesFromMTP.ps1 -DeviceName "Galaxy S24" -SourcePath "Internal storage\DCIM" `
    -IgnoreFilesInFoldersBySizeAndName "D:\Backup" -TargetFolder "D:\Backup\New" `
    -Benchmark -MaxCopyCount 10
```

## License

MIT

---

*Developed with [Claude Code](https://claude.ai/claude-code) by Anthropic*
