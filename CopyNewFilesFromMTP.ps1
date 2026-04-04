<#
.SYNOPSIS
    Copies new files from an MTP-connected Android device to a backup folder,
    skipping files that already exist in specified backup locations.

.DESCRIPTION
    1. Builds an index of all files in existing backup folders (filename + size)
    2. Scans the specified folder on the MTP device recursively
    3. Copies only files not found in the index to the target backup folder
    4. Supports resume after interruption (unplug phone, come back later)
    5. Shows progress with file counts and ETA

.PARAMETER DeviceName
    Name of the MTP device as it appears in Windows Explorer (e.g., "Galaxy S24").

.PARAMETER SourcePath
    Path on the device to copy from (e.g., "Internal storage\DCIM").
    Use backslashes to separate path components.

.PARAMETER IgnoreFilesInFoldersBySizeAndName
    One or more existing local backup folder paths to index for deduplication.
    Files found in these folders (matched by filename and size) will be skipped
    during copy. Accepts a single path or an array of paths.

.PARAMETER TargetFolder
    Destination folder where new files will be copied to.

.PARAMETER IndexFile
    Path to the local backup file index (tab-separated: filename, size, full path).
    Contains all files found in the -IgnoreFilesInFoldersBySizeAndName folders, used
    for fast O(1) deduplication lookups during copy.
    Default: <TargetFolder>\_cache_CopyNewFilesFromMTP_local_backup_file_index.tsv

.PARAMETER StateFile
    Path to the resume progress file (one processed file path per line).
    Tracks which MTP files have already been copied or skipped, so the script
    can resume after interruption without reprocessing completed files.
    Default: <TargetFolder>\_cache_CopyNewFilesFromMTP_resume_progress.txt

.PARAMETER ScanCacheFile
    Path to the MTP device file list cache (tab-separated: relative path, size).
    Contains all files found during the MTP device scan, so the phone does not
    need to be re-scanned on resume.
    Default: <TargetFolder>\_cache_CopyNewFilesFromMTP_mtp_device_file_list.tsv

.PARAMETER ScanOnly
    Only scan the MTP device source folder and display all found files with sizes.
    Useful for testing if the MTP connection and path work correctly.
    When used, -IgnoreFilesInFoldersBySizeAndName and -TargetFolder are not required.

.PARAMETER RebuildIndex
    Force rebuilding the local backup index even if it already exists.

.PARAMETER Rescan
    Force rescanning the MTP device even if a scan cache exists.

.PARAMETER ThrottleDelayMs
    Milliseconds to pause between file operations to keep PC responsive. Default: 5.

.PARAMETER RetryCount
    Maximum number of retries when the MTP device becomes unavailable (e.g., phone
    disconnected). Wait time doubles with each retry. Default: 30.

.PARAMETER RetryWaitSeconds
    Initial wait time in seconds between retries. Doubles after each failed attempt
    (e.g., 10, 20, 40, 80...). Default: 10.

.PARAMETER OnFinalFailure
    What to do after all retries are exhausted. Default: WaitForever.
    - Ask:         Prompt the user to skip the file or keep waiting
    - Skip:        Automatically skip the file and continue with the next one
    - WaitForever: Keep retrying indefinitely until the device comes back

.PARAMETER ResumeMode
    What to do when state files from a previous run exist. Default: Ask.
    - Ask:      Prompt the user to continue or start fresh
    - Continue: Automatically resume from the last state
    - Fresh:    Clear all state files and start from scratch

