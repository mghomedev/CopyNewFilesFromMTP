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

.PARAMETER NewerThan
    Only copy files whose modification date on the MTP device is newer than
    the specified cutoff. Supports relative timespans and absolute dates:
    - Relative: 2h (hours), 3d (days), 2w (weeks), 6m (months), 1y (years)
    - Absolute date: 2025-01-15 (yyyy-MM-dd)
    - Absolute date+time: 2025-01-15T14:30 (yyyy-MM-ddTHH:mm)
    Files with no retrievable modification date pass the filter (are not skipped).

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

    [string]$NewerThan = "",

    [switch]$CloudSyncSafe,
    [int]$MaxCopyCount = 0,
    [switch]$Benchmark
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── Version info ──────────────────────────────────────────────────────────────

$script:AppVersion   = "1.6.0"
$script:AppBuildDate = "2026-04-10"

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

# ─── Cache file headers and footers ────────────────────────────────────────────
# All cache/state files start with two header lines and end with a footer line:
#   Line 1: version   — "# CopyNewFilesFromMTP vX.Y.Z"
#   Line 2: params    — "# Params: <key>=<value> | <key>=<value> | ..."
#   ...data lines...
#   Last line: footer  — "# Completed: 2026-04-10T14:30:00"
#
# The footer proves the file was written completely. If the footer is missing
# (e.g., script crashed mid-write), the cache is rejected on next load.

$script:CacheVersionHeader = "# CopyNewFilesFromMTP v$($script:AppVersion)"
$script:CacheFooterPrefix  = "# Completed: "

function Build-CacheParamsLine {
    param([hashtable]$Params)
    $parts = @()
    foreach ($key in ($Params.Keys | Sort-Object)) {
        $parts += "$key=$($Params[$key])"
    }
    return "# Params: " + ($parts -join " | ")
}

function Get-CacheFooterLine {
    return $script:CacheFooterPrefix + [datetime]::Now.ToString('yyyy-MM-ddTHH:mm:ss')
}

function Read-CacheFooter {
    param([string]$FilePath)
    # Returns the completion timestamp string if a valid footer exists, or $null
    if (-not (Test-Path $FilePath)) { return $null }
    try {
        $lines = [System.IO.File]::ReadAllLines($FilePath, [System.Text.Encoding]::UTF8)
        if ($lines.Length -eq 0) { return $null }
        $lastLine = $lines[$lines.Length - 1]
        if ($lastLine.StartsWith($script:CacheFooterPrefix)) {
            return $lastLine.Substring($script:CacheFooterPrefix.Length)
        }
        return $null
    }
    catch { return $null }
}

