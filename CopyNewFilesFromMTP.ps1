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
    Path to the file index. Default: <TargetFolder>\_file_index.tsv

.PARAMETER StateFile
    Path to the resume state file. Default: <TargetFolder>\_resume_state.txt

.PARAMETER ScanCacheFile
    Path to cache the MTP device scan. Default: <TargetFolder>\_mtp_scan_cache.tsv

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
    [string]$ResumeMode = "Ask"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── Version info ──────────────────────────────────────────────────────────────

$script:AppVersion   = "1.3.0"
$script:AppBuildDate = "2026-04-04"

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
    if (-not $IndexFile)     { $IndexFile     = Join-Path $TargetFolder "_file_index.tsv" }
    if (-not $StateFile)     { $StateFile     = Join-Path $TargetFolder "_resume_state.txt" }
    if (-not $ScanCacheFile) { $ScanCacheFile = Join-Path $TargetFolder "_mtp_scan_cache.tsv" }
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

        switch ($ResumeMode) {
            "Continue" {
                Write-Host "[RESUME] Found previous state ($stateList). Continuing from last run." -ForegroundColor Cyan
            }
            "Fresh" {
                $startFresh = $true
            }
            default {
                # Ask the user
                Write-Host ""
                Write-Host "[RESUME] Found previous state from an earlier run:" -ForegroundColor Yellow
                if ($hasIndex)     { Write-Host "  - File index:     $IndexFile" -ForegroundColor Gray }
                if ($hasScanCache) { Write-Host "  - MTP scan cache: $ScanCacheFile" -ForegroundColor Gray }
                if ($hasState)     { Write-Host "  - Resume state:   $StateFile" -ForegroundColor Gray }
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
                if ($_.Name.StartsWith("_file_index") -or $_.Name.StartsWith("_resume_state") -or $_.Name.StartsWith("_mtp_scan")) {
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
            if ($Counter.Value % 500 -eq 0) {
                Start-Sleep -Milliseconds 1
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

                if ($Counter.Value % 500 -eq 0) {
                    Start-Sleep -Milliseconds 1
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
                    $currentWait = [math]::Min($currentWait * 2, 600)
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

# Open state file for appending
$stateWriter = [System.IO.StreamWriter]::new($StateFile, $true, [System.Text.Encoding]::UTF8)

$copyCount = 0
$skipCount = 0
$errorCount = 0
$processedCount = 0
$startTime = Get-Date

foreach ($file in $toProcess) {
    $processedCount++
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

    $progressPrefix = "[$processedCount/$remaining | Left: $remainingNow | ETA: $etaStr]"

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

        # Copy with retry support for MTP disconnections
        # Strategy: CopyHere to target dir, immediately rename to ~filename.tmp with
        # Temporary+Hidden attributes (Dropbox/OneDrive skip these), verify, then rename to final name.
        $currentFile = $file
        $currentTargetDir = $targetDir
        $currentTargetFilePath = $targetFilePath
        $tmpFileName = "~" + $file.FileName + ".tmp"
        $tmpFilePath = Join-Path $targetDir $tmpFileName

        # Clean up leftover ~.tmp from a previous failed attempt
        if (Test-Path -LiteralPath $tmpFilePath) {
            # Remove Hidden+Temporary attributes so we can delete
            $fi = Get-Item -LiteralPath $tmpFilePath -Force
            $fi.Attributes = $fi.Attributes -band (-bnot ([System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::Temporary))
            Remove-Item -LiteralPath $tmpFilePath -Force -ErrorAction SilentlyContinue
        }

        # Show message before copy starts
        $sizeDisplay = if ($file.Size -lt 0) { "unknown size" }
            elseif ($file.Size -lt 1024) { "$($file.Size) B" }
            elseif ($file.Size -lt 1048576) { "$([math]::Round($file.Size / 1024, 1)) KB" }
            elseif ($file.Size -lt 1073741824) { "$([math]::Round($file.Size / 1048576, 1)) MB" }
            else { "$([math]::Round($file.Size / 1073741824, 2)) GB" }
        Write-Host "$progressPrefix COPYING: $($file.RelativePath) ($sizeDisplay) ..." -ForegroundColor White -NoNewline

        $copyResult = Invoke-WithRetry -FileDescription $file.RelativePath -ProgressPrefix $progressPrefix -Operation {
            # Clean up partial ~.tmp and any original-name leftover before each retry
            foreach ($cleanPath in @($tmpFilePath, $currentTargetFilePath)) {
                if (Test-Path -LiteralPath $cleanPath) {
                    $cfi = Get-Item -LiteralPath $cleanPath -Force
                    $cfi.Attributes = $cfi.Attributes -band (-bnot ([System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::Temporary))
                    Remove-Item -LiteralPath $cleanPath -Force -ErrorAction SilentlyContinue
                }
            }

            # Navigate to file on MTP device
            $mtpResult = Get-MTPParentAndItem -RootFolder $script:sourceFolder -RelativePath $currentFile.RelativePath

            if ($null -eq $mtpResult -or $null -eq $mtpResult.FileItem) {
                throw "File not found on device: $($currentFile.RelativePath)"
            }

            # Copy using Shell COM into target directory (file appears with original name)
            $targetShellFolder = $script:shell.NameSpace($currentTargetDir)
            if ($null -eq $targetShellFolder) {
                throw "Cannot access target folder: $currentTargetDir"
            }

            # Flags: 0x4 = no progress dialog, 0x10 = yes to all, 0x400 = no UI on error
            $targetShellFolder.CopyHere($mtpResult.FileItem, 0x414)

            # Wait for file to appear and show progress with spinner
            $spinChars = @('|', '/', '-', '\')
            $spinIdx = 0
            $waitStart = Get-Date
            $lastProgressUpdate = [datetime]::MinValue
            $timeout = [TimeSpan]::FromMinutes(30)
            $expectedSize = $currentFile.Size
            $fileAppeared = $false

            while ($true) {
                $now = Get-Date

                if (-not $fileAppeared) {
                    # Waiting for file to appear
                    if (Test-Path $currentTargetFilePath) {
                        $fileAppeared = $true
                    }
                    elseif (($now - $waitStart) -gt $timeout) {
                        Write-Host ""
                        throw "Timeout waiting for file copy to start"
                    }
                }

                if ($fileAppeared) {
                    # File exists - check if copy is complete (size matches or size stopped growing)
                    try {
                        $currentSize = (Get-Item -LiteralPath $currentTargetFilePath -Force).Length
                    }
                    catch {
                        $currentSize = 0
                    }

                    # Show progress once per second
                    if (($now - $lastProgressUpdate).TotalMilliseconds -ge 500) {
                        $spin = $spinChars[$spinIdx % 4]
                        $spinIdx++

                        if ($expectedSize -gt 0) {
                            $pct = [math]::Min(100, [math]::Round(($currentSize / $expectedSize) * 100))
                            Write-Host "`r$progressPrefix COPYING: $($currentFile.RelativePath) ($sizeDisplay) $spin ${pct}%   " -ForegroundColor White -NoNewline
                        }
                        else {
                            $copiedDisplay = if ($currentSize -lt 1048576) { "$([math]::Round($currentSize / 1024, 1)) KB" }
                                else { "$([math]::Round($currentSize / 1048576, 1)) MB" }
                            Write-Host "`r$progressPrefix COPYING: $($currentFile.RelativePath) ($sizeDisplay) $spin $copiedDisplay   " -ForegroundColor White -NoNewline
                        }
                        $lastProgressUpdate = $now
                    }

                    # Check if done: size matches expected, or for unknown sizes wait for file to be stable
                    if ($expectedSize -gt 0 -and $currentSize -ge $expectedSize) {
                        break
                    }
                    elseif ($expectedSize -le 0 -and $currentSize -gt 0) {
                        # Unknown expected size - wait a bit for stability
                        Start-Sleep -Milliseconds 500
                        try {
                            $recheckSize = (Get-Item -LiteralPath $currentTargetFilePath -Force).Length
                        }
                        catch { $recheckSize = -1 }
                        if ($recheckSize -eq $currentSize) { break }
                    }

                    if (($now - $waitStart) -gt $timeout) {
                        Write-Host ""
                        throw "Timeout waiting for file copy to complete"
                    }
                }

                Start-Sleep -Milliseconds 200
            }

            # Clear the progress line
            Write-Host "`r$(' ' * 200)`r" -NoNewline

            # Immediately rename to ~filename.tmp and set attributes so cloud sync ignores it
            Rename-Item -LiteralPath $currentTargetFilePath -NewName $tmpFileName -Force
            $tmpItem = Get-Item -LiteralPath $tmpFilePath -Force
            $tmpItem.Attributes = $tmpItem.Attributes -bor [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::Temporary

            # Verify size
            $copiedSize = $tmpItem.Length
            if ($currentFile.Size -ge 0 -and $copiedSize -ne $currentFile.Size) {
                Remove-Item -LiteralPath $tmpFilePath -Force -ErrorAction SilentlyContinue
                throw "Copy incomplete: expected $($currentFile.Size) bytes but got $copiedSize bytes"
            }

            return @{ CopiedSize = $copiedSize }
        }

        if ($null -eq $copyResult) {
            # File was skipped after retries - clean up
            if (Test-Path -LiteralPath $tmpFilePath) {
                $fi = Get-Item -LiteralPath $tmpFilePath -Force
                $fi.Attributes = $fi.Attributes -band (-bnot ([System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::Temporary))
                Remove-Item -LiteralPath $tmpFilePath -Force -ErrorAction SilentlyContinue
            }
            $errorCount++
            $stateWriter.WriteLine($file.RelativePath)
        }
        else {
            # Promote: clear attributes and rename to final name (atomic, same volume)
            $tmpItem = Get-Item -LiteralPath $tmpFilePath -Force
            $tmpItem.Attributes = $tmpItem.Attributes -band (-bnot ([System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::Temporary))
            Rename-Item -LiteralPath $tmpFilePath -NewName ([System.IO.Path]::GetFileName($targetFilePath)) -Force

            $copiedSize = $copyResult.CopiedSize
            $sizeMatch = if ($file.Size -ge 0) { $copiedSize -eq $file.Size } else { $true }

            if ($sizeMatch) {
                Write-Host "$progressPrefix COPIED: $($file.RelativePath) ($([math]::Round($copiedSize / 1MB, 2)) MB)" -ForegroundColor Green
            }
            else {
                Write-Host "$progressPrefix COPIED (size differs - MTP: $($file.Size), Local: $copiedSize): $($file.RelativePath)" -ForegroundColor Yellow
            }

            # Add to index so we don't copy it again if the same filename appears
            $newKey = $file.FileName + "|" + $copiedSize
            $fileIndex.Add($newKey) | Out-Null
            $fileIndexPaths[$newKey] = $targetFilePath

            $stateWriter.WriteLine($file.RelativePath)
            $copyCount++
        }
    }

    # Flush state periodically for crash safety
    if ($processedCount % 50 -eq 0) {
        $stateWriter.Flush()
    }

    # Throttle to keep system responsive
    if ($ThrottleDelayMs -gt 0) {
        Start-Sleep -Milliseconds $ThrottleDelayMs
    }
}

$stateWriter.Close()

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════

$totalElapsed = (Get-Date) - $startTime

Write-Host ""
Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host " COMPLETE"                                                     -ForegroundColor Green
Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Files copied:  $copyCount"   -ForegroundColor Green
Write-Host "  Files skipped: $skipCount"   -ForegroundColor DarkYellow
Write-Host "  Errors:        $errorCount"  -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Time elapsed:  $($totalElapsed.ToString('hh\:mm\:ss'))" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Target folder: $TargetFolder" -ForegroundColor Cyan

if ($errorCount -gt 0) {
    Write-Host ""
    Write-Host "  Some files had errors. Re-run with the same parameters to retry." -ForegroundColor Yellow
}