.EXAMPLE
    # Test MTP connection by scanning and listing files:
    .\CopyNewFilesFromMTP.ps1 `
        -DeviceName "Galaxy S24" `
        -SourcePath "Internal storage\DCIM" `
        -ScanOnly

.EXAMPLE
    # Single ignore folder:
    .\CopyNewFilesFromMTP.ps1 `
        -DeviceName "Galaxy S24" `
        -SourcePath "Internal storage\DCIM" `
        -IgnoreFilesInFoldersBySizeAndName "D:\Backup\Phone2024" `
        -TargetFolder "D:\Backup\Phone2025"

.EXAMPLE
    # Multiple ignore folders:
    .\CopyNewFilesFromMTP.ps1 `
        -DeviceName "Galaxy S24" `
        -SourcePath "Internal storage\DCIM" `
        -IgnoreFilesInFoldersBySizeAndName @("D:\Backup\Phone2023", "D:\Backup\Phone2024") `
        -TargetFolder "D:\Backup\Phone2025"
#>

[CmdletBinding()]
param(
    [string]$DeviceName = "",
    [string]$SourcePath = "",

    [string[]]$IgnoreFilesInFoldersBySizeAndName = @(),
    [string]$TargetFolder = "",

    [switch]$ScanOnly,
    [string]$IndexFile = "",
    [string]$StateFile = "",
    [string]$ScanCacheFile = "",
    [switch]$RebuildIndex,
    [switch]$Rescan,
    [int]$ThrottleDelayMs = 5,
    [int]$RetryCount = 30,
    [int]$RetryWaitSeconds = 10,

    [ValidateSet("Ask", "Skip", "WaitForever")]
    [string]$OnFinalFailure = "WaitForever",

    [ValidateSet("Ask", "Continue", "Fresh")]
    [string]$ResumeMode = "Ask",

    [switch]$CloudSyncSafe,
    [int]$MaxCopyCount = 0,
    [switch]$Benchmark
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── Version info ──────────────────────────────────────────────────────────────

$script:AppVersion   = "1.5.0"
$script:AppBuildDate = "2026-04-04"

# ─── Timing configuration (all in one place) ──────────────────────────────────
#
# Copy wait loop:
#   CopyPollMs          - How often to check if a file has appeared/finished copying (ms)
#   CopyProgressMs      - How often to update the spinner/percentage on screen (ms)
#   CopyTimeoutMinutes  - Max time to wait for a single file copy before giving up
#   StabilityCheckMs    - For files with unknown size: pause before re-checking if size stopped growing
#
# Retry / reconnect:
#   RetryBackoffMaxSeconds - Cap for exponential backoff between retries (seconds)
#
# MTP scan:
#   ScanYieldInterval   - Yield CPU every N files during MTP scan (prevents UI freeze)
#   ScanYieldMs         - Duration of each yield pause (ms)
#
$script:CopyPollMs             = 50
$script:CopyProgressMs         = 500
$script:CopyTimeoutMinutes     = 30
$script:StabilityCheckMs       = 200
$script:RetryBackoffMaxSeconds = 600
$script:ScanYieldInterval      = 500
$script:ScanYieldMs            = 1

# ─── Show help if no arguments ─────────────────────────────────────────────────

if (-not $DeviceName -and -not $SourcePath -and -not $ScanOnly) {
    Write-Host ""
    Write-Host "  CopyNewFilesFromMTP  v$($script:AppVersion)  (built $($script:AppBuildDate))" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Copies files from an MTP-connected Android phone to a Windows PC," -ForegroundColor White
    Write-Host "  skipping files that already exist in specified backup locations." -ForegroundColor White
    Write-Host ""
    Write-Host "  Features:" -ForegroundColor Yellow
    Write-Host "    - Deduplication by filename + file size against existing backup folders"
    Write-Host "    - Resume support: unplug your phone, come back later, re-run"
    Write-Host "    - Progress reporting with ETA"
    Write-Host "    - Low system impact (runs at BelowNormal priority)"
    Write-Host "    - MTP scan caching for fast resume"
    Write-Host ""
    Write-Host "  Usage:" -ForegroundColor Yellow
    Write-Host "    Test MTP connection (scan only):" -ForegroundColor Gray
    Write-Host '    .\CopyNewFilesFromMTP.ps1 -DeviceName "Galaxy S24" -SourcePath "Internal storage\DCIM" -ScanOnly'
    Write-Host ""
    Write-Host "    Copy new files:" -ForegroundColor Gray
    Write-Host '    .\CopyNewFilesFromMTP.ps1 -DeviceName "Galaxy S24" -SourcePath "Internal storage\DCIM" \'
    Write-Host '      -IgnoreFilesInFoldersBySizeAndName "D:\Backup\Phone2024" -TargetFolder "D:\Backup\Phone2025"'
    Write-Host ""
    Write-Host "    Copy with multiple ignore folders:" -ForegroundColor Gray
    Write-Host '    .\CopyNewFilesFromMTP.ps1 -DeviceName "Galaxy S24" -SourcePath "Internal storage\DCIM" \'
    Write-Host '      -IgnoreFilesInFoldersBySizeAndName @("D:\Backup\2023","D:\Backup\2024") -TargetFolder "D:\Backup\2025"'
    Write-Host ""
    Write-Host "  Parameters:" -ForegroundColor Yellow
    Write-Host "    -DeviceName          MTP device name as shown in Windows Explorer"
    Write-Host "    -SourcePath          Path on device (e.g. 'Internal storage\DCIM')"
    Write-Host "    -IgnoreFilesInFoldersBySizeAndName  Folder(s) to check for existing files"
    Write-Host "    -TargetFolder        Where to copy new files to"
    Write-Host "    -ScanOnly            Only list device files, don't copy"
    Write-Host "    -RebuildIndex        Force rebuild of the ignore index"
    Write-Host "    -Rescan              Force rescan of the MTP device"
    Write-Host "    -ThrottleDelayMs     Delay between operations in ms (default: 5)"
    Write-Host "    -RetryCount          Max retries when device disconnects (default: 30)"
    Write-Host "    -RetryWaitSeconds    Seconds between retries, doubles each time (default: 10)"
    Write-Host "    -OnFinalFailure      After all retries: Ask, Skip, or WaitForever (default: WaitForever)"
    Write-Host "    -ResumeMode          On existing state: Ask, Continue, or Fresh (default: Ask)"
    Write-Host "    -CloudSyncSafe       Rename files during copy to prevent Dropbox/OneDrive upload"
    Write-Host "    -MaxCopyCount        Stop after copying this many files (0 = unlimited, default: 0)"
    Write-Host "    -Benchmark           Output detailed per-statement timing for performance analysis"
    Write-Host ""
    Write-Host "  Cache files (created in -TargetFolder):" -ForegroundColor Yellow
    Write-Host "    _cache_CopyNewFilesFromMTP_local_backup_file_index.tsv"
    Write-Host "      Index of all files in -IgnoreFilesInFoldersBySizeAndName folders (for dedup)"
    Write-Host "    _cache_CopyNewFilesFromMTP_mtp_device_file_list.tsv"
    Write-Host "      Cached list of all files on the MTP device (avoids re-scanning on resume)"
    Write-Host "    _cache_CopyNewFilesFromMTP_resume_progress.txt"
    Write-Host "      Tracks which files have been processed (for resume after interruption)"
    Write-Host ""
    Write-Host "  https://github.com/mghomedev/CopyNewFilesFromMTP" -ForegroundColor DarkGray
    Write-Host ""
    exit 0
}

# ─── Validate parameters ───────────────────────────────────────────────────────

if (-not $DeviceName) {
    throw "-DeviceName is required. Run without arguments to see usage."
}
if (-not $SourcePath) {
    throw "-SourcePath is required. Run without arguments to see usage."
}

if (-not $ScanOnly) {
    if (-not $TargetFolder) {
        throw "-TargetFolder is required unless -ScanOnly is specified."
    }
    if ($IgnoreFilesInFoldersBySizeAndName.Count -eq 0) {
        throw "-IgnoreFilesInFoldersBySizeAndName is required unless -ScanOnly is specified. Pass one or more folder paths."
    }
}

# ─── Defaults ───────────────────────────────────────────────────────────────────

if (-not $ScanOnly) {
    if (-not $IndexFile)     { $IndexFile     = Join-Path $TargetFolder "_cache_CopyNewFilesFromMTP_local_backup_file_index.tsv" }
    if (-not $StateFile)     { $StateFile     = Join-Path $TargetFolder "_cache_CopyNewFilesFromMTP_resume_progress.txt" }
    if (-not $ScanCacheFile) { $ScanCacheFile = Join-Path $TargetFolder "_cache_CopyNewFilesFromMTP_mtp_device_file_list.tsv" }
}

# ─── Lower process priority so the PC stays responsive ─────────────────────────

[System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
Write-Host "[INFO] Process priority set to BelowNormal for background-friendly operation." -ForegroundColor Cyan

# ─── Ensure target folder exists ────────────────────────────────────────────────

if (-not $ScanOnly) {
    if (-not (Test-Path $TargetFolder)) {
        New-Item -ItemType Directory -Path $TargetFolder -Force | Out-Null
        Write-Host "[INFO] Created target folder: $TargetFolder" -ForegroundColor Cyan
    }
}

# ─── Check for existing state and ask to resume or start fresh ─────────────────

if (-not $ScanOnly) {
    $hasIndex = $IndexFile -and (Test-Path $IndexFile)
    $hasState = $StateFile -and (Test-Path $StateFile)
    $hasScanCache = $ScanCacheFile -and (Test-Path $ScanCacheFile)
    $hasAnyState = $hasIndex -or $hasState -or $hasScanCache

    if ($hasAnyState) {
        $stateDetails = @()
        if ($hasIndex)     { $stateDetails += "file index" }
        if ($hasScanCache) { $stateDetails += "MTP scan cache" }
        if ($hasState)     { $stateDetails += "resume state" }
        $stateList = $stateDetails -join ", "

        $startFresh = $false

        # Gather stats from existing state files for display
        $resumeStats = @{}
        if ($hasIndex) {
            $fi = [System.IO.FileInfo]::new($IndexFile)
            $resumeStats.IndexDate = $fi.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
            $resumeStats.IndexLines = ([System.IO.File]::ReadAllLines($IndexFile)).Count - 1  # minus header
        }
        if ($hasScanCache) {
            $fi = [System.IO.FileInfo]::new($ScanCacheFile)
            $resumeStats.ScanDate = $fi.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
            $resumeStats.ScanTotal = ([System.IO.File]::ReadAllLines($ScanCacheFile)).Count - 1  # minus header
        }
        if ($hasState) {
            $fi = [System.IO.FileInfo]::new($StateFile)
            $resumeStats.StateDate = $fi.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
            $resumeStats.StateProcessed = ([System.IO.File]::ReadAllLines($StateFile)).Count
        }
        if ($resumeStats.ContainsKey('ScanTotal') -and $resumeStats.ContainsKey('StateProcessed')) {
            $resumeStats.Remaining = $resumeStats.ScanTotal - $resumeStats.StateProcessed
        }

        switch ($ResumeMode) {
            "Continue" {
                Write-Host ""
                Write-Host "[RESUME] Found previous state. Continuing from last run." -ForegroundColor Cyan
                if ($resumeStats.ContainsKey('ScanTotal')) {
                    Write-Host "  Total files on device: $($resumeStats.ScanTotal)   (scanned $($resumeStats.ScanDate))" -ForegroundColor Gray
                }
                if ($resumeStats.ContainsKey('StateProcessed')) {
                    Write-Host "  Already processed:     $($resumeStats.StateProcessed)   (last activity $($resumeStats.StateDate))" -ForegroundColor Gray
                }
                if ($resumeStats.ContainsKey('Remaining')) {
                    Write-Host "  Remaining:             $($resumeStats.Remaining)" -ForegroundColor Gray
                }
            }
            "Fresh" {
                $startFresh = $true
            }
            default {
                # Ask the user
                Write-Host ""
                Write-Host "[RESUME] Found previous state from an earlier run:" -ForegroundColor Yellow
                Write-Host ""
                if ($hasIndex) {
                    Write-Host "  File index:     $($resumeStats.IndexLines) entries   (created $($resumeStats.IndexDate))" -ForegroundColor Gray
                    Write-Host "                  $IndexFile" -ForegroundColor DarkGray
                }
                if ($hasScanCache) {
                    Write-Host "  MTP scan cache: $($resumeStats.ScanTotal) files on device   (scanned $($resumeStats.ScanDate))" -ForegroundColor Gray
                    Write-Host "                  $ScanCacheFile" -ForegroundColor DarkGray
                }
                if ($hasState) {
                    Write-Host "  Resume state:   $($resumeStats.StateProcessed) files processed   (last activity $($resumeStats.StateDate))" -ForegroundColor Gray
                    Write-Host "                  $StateFile" -ForegroundColor DarkGray
                }
                if ($resumeStats.ContainsKey('Remaining')) {
                    Write-Host ""
                    Write-Host "  ==> $($resumeStats.Remaining) files remaining to process" -ForegroundColor Cyan
                }
                Write-Host ""
                $response = Read-Host "  (C)ontinue from where you left off, or start (F)resh? [C/f]"
                if ($response -in @('f', 'F', 'fresh', 'Fresh', 'FRESH')) {
                    $startFresh = $true
                }
                else {
                    Write-Host "[RESUME] Continuing from last run." -ForegroundColor Cyan
                }
            }
        }

        if ($startFresh) {
            Write-Host "[FRESH] Clearing all state files..." -ForegroundColor Yellow
            if ($hasIndex)     { Remove-Item -LiteralPath $IndexFile -Force; Write-Host "  Deleted: $IndexFile" -ForegroundColor DarkGray }
            if ($hasScanCache) { Remove-Item -LiteralPath $ScanCacheFile -Force; Write-Host "  Deleted: $ScanCacheFile" -ForegroundColor DarkGray }
            if ($hasState)     { Remove-Item -LiteralPath $StateFile -Force; Write-Host "  Deleted: $StateFile" -ForegroundColor DarkGray }

            # Also clean up any leftover ~*.tmp files in the target
            Get-ChildItem -LiteralPath $TargetFolder -Recurse -File -Filter "~*.tmp" -Force -ErrorAction SilentlyContinue | ForEach-Object {
                $_.Attributes = $_.Attributes -band (-bnot ([System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::Temporary))
                Remove-Item -LiteralPath $_.FullName -Force
                Write-Host "  Deleted temp file: $($_.FullName)" -ForegroundColor DarkGray
            }

            Write-Host "[FRESH] Starting from scratch." -ForegroundColor Green
            # Force rebuild/rescan
            $RebuildIndex = $true
            $Rescan = $true
        }
        Write-Host ""
    }
}

# ─── PowerShell STA check ──────────────────────────────────────────────────────

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Warning "Shell COM works best in STA mode. If you encounter issues, run: powershell.exe -STA -File `"$($MyInvocation.MyCommand.Path)`""
}

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1: Build or load the local backup file index
# ═══════════════════════════════════════════════════════════════════════════════

