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
    [Parameter(Mandatory = $true)]
    [string]$DeviceName,

    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [string[]]$IgnoreFilesInFoldersBySizeAndName = @(),
    [string]$TargetFolder = "",

    [switch]$ScanOnly,
    [string]$IndexFile = "",
    [string]$StateFile = "",
    [string]$ScanCacheFile = "",
    [switch]$RebuildIndex,
    [switch]$Rescan,
    [int]$ThrottleDelayMs = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── Validate parameters ───────────────────────────────────────────────────────

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
$shell = New-Object -ComObject Shell.Application
$device = Get-MTPDevice -Name $DeviceName
$sourceFolder = Navigate-MTPPath -DeviceItem $device -Path $SourcePath
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
        try {
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

            # Navigate to file on MTP device
            $mtpResult = Get-MTPParentAndItem -RootFolder $sourceFolder -RelativePath $file.RelativePath

            if ($null -eq $mtpResult -or $null -eq $mtpResult.FileItem) {
                Write-Host "$progressPrefix ERROR: File not found on device: $($file.RelativePath)" -ForegroundColor Red
                $errorCount++
                $stateWriter.WriteLine($file.RelativePath)
                continue
            }

            # Copy using Shell COM
            $targetShellFolder = $shell.NameSpace($targetDir)
            if ($null -eq $targetShellFolder) {
                Write-Host "$progressPrefix ERROR: Cannot access target folder: $targetDir" -ForegroundColor Red
                $errorCount++
                continue
            }

            # Flags: 0x4 = no progress dialog, 0x10 = yes to all, 0x400 = no UI on error
            $targetShellFolder.CopyHere($mtpResult.FileItem, 0x414)

            # Wait for copy to complete (CopyHere can be async)
            $fileName = $file.FileName
            $targetFile = Join-Path $targetDir $fileName
            $waitStart = Get-Date
            $timeout = [TimeSpan]::FromMinutes(30) # 30 min timeout per file

            while (-not (Test-Path $targetFile)) {
                Start-Sleep -Milliseconds 200
                if (((Get-Date) - $waitStart) -gt $timeout) {
                    throw "Timeout waiting for file copy to complete"
                }
            }

            # Verify size if possible (MTP sizes can sometimes be approximate)
            $copiedSize = (Get-Item -LiteralPath $targetFile).Length
            $sizeMatch = if ($file.Size -ge 0) { $copiedSize -eq $file.Size } else { $true }

            if ($sizeMatch) {
                Write-Host "$progressPrefix COPIED: $($file.RelativePath) ($([math]::Round($copiedSize / 1MB, 2)) MB)" -ForegroundColor Green
            }
            else {
                Write-Host "$progressPrefix COPIED (size differs - MTP: $($file.Size), Local: $copiedSize): $($file.RelativePath)" -ForegroundColor Yellow
            }

            # Add to index so we don't copy it again if the same filename appears
            $newKey = "$fileName|$copiedSize"
            $fileIndex.Add($newKey) | Out-Null
            $fileIndexPaths[$newKey] = $targetFile

            $stateWriter.WriteLine($file.RelativePath)
            $copyCount++
        }
        catch {
            Write-Host "$progressPrefix ERROR copying $($file.RelativePath): $_" -ForegroundColor Red
            $errorCount++
            # Don't write to state file on error so it gets retried next run
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