function Test-CacheHeader {
    param(
        [string]$FilePath,
        [string]$ExpectedParamsLine,
        [switch]$RequireFooter
    )
    if (-not (Test-Path $FilePath)) { return $false }
    try {
        $reader = [System.IO.StreamReader]::new($FilePath, [System.Text.Encoding]::UTF8)
        $line1 = $reader.ReadLine()
        $line2 = $reader.ReadLine()
        $reader.Close()
        if ($line1 -ne $script:CacheVersionHeader) { return $false }
        if ($ExpectedParamsLine -and $line2 -ne $ExpectedParamsLine) { return $false }
        # Check footer exists (file was written completely) — only for index/scan cache
        if ($RequireFooter) {
            $footer = Read-CacheFooter $FilePath
            if ($null -eq $footer) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Write-CacheHeaders {
    param(
        [System.IO.StreamWriter]$Writer,
        [string]$ParamsLine
    )
    $Writer.WriteLine($script:CacheVersionHeader)
    $Writer.WriteLine($ParamsLine)
}

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
    Write-Host "    -NewerThan           Only copy files newer than: 2h, 3d, 2w, 6m, 1y, or 2025-01-15"
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

# ─── Parse -NewerThan into a cutoff DateTime ──────────────────────────────────

$script:NewerThanCutoff = $null

if ($NewerThan) {
    $now = [datetime]::Now
    # Try relative timespan: number + unit (h/d/w/m/y)
    if ($NewerThan -match '^\s*(\d+)\s*(h|d|w|m|y)\s*$') {
        $amount = [int]$matches[1]
        $unit = $matches[2]
        switch ($unit) {
            'h' { $script:NewerThanCutoff = $now.AddHours(-$amount) }
            'd' { $script:NewerThanCutoff = $now.AddDays(-$amount) }
            'w' { $script:NewerThanCutoff = $now.AddDays(-($amount * 7)) }
            'm' { $script:NewerThanCutoff = $now.AddMonths(-$amount) }
            'y' { $script:NewerThanCutoff = $now.AddYears(-$amount) }
        }
    }
    else {
        # Try absolute date/datetime (yyyy-MM-dd or yyyy-MM-ddTHH:mm)
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($NewerThan, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            $script:NewerThanCutoff = $parsed
        }
        elseif ([datetime]::TryParseExact($NewerThan, 'yyyy-MM-dd\THH:mm', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            $script:NewerThanCutoff = $parsed
        }
        elseif ([datetime]::TryParse($NewerThan, [ref]$parsed)) {
            $script:NewerThanCutoff = $parsed
        }
        else {
            throw "-NewerThan value '$NewerThan' is not recognized. Use: 2h, 3d, 2w, 6m, 1y, 2025-01-15, or 2025-01-15T14:30"
        }
    }

    Write-Host "[FILTER] -NewerThan: only copying files modified after $($script:NewerThanCutoff.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan
}

# ─── Build cache parameter lines for each cache file type ─────────────────────

$script:ScanCacheParams = Build-CacheParamsLine @{
    DeviceName = $DeviceName
    SourcePath = $SourcePath
}

if (-not $ScanOnly) {
    $sortedIgnore = ($IgnoreFilesInFoldersBySizeAndName | Sort-Object) -join ";"
    $script:IndexParams = Build-CacheParamsLine @{
        IgnoreFolders = $sortedIgnore
    }
    $script:StateParams = Build-CacheParamsLine @{
        DeviceName = $DeviceName
        SourcePath = $SourcePath
        TargetFolder = $TargetFolder
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
    $hasIndex = $IndexFile -and (Test-Path $IndexFile) -and (Test-CacheHeader $IndexFile $script:IndexParams -RequireFooter)
    $hasState = $StateFile -and (Test-Path $StateFile) -and (Test-CacheHeader $StateFile $script:StateParams)
    $hasScanCache = $ScanCacheFile -and (Test-Path $ScanCacheFile) -and (Test-CacheHeader $ScanCacheFile $script:ScanCacheParams -RequireFooter)
    # Detect and warn about incompatible or incomplete files
    $hasStaleFiles = $false
    $staleReasons = @()
    foreach ($check in @(
        @{ Path=$IndexFile; Params=$script:IndexParams; Name="index"; Footer=$true },
        @{ Path=$ScanCacheFile; Params=$script:ScanCacheParams; Name="scan cache"; Footer=$true },
        @{ Path=$StateFile; Params=$script:StateParams; Name="state"; Footer=$false }
    )) {
        if ($check.Path -and (Test-Path $check.Path)) {
            $ok = if ($check.Footer) { Test-CacheHeader $check.Path $check.Params -RequireFooter } else { Test-CacheHeader $check.Path $check.Params }
            if (-not $ok) {
                $hasStaleFiles = $true
                $staleReasons += $check.Name
            }
        }
    }
    if ($hasStaleFiles) {
        Write-Host ""
        Write-Host "[CACHE] Incompatible cache files detected ($($staleReasons -join ', ')). They will be rebuilt." -ForegroundColor Yellow
        Write-Host "[CACHE] This happens when the script version or input parameters (device, paths) have changed." -ForegroundColor Yellow
    }
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
            $resumeStats.IndexDate = Read-CacheFooter $IndexFile
            $resumeStats.IndexLines = ([System.IO.File]::ReadAllLines($IndexFile)).Count - 4  # minus version + params + column header + footer
        }
        if ($hasScanCache) {
            $resumeStats.ScanDate = Read-CacheFooter $ScanCacheFile
            $resumeStats.ScanTotal = ([System.IO.File]::ReadAllLines($ScanCacheFile)).Count - 4  # minus version + params + column header + footer
        }
        if ($hasState) {
            $stateFooter = Read-CacheFooter $StateFile
            if ($stateFooter) {
                $resumeStats.StateDate = $stateFooter
                $resumeStats.StateComplete = $true
                $resumeStats.StateProcessed = ([System.IO.File]::ReadAllLines($StateFile)).Count - 3  # minus version + params header + footer
            }
            else {
                $fi = [System.IO.FileInfo]::new($StateFile)
                $resumeStats.StateDate = $fi.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
                $resumeStats.StateComplete = $false
                $resumeStats.StateProcessed = ([System.IO.File]::ReadAllLines($StateFile)).Count - 2  # minus version + params header
            }
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
                    $stateLabel = if ($resumeStats.StateComplete) { "completed $($resumeStats.StateDate)" } else { "interrupted, last activity $($resumeStats.StateDate)" }
                    Write-Host "  Already processed:     $($resumeStats.StateProcessed)   ($stateLabel)" -ForegroundColor Gray
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
                    Write-Host "  File index:     $($resumeStats.IndexLines) entries   (completed $($resumeStats.IndexDate))" -ForegroundColor Gray
                    Write-Host "                  $IndexFile" -ForegroundColor DarkGray
                }
                if ($hasScanCache) {
                    Write-Host "  MTP scan cache: $($resumeStats.ScanTotal) files on device   (completed $($resumeStats.ScanDate))" -ForegroundColor Gray
                    Write-Host "                  $ScanCacheFile" -ForegroundColor DarkGray
                }
                if ($hasState) {
                    $stateLabel = if ($resumeStats.StateComplete) { "completed $($resumeStats.StateDate)" } else { "interrupted, last activity $($resumeStats.StateDate)" }
                    Write-Host "  Resume state:   $($resumeStats.StateProcessed) files processed   ($stateLabel)" -ForegroundColor Gray
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
    Write-CacheHeaders -Writer $writer -ParamsLine $script:IndexParams
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

    $writer.WriteLine((Get-CacheFooterLine))
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
        if ($lineNum -le 3) { continue } # skip version header + params header + column header
        if ($line.StartsWith('#')) { continue } # skip footer

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
    # Check if index needs to be built (or rebuilt due to version mismatch)
    $indexVersionOk = (Test-Path $IndexFile) -and (Test-CacheHeader $IndexFile $script:IndexParams -RequireFooter)
    if (-not $indexVersionOk -and (Test-Path $IndexFile)) {
        $reason = if ($null -eq (Read-CacheFooter $IndexFile)) { "incomplete (previous build may have crashed)" } else { "incompatible (different version or ignore folders)" }
        Write-Host "[INDEX] Index file is $reason. Rebuilding..." -ForegroundColor Yellow
    }
    if ($RebuildIndex -or -not $indexVersionOk) {
        $builtCount = Build-FileIndex -Folders $IgnoreFilesInFoldersBySizeAndName -OutputFile $IndexFile
        if ($builtCount -eq 0) {
            Confirm-Continue -Message 'The generated ignore index is empty (0 files). This means no files will be skipped during copy - everything from the device will be copied. Did you make a mistake?'
        }
    }
    else {
        $indexFooterDate = Read-CacheFooter $IndexFile
        Write-Host ""
        Write-Host "[INDEX] File index already exists: $IndexFile" -ForegroundColor Cyan
        Write-Host "[INDEX] Index completed: $indexFooterDate. Use -RebuildIndex to force rebuild." -ForegroundColor Cyan
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

function Get-MTPFileDate {
    param([System.__ComObject]$Item, [System.__ComObject]$ParentFolder)

    # Try ExtendedProperty first (returns DateTime)
    try {
        $dateVal = $Item.ExtendedProperty("System.DateModified")
        if ($null -ne $dateVal) {
            return [datetime]$dateVal
        }
    }
    catch {}

    # Fallback: GetDetailsOf column 3 (Date modified)
    try {
        $dateStr = $ParentFolder.GetDetailsOf($Item, 3)
        if ($dateStr) {
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParse($dateStr.Trim(), [ref]$parsed)) {
                return $parsed
            }
        }
    }
    catch {}

    return $null
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
            $dateObj = Get-MTPFileDate -Item $item -ParentFolder $Folder
            $dateStr = if ($null -ne $dateObj) { $dateObj.ToString('o') } else { "" }
            $filePath = if ($RelativePath) { "$RelativePath\$($item.Name)" } else { $item.Name }
            $Writer.WriteLine("$filePath`t$size`t$dateStr")
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

$scanCacheVersionOk = (Test-Path $ScanCacheFile) -and (Test-CacheHeader $ScanCacheFile $script:ScanCacheParams -RequireFooter)
if (-not $scanCacheVersionOk -and -not $Rescan -and (Test-Path $ScanCacheFile)) {
    $reason = if ($null -eq (Read-CacheFooter $ScanCacheFile)) { "incomplete (previous scan may have crashed)" } else { "incompatible (different version, device, or source path)" }
    Write-Host "[MTP] Scan cache is $reason. Rescanning..." -ForegroundColor Yellow
}

if (-not $Rescan -and $scanCacheVersionOk) {
    Write-Host ""
    Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host " STEP 2: Loading cached MTP device scan"                      -ForegroundColor Yellow
    Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    $scanFooterDate = Read-CacheFooter $ScanCacheFile
    Write-Host "[MTP] Loading scan cache: $ScanCacheFile" -ForegroundColor Cyan
    Write-Host "[MTP] Cache completed: $scanFooterDate. Use -Rescan to force a fresh device scan." -ForegroundColor Cyan

    $lineNum = 0
    foreach ($line in [System.IO.File]::ReadLines($ScanCacheFile, [System.Text.Encoding]::UTF8)) {
        $lineNum++
        if ($lineNum -le 3) { continue }
        if ($line.StartsWith('#')) { continue } # skip footer

        $parts = $line.Split("`t")
        if ($parts.Length -ge 2) {
            $fileDate = $null
            if ($parts.Length -ge 3 -and $parts[2]) {
                try { $fileDate = [datetime]::Parse($parts[2]) } catch {}
            }
            $mtpFiles.Add([PSCustomObject]@{
                RelativePath = $parts[0]
                FileName     = $parts[0].Substring($parts[0].LastIndexOf('\') + 1)
                Size         = [long]$parts[1]
                DateModified = $fileDate
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
    Write-CacheHeaders -Writer $scanWriter -ParamsLine $script:ScanCacheParams
    $scanWriter.WriteLine("RelativePath`tSize`tDateModified")
    $scanCount = [ref]0

    $scanStart = Get-Date
    Scan-MTPFolderRecursive -Folder $sourceFolder -RelativePath "" -Writer $scanWriter -Counter $scanCount
    $scanWriter.WriteLine((Get-CacheFooterLine))
    $scanWriter.Close()
    $scanDuration = (Get-Date) - $scanStart

    Write-Host "[MTP] Scan complete: $($scanCount.Value) files found in $($scanDuration.ToString('hh\:mm\:ss'))" -ForegroundColor Green
    Write-Host "[MTP] Scan cached to: $ScanCacheFile" -ForegroundColor Green

    # Load into memory
    $lineNum = 0
    foreach ($line in [System.IO.File]::ReadLines($ScanCacheFile, [System.Text.Encoding]::UTF8)) {
        $lineNum++
        if ($lineNum -le 3) { continue }
        if ($line.StartsWith('#')) { continue } # skip footer

        $parts = $line.Split("`t")
        if ($parts.Length -ge 2) {
            $fileDate = $null
            if ($parts.Length -ge 3 -and $parts[2]) {
                try { $fileDate = [datetime]::Parse($parts[2]) } catch {}
            }
            $mtpFiles.Add([PSCustomObject]@{
                RelativePath = $parts[0]
                FileName     = $parts[0].Substring($parts[0].LastIndexOf('\') + 1)
                Size         = [long]$parts[1]
                DateModified = $fileDate
            })
        }
    }
}

if ($mtpFiles.Count -eq 0) {
    Write-Host "[MTP] No files found on device. Nothing to do." -ForegroundColor Yellow
    exit 0
}

# ─── Apply -NewerThan date filter ──────────────────────────────────────────────

if ($script:NewerThanCutoff) {
    $beforeCount = $mtpFiles.Count
    $filteredFiles = [System.Collections.Generic.List[PSCustomObject]]::new()
    $skippedByDate = 0
    $noDateCount = 0
    foreach ($f in $mtpFiles) {
        if ($null -eq $f.DateModified) {
            $noDateCount++
            $filteredFiles.Add($f)
        }
        elseif ($f.DateModified -ge $script:NewerThanCutoff) {
            $filteredFiles.Add($f)
        }
        else {
            $skippedByDate++
        }
    }
    $mtpFiles = $filteredFiles
    Write-Host "[FILTER] Date filter applied: $($mtpFiles.Count) files pass (skipped $skippedByDate older files)" -ForegroundColor Cyan
    if ($noDateCount -gt 0) {
        Write-Host "[FILTER] WARNING: $noDateCount files had no date metadata and were included (not skipped)" -ForegroundColor Yellow
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 3: Copy new files with resume support and progress tracking
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host " STEP 3: Copying new files to target folder"                  -ForegroundColor Yellow
Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Yellow

# Load resume state (only if version and parameters match)
$processedFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
if ((Test-Path $StateFile) -and (Test-CacheHeader $StateFile $script:StateParams)) {
    foreach ($line in [System.IO.File]::ReadLines($StateFile, [System.Text.Encoding]::UTF8)) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith('#')) { continue }
        $processedFiles.Add($trimmed) | Out-Null
    }
    Write-Host "[RESUME] Loaded $($processedFiles.Count) already-processed entries from previous run." -ForegroundColor Cyan
}
elseif (Test-Path $StateFile) {
    Write-Host "[RESUME] State file is incompatible (different version, device, or target). Starting fresh." -ForegroundColor Yellow
    Remove-Item -LiteralPath $StateFile -Force
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

# Open state file for appending (write headers if new)
$stateFileIsNew = -not (Test-Path $StateFile)
$stateWriter = [System.IO.StreamWriter]::new($StateFile, $true, [System.Text.Encoding]::UTF8)
if ($stateFileIsNew) {
    Write-CacheHeaders -Writer $stateWriter -ParamsLine $script:StateParams
}

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

$stateWriter.WriteLine((Get-CacheFooterLine))
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