function Confirm-Continue {
    param([string]$Message)

    Write-Host ""
    Write-Host "[WARNING] $Message" -ForegroundColor Red
    Write-Host ""
    $response = Read-Host "Do you want to continue anyway? (y/N)"
    if ($response -notin @('y', 'Y', 'yes', 'Yes', 'YES')) {
        Write-Host "Aborted by user." -ForegroundColor Yellow
        exit 1
    }
    Write-Host ""
}

function Build-FileIndex {
    param(
        [string[]]$Folders,
        [string]$OutputFile
    )

    Write-Host ""
    Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host " STEP 1: Building file index from local backup folders"       -ForegroundColor Yellow
    Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Yellow

    # Pre-check: warn about missing or empty folders before indexing
    $problems = @()
    foreach ($folder in $Folders) {
        if (-not (Test-Path $folder)) {
            $problems += "Folder does not exist: $folder"
        }
        else {
            $firstFile = Get-ChildItem -LiteralPath $folder -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -eq $firstFile) {
                $problems += "Folder exists but contains no files: $folder"
            }
        }
    }

    if ($problems.Count -gt 0) {
        Write-Host ""
        foreach ($p in $problems) {
            Write-Host "  ! $p" -ForegroundColor Red
        }
        Confirm-Continue -Message "One or more ignore folders are missing or empty. This means no files will be skipped during copy — everything from the device will be copied. Did you make a mistake?"
    }

    $writer = [System.IO.StreamWriter]::new($OutputFile, $false, [System.Text.Encoding]::UTF8)
    $writer.WriteLine("FileName`tSize`tFullPath")
    $totalFiles = 0

    foreach ($folder in $Folders) {
        if (-not (Test-Path $folder)) {
            Write-Warning "Backup folder not found, skipping: $folder"
            continue
        }

        Write-Host "[INDEX] Scanning: $folder" -ForegroundColor Gray
        $folderCount = 0

        try {
            Get-ChildItem -LiteralPath $folder -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                $writer.WriteLine("$($_.Name)`t$($_.Length)`t$($_.FullName)")
                $folderCount++
                $totalFiles++

                if ($folderCount % 10000 -eq 0) {
                    Write-Host "  ... $folderCount files indexed so far in this folder" -ForegroundColor DarkGray
                }
            }
        }
        catch {
            Write-Warning "Error scanning $folder : $_"
        }

        Write-Host "[INDEX] Indexed $folderCount files from: $folder" -ForegroundColor Green
    }

    $writer.Close()
    Write-Host "[INDEX] Total files indexed: $totalFiles" -ForegroundColor Green
    Write-Host "[INDEX] Index saved to: $OutputFile" -ForegroundColor Green

    return $totalFiles
}

function Load-FileIndex {
    param([string]$IndexPath)

    Write-Host "[INDEX] Loading file index into memory..." -ForegroundColor Cyan

    # HashSet for O(1) lookup: key = "lowercasename|size"
    $index = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    # Dictionary for logging: key -> original full path
    $indexPaths = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $lineNum = 0
    foreach ($line in [System.IO.File]::ReadLines($IndexPath, [System.Text.Encoding]::UTF8)) {
        $lineNum++
        if ($lineNum -eq 1) { continue } # skip header

        $parts = $line.Split("`t", 3)
        if ($parts.Length -ge 2) {
            $key = $parts[0] + "|" + $parts[1]
            if ($index.Add($key)) {
                if ($parts.Length -ge 3) {
                    $indexPaths[$key] = $parts[2]
                }
            }
        }
    }

    Write-Host "[INDEX] Loaded $($index.Count) unique file entries into memory." -ForegroundColor Green
    return @{ Index = $index; Paths = $indexPaths }
}

if (-not $ScanOnly) {
    # Check if index needs to be built
    if ($RebuildIndex -or -not (Test-Path $IndexFile)) {
        $builtCount = Build-FileIndex -Folders $IgnoreFilesInFoldersBySizeAndName -OutputFile $IndexFile
        if ($builtCount -eq 0) {
            Confirm-Continue -Message 'The generated ignore index is empty (0 files). This means no files will be skipped during copy - everything from the device will be copied. Did you make a mistake?'
        }
    }
    else {
        Write-Host ""
        Write-Host "[INDEX] File index already exists: $IndexFile" -ForegroundColor Cyan
        Write-Host "[INDEX] Use -RebuildIndex to force rebuild." -ForegroundColor Cyan
    }

    $indexData = Load-FileIndex -IndexPath $IndexFile
    $fileIndex = $indexData.Index
    $fileIndexPaths = $indexData.Paths

    if ($fileIndex.Count -eq 0) {
        Confirm-Continue -Message 'The loaded ignore index is empty (0 files). This means no files will be skipped during copy - everything from the device will be copied. Did you make a mistake?'
    }

    # Also index files already in the target folder (from previous runs)
    if (Test-Path $TargetFolder) {
        Write-Host "[INDEX] Indexing target folder for already-copied files..." -ForegroundColor Cyan
        $targetCount = 0
        try {
            Get-ChildItem -LiteralPath $TargetFolder -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                # Skip our metadata files
                if ($_.Name.StartsWith("_cache_CopyNewFilesFromMTP_")) {
                    return
                }
                $key = $_.Name + "|" + $_.Length
                if ($fileIndex.Add($key)) {
                    $fileIndexPaths[$key] = $_.FullName
                    $targetCount++
                }
            }
        }
        catch {
            Write-Warning "Error scanning target folder: $_"
        }
        if ($targetCount -gt 0) {
            Write-Host "[INDEX] Found $targetCount additional files already in target folder." -ForegroundColor Green
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 2: Connect to MTP device and scan source folder
# ═══════════════════════════════════════════════════════════════════════════════

function Get-MTPDevice {
    param([string]$Name)

    $shell = New-Object -ComObject Shell.Application
    $myComputer = $shell.NameSpace(17) # This PC

    foreach ($item in $myComputer.Items()) {
        if ($item.Name -eq $Name) {
            return $item
        }
    }

    # If exact match not found, try partial match
    foreach ($item in $myComputer.Items()) {
        if ($item.Name -like "*$Name*") {
            Write-Host "[MTP] Partial match found: '$($item.Name)'" -ForegroundColor Yellow
            return $item
        }
    }

    # List available devices
    Write-Host "[MTP] Available devices under 'This PC':" -ForegroundColor Red
    foreach ($item in $myComputer.Items()) {
        $type = $myComputer.GetDetailsOf($item, 2)
        Write-Host "  - $($item.Name) ($type)" -ForegroundColor Gray
    }

    throw "MTP device '$Name' not found. Check the name in Windows Explorer."
}

function List-MTPFolderContents {
    param([System.__ComObject]$Folder, [string]$LocationLabel)

    Write-Host "[MTP] Available items at '$LocationLabel':" -ForegroundColor Yellow
    $hasItems = $false
    foreach ($item in $Folder.Items()) {
        $hasItems = $true
        $type = if ($item.IsFolder) { "[Folder]" } else { "[File]" }
        Write-Host "  $type $($item.Name)" -ForegroundColor Gray
    }
    if (-not $hasItems) {
        Write-Host "  (empty)" -ForegroundColor DarkGray
    }
}

function Navigate-MTPPath {
    param(
        [System.__ComObject]$DeviceItem,
        [string]$Path
    )

    $currentFolder = $DeviceItem.GetFolder
    $segments = $Path.Split('\', [System.StringSplitOptions]::RemoveEmptyEntries)
    $resolvedSoFar = @()

    foreach ($segment in $segments) {
        $child = $currentFolder.ParseName($segment)
        if ($null -eq $child) {
            $location = if ($resolvedSoFar.Count -eq 0) { $DeviceItem.Name } else { "$($DeviceItem.Name)\$($resolvedSoFar -join '\')" }
            Write-Host ""
            Write-Host "[MTP] ERROR: '$segment' not found under '$location'" -ForegroundColor Red
            Write-Host ""
            List-MTPFolderContents -Folder $currentFolder -LocationLabel $location
            throw "Path segment '$segment' not found. Full path: $Path"
        }
        if (-not $child.IsFolder) {
            $location = if ($resolvedSoFar.Count -eq 0) { $DeviceItem.Name } else { "$($DeviceItem.Name)\$($resolvedSoFar -join '\')" }
            Write-Host ""
            Write-Host "[MTP] ERROR: '$segment' is not a folder under '$location'" -ForegroundColor Red
            throw "'$segment' is not a folder. Full path: $Path"
        }
        $resolvedSoFar += $segment
        $currentFolder = $child.GetFolder
    }

    return $currentFolder
}

function Get-MTPFileSize {
    param([System.__ComObject]$Item, [System.__ComObject]$ParentFolder)

    # Try ExtendedProperty first (returns raw bytes)
    try {
        $size = $Item.ExtendedProperty("System.Size")
        if ($null -ne $size) {
            return [long]$size
        }
    }
    catch {}

    # Fallback: parse GetDetailsOf column 2 (Size)
    try {
        $sizeStr = $ParentFolder.GetDetailsOf($Item, 2)
        if ($sizeStr) {
            # Remove formatting (spaces, commas, units) and try to parse
            $sizeStr = $sizeStr.Trim()
            # Try direct parse first (some systems return raw numbers)
            $parsed = 0L
            if ([long]::TryParse($sizeStr.Replace(",", "").Replace(".", "").Replace(" ", ""), [ref]$parsed)) {
                return $parsed
            }

            # Parse formatted sizes like "1.23 MB"
            if ($sizeStr -match '^([\d.,]+)\s*(bytes?|KB|MB|GB|TB)') {
                $num = [double]($matches[1].Replace(",", ""))
                $unit = $matches[2]
                switch -Wildcard ($unit) {
                    "byte*" { return [long]$num }
                    "KB"    { return [long]($num * 1024) }
                    "MB"    { return [long]($num * 1024 * 1024) }
                    "GB"    { return [long]($num * 1024 * 1024 * 1024) }
                    "TB"    { return [long]($num * 1024 * 1024 * 1024 * 1024) }
                }
            }
        }
    }
    catch {}

    return -1
}

function Scan-MTPFolderRecursive {
    param(
        [System.__ComObject]$Folder,
        [string]$RelativePath,
        [System.IO.StreamWriter]$Writer,
        [ref]$Counter
    )

    try {
        $items = $Folder.Items()
    }
    catch {
        Write-Warning "Cannot enumerate: $RelativePath - $_"
        return
    }

    foreach ($item in $items) {
        if ($item.IsFolder) {
            $subPath = if ($RelativePath) { "$RelativePath\$($item.Name)" } else { $item.Name }
            try {
                $subFolder = $item.GetFolder
                Scan-MTPFolderRecursive -Folder $subFolder -RelativePath $subPath -Writer $Writer -Counter $Counter
            }
            catch {
                Write-Warning "Cannot access folder: $subPath - $_"
            }
        }
        else {
            $size = Get-MTPFileSize -Item $item -ParentFolder $Folder
            $filePath = if ($RelativePath) { "$RelativePath\$($item.Name)" } else { $item.Name }
            $Writer.WriteLine("$filePath`t$size")
            $Counter.Value++

            if ($Counter.Value % 1000 -eq 0) {
                Write-Host "  ... $($Counter.Value) files discovered so far" -ForegroundColor DarkGray
                $Writer.Flush()
            }

            # Small yield to keep system responsive during heavy enumeration
            if ($Counter.Value % $script:ScanYieldInterval -eq 0) {
                Start-Sleep -Milliseconds $script:ScanYieldMs
            }
        }
    }
}

# ─── ScanOnly mode: scan MTP device, display results, and exit ──────────────

if ($ScanOnly) {
    Write-Host ""
    Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host " SCAN ONLY: Listing files on MTP device"                      -ForegroundColor Yellow
    Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Yellow

    Write-Host "[MTP] Looking for device: $DeviceName" -ForegroundColor Cyan
    $device = Get-MTPDevice -Name $DeviceName
    Write-Host "[MTP] Connected to: $($device.Name)" -ForegroundColor Green

    Write-Host "[MTP] Navigating to: $SourcePath" -ForegroundColor Cyan
    $sourceFolder = Navigate-MTPPath -DeviceItem $device -Path $SourcePath
    Write-Host "[MTP] Source folder opened successfully." -ForegroundColor Green
    Write-Host ""

    # Scan into memory and display each file as it's found
    $scanCount = [ref]0
    $totalSize = [ref]0L

    function Scan-MTPAndDisplay {
        param(
            [System.__ComObject]$Folder,
            [string]$RelativePath,
            [ref]$Counter,
            [ref]$TotalSize
        )

        try { $items = $Folder.Items() }
        catch {
            Write-Warning "Cannot enumerate: $RelativePath - $_"
            return
        }

        foreach ($item in $items) {
            if ($item.IsFolder) {
                $subPath = if ($RelativePath) { "$RelativePath\$($item.Name)" } else { $item.Name }
                try {
                    $subFolder = $item.GetFolder
                    Scan-MTPAndDisplay -Folder $subFolder -RelativePath $subPath -Counter $Counter -TotalSize $TotalSize
                }
                catch {
                    Write-Warning "Cannot access folder: $subPath - $_"
                }
            }
            else {
                $size = Get-MTPFileSize -Item $item -ParentFolder $Folder
                $filePath = if ($RelativePath) { "$RelativePath\$($item.Name)" } else { $item.Name }
                $Counter.Value++
                if ($size -ge 0) { $TotalSize.Value += $size }

                # Format size for display
                $sizeDisplay = if ($size -lt 0) { "unknown" }
                    elseif ($size -lt 1024) { "$size B" }
                    elseif ($size -lt 1048576) { "$([math]::Round($size / 1024, 1)) KB" }
                    elseif ($size -lt 1073741824) { "$([math]::Round($size / 1048576, 1)) MB" }
                    else { "$([math]::Round($size / 1073741824, 2)) GB" }

                Write-Host "  [$($Counter.Value)] $filePath  ($sizeDisplay)" -ForegroundColor Gray

                if ($Counter.Value % $script:ScanYieldInterval -eq 0) {
                    Start-Sleep -Milliseconds $script:ScanYieldMs
                }
            }
        }
    }

    Write-Host "[MTP] Scanning all files recursively..." -ForegroundColor Cyan
    Write-Host ""
    $scanStart = Get-Date
    Scan-MTPAndDisplay -Folder $sourceFolder -RelativePath "" -Counter $scanCount -TotalSize $totalSize
    $scanDuration = (Get-Date) - $scanStart

    # Format total size
    $ts = $totalSize.Value
    $totalDisplay = if ($ts -lt 1073741824) { "$([math]::Round($ts / 1048576, 1)) MB" }
        else { "$([math]::Round($ts / 1073741824, 2)) GB" }

    Write-Host ""
    Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host " SCAN COMPLETE"                                                -ForegroundColor Green
    Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "  Total files: $($scanCount.Value)"       -ForegroundColor Cyan
    Write-Host "  Total size:  $totalDisplay"              -ForegroundColor Cyan
    Write-Host "  Scan time:   $($scanDuration.ToString('hh\:mm\:ss'))" -ForegroundColor Cyan
    exit 0
}

# ─── Normal mode: Scan or load cache ────────────────────────────────────────

$mtpFiles = [System.Collections.Generic.List[PSCustomObject]]::new()

if (-not $Rescan -and (Test-Path $ScanCacheFile)) {
    Write-Host ""
    Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host " STEP 2: Loading cached MTP device scan"                      -ForegroundColor Yellow
    Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host "[MTP] Loading scan cache: $ScanCacheFile" -ForegroundColor Cyan
    Write-Host "[MTP] Use -Rescan to force a fresh device scan." -ForegroundColor Cyan

    $lineNum = 0
    foreach ($line in [System.IO.File]::ReadLines($ScanCacheFile, [System.Text.Encoding]::UTF8)) {
        $lineNum++
        if ($lineNum -eq 1) { continue }

        $parts = $line.Split("`t", 2)
        if ($parts.Length -eq 2) {
            $mtpFiles.Add([PSCustomObject]@{
                RelativePath = $parts[0]
                FileName     = [System.IO.Path]::GetFileName($parts[0])
                Size         = [long]$parts[1]
            })
        }
    }

    Write-Host "[MTP] Loaded $($mtpFiles.Count) files from scan cache." -ForegroundColor Green
}
else {
    Write-Host ""
    Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host " STEP 2: Scanning MTP device (this may take a while)"         -ForegroundColor Yellow
    Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Yellow

    Write-Host "[MTP] Looking for device: $DeviceName" -ForegroundColor Cyan
    $device = Get-MTPDevice -Name $DeviceName
    Write-Host "[MTP] Connected to: $($device.Name)" -ForegroundColor Green

    Write-Host "[MTP] Navigating to: $SourcePath" -ForegroundColor Cyan
    $sourceFolder = Navigate-MTPPath -DeviceItem $device -Path $SourcePath
    Write-Host "[MTP] Source folder opened successfully." -ForegroundColor Green

    Write-Host "[MTP] Scanning all files recursively..." -ForegroundColor Cyan
    $scanWriter = [System.IO.StreamWriter]::new($ScanCacheFile, $false, [System.Text.Encoding]::UTF8)
    $scanWriter.WriteLine("RelativePath`tSize")
    $scanCount = [ref]0

    $scanStart = Get-Date
    Scan-MTPFolderRecursive -Folder $sourceFolder -RelativePath "" -Writer $scanWriter -Counter $scanCount
    $scanWriter.Close()
    $scanDuration = (Get-Date) - $scanStart

    Write-Host "[MTP] Scan complete: $($scanCount.Value) files found in $($scanDuration.ToString('hh\:mm\:ss'))" -ForegroundColor Green
    Write-Host "[MTP] Scan cached to: $ScanCacheFile" -ForegroundColor Green

    # Load into memory
    $lineNum = 0
    foreach ($line in [System.IO.File]::ReadLines($ScanCacheFile, [System.Text.Encoding]::UTF8)) {
        $lineNum++
        if ($lineNum -eq 1) { continue }

        $parts = $line.Split("`t", 2)
        if ($parts.Length -eq 2) {
            $mtpFiles.Add([PSCustomObject]@{
                RelativePath = $parts[0]
                FileName     = [System.IO.Path]::GetFileName($parts[0])
                Size         = [long]$parts[1]
            })
        }
    }
}

if ($mtpFiles.Count -eq 0) {
    Write-Host "[MTP] No files found on device. Nothing to do." -ForegroundColor Yellow
    exit 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 3: Copy new files with resume support and progress tracking
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host " STEP 3: Copying new files to target folder"                  -ForegroundColor Yellow
Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Yellow

# Load resume state
$processedFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
if (Test-Path $StateFile) {
    foreach ($line in [System.IO.File]::ReadLines($StateFile, [System.Text.Encoding]::UTF8)) {
        $processedFiles.Add($line.Trim()) | Out-Null
    }
    Write-Host "[RESUME] Loaded $($processedFiles.Count) already-processed entries from previous run." -ForegroundColor Cyan
}

# Calculate remaining work
$totalOnDevice = $mtpFiles.Count
$alreadyProcessed = 0
$toProcess = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($f in $mtpFiles) {
    if ($processedFiles.Contains($f.RelativePath)) {
        $alreadyProcessed++
    }
    else {
        $toProcess.Add($f)
    }
}

$remaining = $toProcess.Count
Write-Host "[PROGRESS] Total files on device: $totalOnDevice" -ForegroundColor Cyan
Write-Host "[PROGRESS] Already processed (resume): $alreadyProcessed" -ForegroundColor Cyan
Write-Host "[PROGRESS] Remaining to process: $remaining" -ForegroundColor Cyan
Write-Host ""

if ($remaining -eq 0) {
    Write-Host "[DONE] All files have been processed. Nothing to do." -ForegroundColor Green
    exit 0
}

# Connect to MTP device for copying
Write-Host "[MTP] Connecting to device for file transfer..." -ForegroundColor Cyan
$script:shell = New-Object -ComObject Shell.Application
$device = Get-MTPDevice -Name $DeviceName
$script:sourceFolder = Navigate-MTPPath -DeviceItem $device -Path $SourcePath
Write-Host "[MTP] Ready to transfer." -ForegroundColor Green
Write-Host ""

# Helper: navigate from source folder to a file's parent folder on MTP
function Get-MTPParentAndItem {
    param(
        [System.__ComObject]$RootFolder,
        [string]$RelativePath
    )

    $parts = $RelativePath.Split('\')
    $currentFolder = $RootFolder

    # Navigate to the parent folder
    for ($i = 0; $i -lt $parts.Length - 1; $i++) {
        $child = $currentFolder.ParseName($parts[$i])
        if ($null -eq $child) { return $null }
        $currentFolder = $child.GetFolder
    }

    # Get the file item
    $fileName = $parts[$parts.Length - 1]
    $fileItem = $currentFolder.ParseName($fileName)

    return @{
        ParentFolder = $currentFolder
        FileItem     = $fileItem
    }
}

# Helper: reconnect to MTP device and re-navigate to source folder
function Reconnect-MTP {
    Write-Host "[MTP] Reconnecting to device..." -ForegroundColor Yellow
    # Invalidate folder caches
    $script:lastMtpParentPath = $null
    $script:lastMtpParentFolder = $null
    $script:lastMtpFolderItems = @{}
    $script:lastTargetShellDir = $null
    $script:lastTargetShellFolder = $null
    $newShell = New-Object -ComObject Shell.Application
    $newDevice = Get-MTPDevice -Name $DeviceName
    $newSourceFolder = Navigate-MTPPath -DeviceItem $newDevice -Path $SourcePath
    Write-Host "[MTP] Reconnected successfully." -ForegroundColor Green
    return @{ Shell = $newShell; SourceFolder = $newSourceFolder }
}

# Helper: retry an MTP operation with exponential backoff and reconnection
function Invoke-WithRetry {
    param(
        [scriptblock]$Operation,
        [string]$FileDescription,
        [string]$ProgressPrefix
    )

    $attempt = 0
    $currentWait = $RetryWaitSeconds

    while ($true) {
        try {
            return (& $Operation)
        }
        catch {
            $attempt++
            $errorMsg = $_.ToString()

            if ($attempt -le $RetryCount) {
                Write-Host "$ProgressPrefix RETRY ($attempt/$RetryCount): $FileDescription" -ForegroundColor Yellow
                Write-Host "  Error: $errorMsg" -ForegroundColor DarkGray

                # Try to reconnect first - if successful, retry immediately
                $reconnected = $false
                try {
                    $reconnect = Reconnect-MTP
                    $script:shell = $reconnect.Shell
                    $script:sourceFolder = $reconnect.SourceFolder
                    $reconnected = $true
                }
                catch {
                    Write-Host "$ProgressPrefix RETRY: Device not available, waiting ${currentWait}s..." -ForegroundColor DarkYellow
                    Start-Sleep -Seconds $currentWait
                    # Exponential backoff: double wait time, cap at 10 minutes
                    $currentWait = [math]::Min($currentWait * 2, $script:RetryBackoffMaxSeconds)
                }

                if ($reconnected) {
                    # Device is back - reset backoff and retry immediately
                    $currentWait = $RetryWaitSeconds
                }
            }
            else {
                # All retries exhausted
                switch ($OnFinalFailure) {
                    "Skip" {
                        Write-Host "$ProgressPrefix SKIP (retries exhausted): $FileDescription" -ForegroundColor Red
                        return $null
                    }
                    "Ask" {
                        while ($true) {
                            Write-Host ""
                            Write-Host "$ProgressPrefix FAILED after $RetryCount retries: $FileDescription" -ForegroundColor Red
                            Write-Host "  Error: $errorMsg" -ForegroundColor DarkGray
                            $response = Read-Host "  (S)kip this file, (R)etry again, or (W)ait forever?"
                            switch ($response.ToUpper()) {
                                "S" { return $null }
                                "R" {
                                    $attempt = 0
                                    $currentWait = $RetryWaitSeconds
                                    break
                                }
                                "W" {
                                    # Fall through to WaitForever behavior
                                    $attempt = 0
                                    $currentWait = $RetryWaitSeconds
                                    $script:OnFinalFailureOverride = "WaitForever"
                                    break
                                }
                                default {
                                    Write-Host "  Please enter S, R, or W" -ForegroundColor Gray
                                }
                            }
                            break
                        }
                    }
                    default {
                        # WaitForever: reset retry counter and keep going
                        Write-Host "$ProgressPrefix WAITING: Retries exhausted but will keep trying. Plug the phone back in..." -ForegroundColor Yellow
                        Write-Host "  Press Ctrl+C to abort." -ForegroundColor DarkGray
                        $attempt = 0
                        $currentWait = $RetryWaitSeconds

                        # Try reconnect first - only sleep if device not available
                        try {
                            $reconnect = Reconnect-MTP
                            $script:shell = $reconnect.Shell
                            $script:sourceFolder = $reconnect.SourceFolder
                        }
                        catch {
                            Write-Host "$ProgressPrefix WAITING: Device not available yet, waiting ${currentWait}s..." -ForegroundColor DarkYellow
                            Start-Sleep -Seconds $currentWait
                        }
                    }
                }
            }
        }
    }
}

# ─── Background spinner for real-time progress during blocking CopyHere ────────
# CopyHere blocks the main thread, so we use a background runspace to update the console.

$script:spinnerSync = [hashtable]::Synchronized(@{
    Active     = $false
    Stop       = $false
    Prefix     = ""
    FileName   = ""
    SizeDisplay = ""
    FileSize   = 0L
    TargetPath = ""
    StartTicks = 0L
    ProgressMs = $script:CopyProgressMs
})

$script:spinnerRunspace = [runspacefactory]::CreateRunspace()
$script:spinnerRunspace.Open()
$script:spinnerPs = [powershell]::Create().AddScript({
    param($sync)
    $chars = '|/-\'
    $i = 0
    while (-not $sync.Stop) {
        if ($sync.Active) {
            $spin = $chars[$i % 4]
            $i++
            $elapsedSec = ([System.Diagnostics.Stopwatch]::GetTimestamp() - $sync.StartTicks) / [System.Diagnostics.Stopwatch]::Frequency
            $elapsedDisplay = [math]::Round($elapsedSec)
            try { [Console]::Write("`r$($sync.Prefix) COPYING: $($sync.FileName) ($($sync.SizeDisplay)) ${elapsedDisplay}s $spin   ") } catch {}
        }
        [System.Threading.Thread]::Sleep($sync.ProgressMs)
    }
}).AddArgument($script:spinnerSync)
$script:spinnerPs.Runspace = $script:spinnerRunspace
$script:spinnerHandle = $script:spinnerPs.BeginInvoke()

# Open state file for appending
$stateWriter = [System.IO.StreamWriter]::new($StateFile, $true, [System.Text.Encoding]::UTF8)

$copyCount = 0
$skipCount = 0
$errorCount = 0
$processedCount = 0
$script:totalBytesCopied = 0L
$startTime = Get-Date

# Caches for MTP folder navigation and target shell folder (avoid re-navigating per file)
$script:lastMtpParentPath = $null
$script:lastMtpParentFolder = $null
$script:lastMtpFolderItems = @{}
$script:lastTargetShellDir = $null
$script:lastTargetShellFolder = $null

foreach ($file in $toProcess) {
    $processedCount++
    $absolutePos = $alreadyProcessed + $processedCount
    $remainingNow = $remaining - $processedCount

    # ETA calculation
    $elapsed = (Get-Date) - $startTime
    if ($processedCount -gt 1 -and $elapsed.TotalSeconds -gt 0) {
        $rate = $processedCount / $elapsed.TotalSeconds
        $etaSeconds = [math]::Round($remainingNow / $rate)
        $eta = [TimeSpan]::FromSeconds($etaSeconds)
        $etaStr = $eta.ToString('hh\:mm\:ss')
    }
    else {
        $etaStr = "calculating..."
    }

    $ts = [datetime]::Now.ToString("HH:mm:ss")
    $progressPrefix = "[$ts $absolutePos/$totalOnDevice | Left: $remainingNow | ETA: $etaStr]"

    # Check if file exists in local index
    $lookupKey = $file.FileName + "|" + $file.Size

    if ($fileIndex.Contains($lookupKey)) {
        # File already exists in backup
        $existingPath = ""
        if ($fileIndexPaths.ContainsKey($lookupKey)) {
            $existingPath = $fileIndexPaths[$lookupKey]
        }
        Write-Host "$progressPrefix SKIP: $($file.RelativePath) - already exists at: $existingPath" -ForegroundColor DarkYellow
        $stateWriter.WriteLine($file.RelativePath)
        $skipCount++
    }
    else {
        # File is new - copy it
        # Determine target path
        $targetFilePath = Join-Path $TargetFolder $file.RelativePath
        $targetDir = [System.IO.Path]::GetDirectoryName($targetFilePath)

        # Check if file already exists in target with same size
        if (Test-Path -LiteralPath $targetFilePath) {
            $existingSize = (Get-Item -LiteralPath $targetFilePath).Length
            if ($file.Size -lt 0 -or $existingSize -eq $file.Size) {
                Write-Host "$progressPrefix SKIP: $($file.RelativePath) - already exists in target folder" -ForegroundColor DarkYellow
                $stateWriter.WriteLine($file.RelativePath)
                $skipCount++
                continue
            }
        }

        # Create target directory if needed
        if (-not (Test-Path $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }

        # Show message before copy starts
        $sizeDisplay = if ($file.Size -lt 0) { "unknown size" }
            elseif ($file.Size -lt 1024) { "$($file.Size) B" }
            elseif ($file.Size -lt 1048576) { "$([math]::Round($file.Size / 1024, 1)) KB" }
            elseif ($file.Size -lt 1073741824) { "$([math]::Round($file.Size / 1048576, 1)) MB" }
            else { "$([math]::Round($file.Size / 1073741824, 2)) GB" }
        Write-Host "$progressPrefix COPYING: $($file.RelativePath) ($sizeDisplay) ..." -NoNewline

        # ── Inline copy with retry (no scriptblock overhead) ──────────────
        $tmpFileName = "~" + $file.FileName + ".tmp"
        $tmpFilePath = Join-Path $targetDir $tmpFileName
        $retryAttempt = 0
        $retryWait = $RetryWaitSeconds
        $copiedSize = 0L
        $copySuccess = $false
        $copySkipped = $false

        while (-not $copySuccess -and -not $copySkipped) {
            try {
                # On retry: clean up leftovers
                if ($retryAttempt -gt 0) {
                    foreach ($p in @($tmpFilePath, $targetFilePath)) {
                        if ([System.IO.File]::Exists($p)) {
                            try { [System.IO.File]::SetAttributes($p, [System.IO.FileAttributes]::Normal) } catch {}
                            try { [System.IO.File]::Delete($p) } catch {}
                        }
                    }
                }

                # Navigate MTP and find file item (cached per-folder)
                $bmSw = [System.Diagnostics.Stopwatch]::StartNew()
                $relParts = $file.RelativePath.Split('\')
                $parentPath = if ($relParts.Length -gt 1) { ($relParts[0..($relParts.Length - 2)]) -join '\' } else { "" }

                if ($parentPath -ne $script:lastMtpParentPath) {
                    # Navigate to folder
                    if ($parentPath -eq "") {
                        $script:lastMtpParentFolder = $script:sourceFolder
                    }
                    else {
                        $nav = $script:sourceFolder
                        for ($i = 0; $i -lt $relParts.Length - 1; $i++) {
                            $child = $nav.ParseName($relParts[$i])
                            if ($null -eq $child) { throw "MTP path not found: $parentPath" }
                            $nav = $child.GetFolder
                        }
                        $script:lastMtpParentFolder = $nav
                    }
                    $script:lastMtpParentPath = $parentPath

                    # Pre-enumerate ALL items in this folder into a dictionary for fast lookup.
                    # MTP ParseName does a slow linear scan — this avoids calling it per file.
                    $bmEnumSw = [System.Diagnostics.Stopwatch]::StartNew()
                    $script:lastMtpFolderItems = @{}
                    foreach ($mtpItem in $script:lastMtpParentFolder.Items()) {
                        $script:lastMtpFolderItems[$mtpItem.Name] = $mtpItem
                    }
                    $bmEnumSw.Stop()
                    Write-Host "  [Cached $($script:lastMtpFolderItems.Count) items from MTP folder: $parentPath in $($bmEnumSw.ElapsedMilliseconds)ms]" -ForegroundColor DarkGray
                }

                $fileName = $relParts[$relParts.Length - 1]
                $fileItem = $script:lastMtpFolderItems[$fileName]
                if ($null -eq $fileItem) { throw "File not found on device: $($file.RelativePath)" }
                $bmSw.Stop(); $bmNav = $bmSw.ElapsedMilliseconds

                # Cache target shell folder
                $bmSw = [System.Diagnostics.Stopwatch]::StartNew()
                if ($targetDir -ne $script:lastTargetShellDir) {
                    $script:lastTargetShellFolder = $script:shell.NameSpace($targetDir)
                    $script:lastTargetShellDir = $targetDir
                }
                if ($null -eq $script:lastTargetShellFolder) { throw "Cannot access target folder: $targetDir" }
                $bmSw.Stop(); $bmTgt = $bmSw.ElapsedMilliseconds

                # Start spinner, then CopyHere (blocks until MTP transfer is done)
                $script:spinnerSync.Prefix = $progressPrefix
                $script:spinnerSync.FileName = $file.RelativePath
                $script:spinnerSync.SizeDisplay = $sizeDisplay
                $script:spinnerSync.FileSize = $file.Size
                $script:spinnerSync.TargetPath = $targetFilePath
                $script:spinnerSync.StartTicks = [System.Diagnostics.Stopwatch]::GetTimestamp()
                $script:spinnerSync.Active = $true
                $fileCopyStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

                $script:lastTargetShellFolder.CopyHere($fileItem, 0x10)

                $fileCopyStopwatch.Stop()
                $script:spinnerSync.Active = $false
                $bmCopy = $fileCopyStopwatch.ElapsedMilliseconds

                # Verify file arrived (CopyHere is usually synchronous, but check)
                $bmSw = [System.Diagnostics.Stopwatch]::StartNew()
                if (-not [System.IO.File]::Exists($targetFilePath)) {
                    $pollSw = [System.Diagnostics.Stopwatch]::StartNew()
                    $script:spinnerSync.Active = $true
                    while (-not [System.IO.File]::Exists($targetFilePath)) {
                        if ($pollSw.Elapsed.TotalMinutes -gt $script:CopyTimeoutMinutes) {
                            $script:spinnerSync.Active = $false
                            throw "Timeout waiting for file"
                        }
                        [System.Threading.Thread]::Sleep($script:CopyPollMs)
                    }
                    $script:spinnerSync.Active = $false
                }
                $bmSw.Stop(); $bmVerify = $bmSw.ElapsedMilliseconds

                # Clear spinner line
                Write-Host "`r$(' ' * 160)`r" -NoNewline

                # CopyHere is atomic: if the file exists, it's complete.
                $copiedSize = $file.Size

                if ($Benchmark) {
                    Write-Host "  [BENCH nav:${bmNav}ms copy:${bmCopy}ms verify:${bmVerify}ms tgt:${bmTgt}ms total:$($bmNav+$bmCopy+$bmVerify+$bmTgt)ms]" -ForegroundColor DarkGray
                }

                $copySuccess = $true
            }
            catch {
                $script:spinnerSync.Active = $false
                Write-Host "`r$(' ' * 160)`r" -NoNewline
                $retryAttempt++
                $errorMsg = $_.ToString()

                if ($retryAttempt -le $RetryCount) {
                    Write-Host "$progressPrefix RETRY ($retryAttempt/$RetryCount): $($file.RelativePath)" -ForegroundColor Yellow
                    Write-Host "  Error: $errorMsg" -ForegroundColor DarkGray

                    # Try reconnect first - if successful, retry immediately
                    try {
                        $reconnect = Reconnect-MTP
                        $script:shell = $reconnect.Shell
                        $script:sourceFolder = $reconnect.SourceFolder
                        $retryWait = $RetryWaitSeconds  # reset backoff
                    }
                    catch {
                        Write-Host "$progressPrefix RETRY: Device not available, waiting ${retryWait}s..." -ForegroundColor DarkYellow
                        Start-Sleep -Seconds $retryWait
                        $retryWait = [math]::Min($retryWait * 2, $script:RetryBackoffMaxSeconds)
                    }
                }
                else {
                    # All retries exhausted
                    switch ($OnFinalFailure) {
                        "Skip" {
                            Write-Host "$progressPrefix SKIP (retries exhausted): $($file.RelativePath)" -ForegroundColor Red
                            $copySkipped = $true
                        }
                        "Ask" {
                            :askLoop while ($true) {
                                Write-Host ""
                                Write-Host "$progressPrefix FAILED after $RetryCount retries: $($file.RelativePath)" -ForegroundColor Red
                                Write-Host "  Error: $errorMsg" -ForegroundColor DarkGray
                                $resp = Read-Host "  (S)kip this file, (R)etry again, or (W)ait forever?"
                                switch ($resp.ToUpper()) {
                                    "S" { $copySkipped = $true; break askLoop }
                                    "R" { $retryAttempt = 0; $retryWait = $RetryWaitSeconds; break askLoop }
                                    "W" { $retryAttempt = 0; $retryWait = $RetryWaitSeconds; break askLoop }
                                    default { Write-Host "  Please enter S, R, or W" -ForegroundColor Gray }
                                }
                            }
                        }
                        default {
                            # WaitForever
                            Write-Host "$progressPrefix WAITING: Plug the phone back in... (Ctrl+C to abort)" -ForegroundColor Yellow
                            $retryAttempt = 0
                            $retryWait = $RetryWaitSeconds
                            try {
                                $reconnect = Reconnect-MTP
                                $script:shell = $reconnect.Shell
                                $script:sourceFolder = $reconnect.SourceFolder
                            }
                            catch {
                                Write-Host "$progressPrefix WAITING: Device not available yet, waiting ${retryWait}s..." -ForegroundColor DarkYellow
                                Start-Sleep -Seconds $retryWait
                            }
                        }
                    }
                }
            }
        }

        # Record result
        if ($copySkipped) {
            # Clean up any partial/temp files
            foreach ($p in @($tmpFilePath, $targetFilePath)) {
                if ([System.IO.File]::Exists($p)) {
                    try { [System.IO.File]::SetAttributes($p, [System.IO.FileAttributes]::Normal) } catch {}
                    try { [System.IO.File]::Delete($p) } catch {}
                }
            }
            $errorCount++
            $stateWriter.WriteLine($file.RelativePath)
        }
        elseif ($copySuccess) {
            $fileSecs = $fileCopyStopwatch.Elapsed.TotalSeconds
            $fileMBs = if ($fileSecs -gt 0.01) { [math]::Round(($copiedSize / 1048576) / $fileSecs, 1) } else { 0 }
            $script:totalBytesCopied += $copiedSize
            $sizeMatch = if ($file.Size -ge 0) { $copiedSize -eq $file.Size } else { $true }

            $tsNow = [datetime]::Now.ToString("HH:mm:ss")
            if ($sizeMatch) {
                Write-Host "[$tsNow] COPIED: $($file.RelativePath) ($([math]::Round($copiedSize / 1MB, 2)) MB) @ ${fileMBs} MB/s" -ForegroundColor Green
            }
            else {
                Write-Host "[$tsNow] COPIED (size differs): $($file.RelativePath) @ ${fileMBs} MB/s" -ForegroundColor Yellow
            }

            $newKey = $file.FileName + "|" + $copiedSize
            $fileIndex.Add($newKey) | Out-Null
            $fileIndexPaths[$newKey] = $targetFilePath
            $stateWriter.WriteLine($file.RelativePath)
            $copyCount++

            if ($MaxCopyCount -gt 0 -and $copyCount -ge $MaxCopyCount) {
                Write-Host ""
                Write-Host "[LIMIT] Reached -MaxCopyCount $MaxCopyCount. Stopping." -ForegroundColor Yellow
                $stateWriter.Flush()
                break
            }
        }
    }

    # Flush state periodically for crash safety
    if ($processedCount % 50 -eq 0) {
        $stateWriter.Flush()
    }
}

$stateWriter.Close()

# Stop background spinner
$script:spinnerSync.Stop = $true
try {
    $script:spinnerPs.EndInvoke($script:spinnerHandle)
    $script:spinnerPs.Dispose()
    $script:spinnerRunspace.Close()
    $script:spinnerRunspace.Dispose()
}
catch {}

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════

$totalElapsed = (Get-Date) - $startTime

Write-Host ""
Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host " COMPLETE"                                                     -ForegroundColor Green
Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Green
$totalCopiedMB = [math]::Round($script:totalBytesCopied / 1048576, 1)
$totalCopiedDisplay = if ($script:totalBytesCopied -lt 1073741824) { "${totalCopiedMB} MB" }
    else { "$([math]::Round($script:totalBytesCopied / 1073741824, 2)) GB" }
$avgSpeed = if ($totalElapsed.TotalSeconds -gt 0.1 -and $script:totalBytesCopied -gt 0) {
    [math]::Round(($script:totalBytesCopied / 1048576) / $totalElapsed.TotalSeconds, 1)
} else { 0 }

Write-Host "  Files copied:  $copyCount ($totalCopiedDisplay)"   -ForegroundColor Green
Write-Host "  Files skipped: $skipCount"   -ForegroundColor DarkYellow
Write-Host "  Errors:        $errorCount"  -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Time elapsed:  $($totalElapsed.ToString('hh\:mm\:ss'))" -ForegroundColor Cyan
if ($avgSpeed -gt 0) {
    Write-Host "  Avg speed:     ${avgSpeed} MB/s" -ForegroundColor Cyan
}
Write-Host ""
Write-Host "  Target folder: $TargetFolder" -ForegroundColor Cyan

if ($errorCount -gt 0) {
    Write-Host ""
    Write-Host "  Some files had errors. Re-run with the same parameters to retry." -ForegroundColor Yellow
}
