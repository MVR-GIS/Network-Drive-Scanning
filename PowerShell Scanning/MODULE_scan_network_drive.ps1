<#
.SYNOPSIS
    Network Drive Metadata Scanner Module - Optimized for Speed and Efficiency
    
.DESCRIPTION
    Provides Invoke-NetworkDriveScan function for scanning network drives and creating 
    tab-delimited inventories with metadata. Designed to be imported and called from 
    other scripts for parallel drive scanning.
    
    OPTIMIZATIONS:
    - Writes to plain CSV during scan (3-5x faster than GZIP)
    - Compresses to GZIP only at end (one-time cost)
    - Tab-delimited format (no escaping needed, faster)
    - Lightweight progress file (stats + last 1000 paths only)
    - Smart resume with minimal memory usage
    - Full-row deduplication after scan
    - Enhanced error handling and diagnostics
    - Logs inaccessible files/folders and continues scanning
    
.NOTES
    Author: Ryan Benac (Modular Version 4.0)
    Version: 4.0
    
.EXAMPLE
    # Import the module
    . .\NetworkDriveScannerModule.ps1
    
    # Scan a single drive
    Invoke-NetworkDriveScan -DrivePath "T:\" -DrivePrefix "T" -OutputPath "C:\Scans"
    
.EXAMPLE
    # Scan multiple drives in parallel
    $drives = @(
        @{Path="T:\"; Prefix="T"},
        @{Path="S:\"; Prefix="S"}
    )
    
    $drives | ForEach-Object -Parallel {
        . .\NetworkDriveScannerModule.ps1
        Invoke-NetworkDriveScan -DrivePath $_.Path -DrivePrefix $_.Prefix -OutputPath "C:\Scans"
    } -ThrottleLimit 3
#>

# ============================================================================
# HELPER FUNCTIONS (Private)
# ============================================================================

function Write-TimestampedHost {
    param(
        [string]$Message,
        [string]$ForegroundColor = "White"
    )
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $ForegroundColor
}

function Get-MostRecentScanFile {
    param([string]$Prefix, [string]$Path)
    
    $pattern = "$Prefix`_network_drive_metadata_*.csv.gz"
    $existingFiles = Get-ChildItem -Path $Path -Filter $pattern -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    
    return $existingFiles
}

function Test-ShouldSkipScan {
    param(
        [string]$Prefix, 
        [string]$Path, 
        [int]$ThresholdDays
    )
    
    # Check for incomplete scans
    $progressFiles = Get-ChildItem -Path $Path -Filter "$Prefix`_scan_progress_*.json" -ErrorAction SilentlyContinue
    if ($progressFiles) {
        Write-TimestampedHost "Found incomplete scan with progress file" -ForegroundColor Yellow
        return $false
    }
    
    # Check for completed scans
    $recentFile = Get-MostRecentScanFile -Prefix $Prefix -Path $Path
    
    if ($recentFile) {
        $age = (Get-Date) - $recentFile.LastWriteTime
        if ($age.TotalDays -lt $ThresholdDays) {
            Write-TimestampedHost "Found recent scan: $($recentFile.Name) ($(([math]::Round($age.TotalHours, 1))) hours old)" -ForegroundColor Yellow
            Write-TimestampedHost "Skipping scan (threshold: $ThresholdDays days)" -ForegroundColor Yellow
            return $true
        } else {
            Write-TimestampedHost "Found old scan: $($recentFile.Name) ($(([math]::Round($age.TotalDays, 1))) days old)" -ForegroundColor Yellow
            Write-TimestampedHost "Will create new scan and delete old file upon completion" -ForegroundColor Cyan
            return $false
        }
    }
    
    Write-TimestampedHost "No previous scan found" -ForegroundColor Cyan
    return $false
}

function Save-ProgressFile {
    param(
        [string]$ProgressFile,
        [hashtable]$Data
    )
    
    $json = $Data | ConvertTo-Json -Depth 3
    [System.IO.File]::WriteAllText($ProgressFile, $json, [System.Text.Encoding]::UTF8)
}

function Get-ProgressFile {
    param([string]$ProgressFile)
    
    if (Test-Path $ProgressFile) {
        $json = [System.IO.File]::ReadAllText($ProgressFile, [System.Text.Encoding]::UTF8)
        return $json | ConvertFrom-Json
    }
    return $null
}

function Remove-DuplicateRows {
    param([string]$InputFile, [string]$OutputFile)
    
    Write-TimestampedHost "Deduplicating rows (full row comparison)..." -ForegroundColor Cyan
    
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $reader = [System.IO.StreamReader]::new($InputFile, [System.Text.Encoding]::UTF8)
    $writer = [System.IO.StreamWriter]::new($OutputFile, $false, [System.Text.Encoding]::UTF8)
    
    # Copy header
    $header = $reader.ReadLine()
    $writer.WriteLine($header)
    [void]$seen.Add($header)
    
    $lineCount = 0
    $uniqueCount = 0
    $duplicateCount = 0
    
    while ($null -ne ($line = $reader.ReadLine())) {
        $lineCount++
        
        if ($seen.Add($line)) {
            $writer.WriteLine($line)
            $uniqueCount++
        } else {
            $duplicateCount++
        }
        
        if ($lineCount % 500000 -eq 0) {
            Write-TimestampedHost "  Processed $lineCount rows ($duplicateCount duplicates removed)..." -ForegroundColor Yellow
        }
    }
    
    $reader.Close()
    $writer.Close()
    
    Write-TimestampedHost "Deduplication complete: $uniqueCount unique rows, $duplicateCount duplicates removed" -ForegroundColor Green
}

function Compress-ToGzip {
    param([string]$InputFile, [string]$OutputFile)
    
    Write-TimestampedHost "Compressing to GZIP..." -ForegroundColor Cyan
    
    $inputStream = [System.IO.File]::OpenRead($InputFile)
    $outputStream = [System.IO.File]::Create($OutputFile)
    $gzipStream = [System.IO.Compression.GZipStream]::new($outputStream, [System.IO.Compression.CompressionMode]::Compress)
    
    $buffer = New-Object byte[] 81920  # 80KB buffer
    $totalBytes = $inputStream.Length
    $bytesProcessed = 0
    $lastProgress = 0
    
    while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $gzipStream.Write($buffer, 0, $read)
        $bytesProcessed += $read
        
        $percentComplete = [math]::Round(($bytesProcessed / $totalBytes) * 100)
        if ($percentComplete -ge $lastProgress + 10) {
            Write-TimestampedHost "  Compression progress: $percentComplete%" -ForegroundColor Yellow
            $lastProgress = $percentComplete
        }
    }
    
    $inputStream.Close()
    $gzipStream.Close()
    $outputStream.Close()
    
    $originalSize = [math]::Round((Get-Item $InputFile).Length / 1MB, 2)
    $compressedSize = [math]::Round((Get-Item $OutputFile).Length / 1MB, 2)
    $ratio = [math]::Round(($compressedSize / $originalSize) * 100, 1)
    
    Write-TimestampedHost "Compression complete: $originalSize MB → $compressedSize MB ($ratio%)" -ForegroundColor Green
}

# ============================================================================
# MAIN PUBLIC FUNCTION
# ============================================================================

function Invoke-NetworkDriveScan {
    <#
    .SYNOPSIS
        Scans a network drive and creates a compressed metadata inventory.
    
    .DESCRIPTION
        Recursively scans the specified drive path, collecting metadata for all files,
        folders, and geodatabases. Outputs a tab-delimited, GZIP-compressed CSV file.
        Supports resume capability for interrupted scans.
    
    .PARAMETER DrivePath
        The path to scan (e.g., "T:\", "\\server\share\folder")
    
    .PARAMETER DrivePrefix
        Short identifier for output files (e.g., "T", "EGIS", "S")
    
    .PARAMETER OutputPath
        Directory where output files will be saved
    
    .PARAMETER RescanThresholdDays
        Skip scan if a recent scan exists within this many days (default: 1)
    
    .PARAMETER BatchSize
        Number of items to batch before writing to disk (default: 50000)
    
    .PARAMETER ProgressInterval
        Console progress update frequency in items (default: 10000)
    
    .PARAMETER CheckpointInterval
        Progress file update frequency in items (default: 1000)
    
    .PARAMETER RecentPathsToKeep
        Number of recent paths to track for resume (default: 1000)
    
    .PARAMETER AutoResume
        Automatically resume incomplete scans without prompting (default: $false)
    
    .EXAMPLE
        Invoke-NetworkDriveScan -DrivePath "T:\" -DrivePrefix "T" -OutputPath "C:\Scans"
    
    .EXAMPLE
        Invoke-NetworkDriveScan -DrivePath "\\server\share" -DrivePrefix "SHARE" -OutputPath "C:\Scans" -RescanThresholdDays 7
    
    .OUTPUTS
        Creates a GZIP-compressed CSV file with metadata for all scanned items
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$DrivePath,
        
        [Parameter(Mandatory=$true)]
        [string]$DrivePrefix,
        
        [Parameter(Mandatory=$true)]
        [string]$OutputPath,
        
        [Parameter(Mandatory=$false)]
        [int]$RescanThresholdDays = 1,
        
        [Parameter(Mandatory=$false)]
        [int]$BatchSize = 50000,
        
        [Parameter(Mandatory=$false)]
        [int]$ProgressInterval = 10000,
        
        [Parameter(Mandatory=$false)]
        [int]$CheckpointInterval = 1000,
        
        [Parameter(Mandatory=$false)]
        [int]$RecentPathsToKeep = 1000,
        
        [Parameter(Mandatory=$false)]
        [switch]$AutoResume
    )
    
    Write-TimestampedHost "========================================" -ForegroundColor Cyan
    Write-TimestampedHost "Starting scan: $DrivePath (Prefix: $DrivePrefix)" -ForegroundColor Cyan
    Write-TimestampedHost "========================================" -ForegroundColor Cyan
    
    # Create output directory if it doesn't exist
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        Write-TimestampedHost "Created output directory: $OutputPath" -ForegroundColor Green
    }
    
    # NORMALIZE PATH: Remove trailing backslash for consistency
    $DrivePath = $DrivePath.TrimEnd('\')
    Write-TimestampedHost "Normalized path: $DrivePath" -ForegroundColor DarkGray
    
    # VALIDATE PATH ACCESS
    if (-not (Test-Path -LiteralPath $DrivePath)) {
        Write-TimestampedHost "ERROR: Cannot access path: $DrivePath" -ForegroundColor Red
        Write-TimestampedHost "Skipping this drive." -ForegroundColor Yellow
        return @{
            Success = $false
            Error = "Path not accessible"
            DrivePath = $DrivePath
            DrivePrefix = $DrivePrefix
        }
    }
    
    Write-TimestampedHost "Path access verified" -ForegroundColor Green
    
    # Check if we should skip this scan
    if (Test-ShouldSkipScan -Prefix $DrivePrefix -Path $OutputPath -ThresholdDays $RescanThresholdDays) {
        Write-TimestampedHost "Skipping $DrivePath" -ForegroundColor Green
        return @{
            Success = $true
            Skipped = $true
            DrivePath = $DrivePath
            DrivePrefix = $DrivePrefix
        }
    }
    
    # Setup file paths
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $tempCsvFile = Join-Path $OutputPath "$DrivePrefix`_network_drive_metadata_$timestamp.csv"
    $finalGzipFile = Join-Path $OutputPath "$DrivePrefix`_network_drive_metadata_$timestamp.csv.gz"
    $progressFile = Join-Path $OutputPath "$DrivePrefix`_scan_progress_$timestamp.json"
    
    # Check for existing progress file (resume capability)
    $existingProgress = Get-ChildItem -Path $OutputPath -Filter "$DrivePrefix`_scan_progress_*.json" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    
    $resumeMode = $false
    $resumeData = $null
    $recentPathsHashSet = $null
    
    if ($existingProgress) {
        Write-TimestampedHost "Found existing progress file: $($existingProgress.Name)" -ForegroundColor Yellow
        
        if ($AutoResume) {
            $response = "R"
            Write-TimestampedHost "AutoResume enabled - resuming scan automatically" -ForegroundColor Green
        } else {
            $response = Read-Host "Do you want to (R)esume, (S)tart over, or (C)ancel? [R/S/C]"
        }
        
        switch ($response.ToUpper()) {
            "R" {
                $resumeMode = $true
                $progressFile = $existingProgress.FullName
                $resumeData = Get-ProgressFile -ProgressFile $progressFile
                
                if ($resumeData) {
                    # Extract timestamp from progress file to find matching CSV
                    if ($existingProgress.Name -match "$DrivePrefix`_scan_progress_(\d{8}_\d{6})\.json") {
                        $existingTimestamp = $matches[1]
                        $tempCsvFile = Join-Path $OutputPath "$DrivePrefix`_network_drive_metadata_$existingTimestamp.csv"
                        $finalGzipFile = Join-Path $OutputPath "$DrivePrefix`_network_drive_metadata_$existingTimestamp.csv.gz"
                    }
                    
                    Write-TimestampedHost "Resuming scan from checkpoint..." -ForegroundColor Green
                    Write-TimestampedHost "Previous progress: $($resumeData.ItemsProcessed) items" -ForegroundColor Cyan
                    
                    # Load last N paths into HashSet for fast skip
                    $recentPathsHashSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                    if ($resumeData.LastProcessedPaths) {
                        foreach ($path in $resumeData.LastProcessedPaths) {
                            [void]$recentPathsHashSet.Add($path)
                        }
                        Write-TimestampedHost "Loaded $($recentPathsHashSet.Count) recent paths for fast skip" -ForegroundColor Green
                    }
                } else {
                    Write-TimestampedHost "ERROR: Could not load progress file. Starting over." -ForegroundColor Red
                    $resumeMode = $false
                }
            }
            "S" {
                Write-TimestampedHost "Starting new scan..." -ForegroundColor Green
                
                # Clean up old files
                if ($existingProgress.Name -match "$DrivePrefix`_scan_progress_(\d{8}_\d{6})\.json") {
                    $oldTimestamp = $matches[1]
                    $oldCsvFile = Join-Path $OutputPath "$DrivePrefix`_network_drive_metadata_$oldTimestamp.csv"
                    
                    Remove-Item $existingProgress.FullName -Force -ErrorAction SilentlyContinue
                    Write-TimestampedHost "Deleted old progress file" -ForegroundColor Yellow
                    
                    if (Test-Path $oldCsvFile) {
                        Remove-Item $oldCsvFile -Force -ErrorAction SilentlyContinue
                        Write-TimestampedHost "Deleted partial CSV file" -ForegroundColor Yellow
                    }
                }
            }
            "C" {
                Write-TimestampedHost "Scan cancelled by user" -ForegroundColor Yellow
                return @{
                    Success = $false
                    Cancelled = $true
                    DrivePath = $DrivePath
                    DrivePrefix = $DrivePrefix
                }
            }
            default {
                Write-TimestampedHost "Invalid response. Skipping this drive." -ForegroundColor Red
                return @{
                    Success = $false
                    Error = "Invalid user response"
                    DrivePath = $DrivePath
                    DrivePrefix = $DrivePrefix
                }
            }
        }
    }
    
    Write-TimestampedHost "Temp CSV file: $tempCsvFile" -ForegroundColor Cyan
    Write-TimestampedHost "Final output: $finalGzipFile" -ForegroundColor Cyan
    Write-TimestampedHost "Progress file: $progressFile" -ForegroundColor Cyan
    Write-TimestampedHost "" -ForegroundColor White
    
    # Initialize script-scope counters
    $script:counter = 0
    $script:skippedCounter = 0
    $script:errorCounter = if ($resumeMode -and $resumeData) { $resumeData.ErrorsCount } else { 0 }
    $script:fileCounter = if ($resumeMode -and $resumeData) { $resumeData.FilesCount } else { 0 }
    $script:folderCounter = if ($resumeMode -and $resumeData) { $resumeData.FoldersCount } else { 0 }
    $script:gdbCounter = if ($resumeMode -and $resumeData) { $resumeData.GDBCount } else { 0 }
    
    $previousTotal = if ($resumeMode -and $resumeData) { $resumeData.ItemsProcessed } else { 0 }
    
    # Initialize batches
    $csvBatch = [System.Collections.Generic.List[string]]::new($BatchSize)
    $recentPathsList = [System.Collections.Generic.List[string]]::new($RecentPathsToKeep)
    
    # Load existing recent paths if resuming
    if ($resumeMode -and $resumeData -and $resumeData.LastProcessedPaths) {
        foreach ($path in $resumeData.LastProcessedPaths) {
            $recentPathsList.Add($path)
        }
    }
    
    # Initialize CSV writer
    $streamWriter = $null
    $scanSuccessful = $false
    
    try {
        # Open CSV file
        if ($resumeMode -and (Test-Path $tempCsvFile)) {
            # Append mode
            $streamWriter = [System.IO.StreamWriter]::new($tempCsvFile, $true, [System.Text.Encoding]::UTF8)
            Write-TimestampedHost "Appending to existing CSV file" -ForegroundColor Cyan
        } else {
            # Create new file
            $streamWriter = [System.IO.StreamWriter]::new($tempCsvFile, $false, [System.Text.Encoding]::UTF8)
            # Write header (tab-delimited)
            $streamWriter.WriteLine("FullPath`tName`tType`tExtension`tSizeBytes`tCreated`tModified`tParentPath`tStatus`tErrorMessage")
            $streamWriter.Flush()
            Write-TimestampedHost "Created new CSV file with header" -ForegroundColor Green
        }
        
        # Flush CSV batch to file
        function Write-CsvBatch {
            if ($csvBatch.Count -gt 0) {
                foreach ($line in $csvBatch) {
                    $streamWriter.WriteLine($line)
                }
                $streamWriter.Flush()
                $csvBatch.Clear()
            }
        }
        
        # Update progress file
        function Update-ProgressFile {
            $progressData = @{
                DrivePrefix = $DrivePrefix
                DrivePath = $DrivePath
                StartTime = if ($resumeMode -and $resumeData) { $resumeData.StartTime } else { $timestamp }
                LastUpdate = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
                ItemsProcessed = $previousTotal + $script:counter
                FilesCount = $script:fileCounter
                FoldersCount = $script:folderCounter
                GDBCount = $script:gdbCounter
                ErrorsCount = $script:errorCounter
                SkippedCount = $script:skippedCounter
                LastProcessedPaths = @($recentPathsList.ToArray())
            }
            
            Save-ProgressFile -ProgressFile $progressFile -Data $progressData
        }
        
        # Process individual item
        function Add-ItemToScan {
            param($item, $errorMessage = $null, $status = "Success")
            
            # Skip if in recent paths (resume mode fast skip)
            if ($resumeMode -and $recentPathsHashSet -and $recentPathsHashSet.Contains($item.FullName)) {
                $script:skippedCounter++
                return
            }
            
            # Skip if inside a .gdb folder (but not the .gdb folder itself)
            $pathStr = $item.FullName
            if ($pathStr.Contains('.gdb\') -and -not $pathStr.EndsWith('.gdb')) {
                return
            }
            
            $script:counter++
            
            # Progress output
            if ($script:counter % $ProgressInterval -eq 0) {
                $totalProcessed = $previousTotal + $script:counter
                $msg = "Processed $totalProcessed total items ($($script:counter) new)"
                if ($resumeMode) { $msg += " (Skipped: $($script:skippedCounter))" }
                $msg += " | Files: $($script:fileCounter), Folders: $($script:folderCounter), GDBs: $($script:gdbCounter), Errors: $($script:errorCounter)"
                Write-TimestampedHost $msg -ForegroundColor Yellow
            }
            
            # Determine type and extension
            $isGDB = $item.PSIsContainer -and $item.Name -match '\.gdb$'
            $type = if ($isGDB) { "GDB" } elseif ($item.PSIsContainer) { "Folder" } else { "File" }
            $extension = if ($item.PSIsContainer) { "" } else { $item.Extension }
            
            # Update counters
            if ($type -eq "File") { $script:fileCounter++ }
            elseif ($type -eq "Folder") { $script:folderCounter++ }
            elseif ($type -eq "GDB") { $script:gdbCounter++ }
            
            # Get parent path
            $parentPath = Split-Path $item.FullName -Parent
            
            # Build tab-delimited line
            $sizeBytes = if ($item.PSIsContainer) { "" } else { $item.Length }
            $created = if ($item.CreationTime) { $item.CreationTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "" }
            $modified = if ($item.LastWriteTime) { $item.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "" }
            $errorMsg = if ($errorMessage) { $errorMessage.Replace("`t", " ").Replace("`n", " ").Replace("`r", " ") } else { "" }
            
            $line = "$($item.FullName)`t$($item.Name)`t$type`t$extension`t$sizeBytes`t$created`t$modified`t$parentPath`t$status`t$errorMsg"
            
            $csvBatch.Add($line)
            
            # Update recent paths list (rolling window)
            $recentPathsList.Add($item.FullName)
            if ($recentPathsList.Count -gt $RecentPathsToKeep) {
                $recentPathsList.RemoveAt(0)
            }
            
            # Flush batch if it reaches size
            if ($csvBatch.Count -ge $BatchSize) {
                Write-CsvBatch
            }
            
            # Update progress file at checkpoints
            if ($script:counter % $CheckpointInterval -eq 0) {
                Update-ProgressFile
            }
        }
        
        # Main scanning loop
        Write-TimestampedHost "Scanning directory structure..." -ForegroundColor Cyan
        Write-TimestampedHost "Starting enumeration (this may take a while for large drives)..." -ForegroundColor DarkGray
        
        $scanStartTime = Get-Date
        $enumerationCount = 0
        $lastEnumUpdate = Get-Date
        $accessErrors = @()
        
        try {
            Get-ChildItem -LiteralPath $DrivePath -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable +accessErrors | 
                ForEach-Object {
                    $enumerationCount++
                    
                    # Show enumeration progress every 5 seconds
                    $now = Get-Date
                    if (($now - $lastEnumUpdate).TotalSeconds -ge 5) {
                        $lastEnumUpdate = $now
                    }
                    
                    # Filter out items inside .gdb folders (but keep the .gdb folder itself)
                    $p = $_.FullName
                    if (-not ($p.Contains('.gdb\') -and -not $p.EndsWith('.gdb'))) {
                        Add-ItemToScan -item $_
                    }
                }
            
            Write-TimestampedHost "Enumeration complete. Total items found: $enumerationCount" -ForegroundColor Green
            
            # Process and log access errors
            if ($accessErrors.Count -gt 0) {
                Write-TimestampedHost "Access denied errors encountered: $($accessErrors.Count)" -ForegroundColor Yellow
                
                foreach ($err in $accessErrors) {
                    $script:errorCounter++
                    
                    # Extract path from error message
                    $errorPath = ""
                    if ($err.Exception.Message -match "Access to the path '(.+?)' is denied") {
                        $errorPath = $matches[1]
                    } elseif ($err.TargetObject) {
                        $errorPath = $err.TargetObject
                    } else {
                        $errorPath = "Unknown path"
                    }
                    
                    # Create a pseudo-item for the inaccessible path
                    $errorLine = "$errorPath`t$(Split-Path $errorPath -Leaf)`tUnknown`t`t`t`t`t$(Split-Path $errorPath -Parent)`tError`tAccess Denied"
                    $csvBatch.Add($errorLine)
                    
                    # Log to console (first 10 only to avoid spam)
                    if ($script:errorCounter -le 10) {
                        Write-TimestampedHost "  Access denied: $errorPath" -ForegroundColor DarkYellow
                    }
                }
                
                if ($script:errorCounter -gt 10) {
                    Write-TimestampedHost "  ... and $($script:errorCounter - 10) more access denied errors (see CSV for full list)" -ForegroundColor DarkYellow
                }
                
                # Flush error entries to CSV
                Write-CsvBatch
            }
            
            $scanSuccessful = $true
            
        } catch {
            Write-TimestampedHost "ERROR during enumeration: $($_.Exception.Message)" -ForegroundColor Red
            Write-TimestampedHost "Exception type: $($_.Exception.GetType().FullName)" -ForegroundColor Yellow
            
            # Save what we have
            Write-CsvBatch
            if ($script:counter -gt 0) {
                Update-ProgressFile
            }
            
            $scanSuccessful = $false
        }
        
        # Flush remaining batches
        Write-CsvBatch
        
        # Final progress update
        if ($script:counter -gt 0) {
            Update-ProgressFile
        }
        
        $scanEndTime = Get-Date
        $scanDuration = $scanEndTime - $scanStartTime
        
        Write-TimestampedHost "" -ForegroundColor White
        Write-TimestampedHost "Scan phase complete. Duration: $($scanDuration.ToString('hh\:mm\:ss'))" -ForegroundColor Green
        
    } catch {
        Write-TimestampedHost "" -ForegroundColor White
        Write-TimestampedHost "ERROR: An error occurred during scanning: $_" -ForegroundColor Red
        Write-TimestampedHost "Stack trace: $($_.ScriptStackTrace)" -ForegroundColor DarkGray
        Write-TimestampedHost "Partial results saved. You can resume by running the script again." -ForegroundColor Yellow
        $scanSuccessful = $false
    } finally {
        if ($streamWriter) { 
            $streamWriter.Close()
            $streamWriter.Dispose()
        }
    }
    
    # Only proceed to post-processing if scan was successful
    if (-not $scanSuccessful) {
        Write-TimestampedHost "Scan failed or incomplete. Skipping post-processing." -ForegroundColor Red
        Write-TimestampedHost "Progress file preserved for resume: $progressFile" -ForegroundColor Yellow
        return @{
            Success = $false
            Error = "Scan incomplete"
            DrivePath = $DrivePath
            DrivePrefix = $DrivePrefix
            ProgressFile = $progressFile
        }
    }
    
    # Check if we actually processed anything
    if ($script:counter -eq 0 -and -not $resumeMode) {
        Write-TimestampedHost "WARNING: No items were processed!" -ForegroundColor Yellow
        Write-TimestampedHost "This could indicate:" -ForegroundColor Cyan
        Write-TimestampedHost "  - Empty directory" -ForegroundColor White
        Write-TimestampedHost "  - Permission issues preventing enumeration" -ForegroundColor White
        Write-TimestampedHost "  - All items filtered out by .gdb logic" -ForegroundColor White
        
        # Clean up empty file
        if (Test-Path $tempCsvFile) {
            $fileSize = (Get-Item $tempCsvFile).Length
            if ($fileSize -lt 200) {  # Just header
                Remove-Item $tempCsvFile -Force
                Write-TimestampedHost "Removed empty CSV file" -ForegroundColor Yellow
            }
        }
        
        return @{
            Success = $false
            Error = "No items processed"
            DrivePath = $DrivePath
            DrivePrefix = $DrivePrefix
        }
    }
    
    # ========================================================================
    # POST-PROCESSING PHASE
    # ========================================================================
    
    Write-TimestampedHost "" -ForegroundColor White
    Write-TimestampedHost "========================================" -ForegroundColor Cyan
    Write-TimestampedHost "POST-PROCESSING PHASE" -ForegroundColor Cyan
    Write-TimestampedHost "========================================" -ForegroundColor Cyan
    
    try {
        # Step 1: Deduplicate
        $dedupedFile = $tempCsvFile -replace '\.csv$', '_deduped.csv'
        Remove-DuplicateRows -InputFile $tempCsvFile -OutputFile $dedupedFile
        
        # Delete original temp file
        Remove-Item $tempCsvFile -Force
        Write-TimestampedHost "Deleted original temp file" -ForegroundColor Yellow
        
        # Step 2: Compress to GZIP
        Compress-ToGzip -InputFile $dedupedFile -OutputFile $finalGzipFile
        
        # Delete deduped file
        Remove-Item $dedupedFile -Force
        Write-TimestampedHost "Deleted deduped temp file" -ForegroundColor Yellow
        
        # Step 3: Display Summary
        Write-TimestampedHost "" -ForegroundColor White
        Write-TimestampedHost "========================================" -ForegroundColor Green
        Write-TimestampedHost "SCAN COMPLETE: $DrivePath" -ForegroundColor Green
        Write-TimestampedHost "========================================" -ForegroundColor Green
        Write-TimestampedHost "Summary:" -ForegroundColor Cyan
        Write-TimestampedHost "  New items processed: $($script:counter)" -ForegroundColor White
        if ($resumeMode) {
            Write-TimestampedHost "  Previously processed: $previousTotal" -ForegroundColor White
            Write-TimestampedHost "  Items skipped (recent): $($script:skippedCounter)" -ForegroundColor White
            Write-TimestampedHost "  Grand total: $($previousTotal + $script:counter)" -ForegroundColor White
        } else {
            Write-TimestampedHost "  Total items: $($script:counter)" -ForegroundColor White
        }
        Write-TimestampedHost "  Files: $($script:fileCounter)" -ForegroundColor White
        Write-TimestampedHost "  Folders: $($script:folderCounter)" -ForegroundColor White
        Write-TimestampedHost "  Geodatabases (.gdb): $($script:gdbCounter)" -ForegroundColor White
        Write-TimestampedHost "  Inaccessible: $($script:errorCounter)" -ForegroundColor White
        Write-TimestampedHost "  Output file: $finalGzipFile" -ForegroundColor White
        Write-TimestampedHost "  Output size: $([math]::Round((Get-Item $finalGzipFile).Length / 1MB, 2)) MB" -ForegroundColor White
        Write-TimestampedHost "  Scan duration: $($scanDuration.ToString('hh\:mm\:ss'))" -ForegroundColor White
        Write-TimestampedHost "" -ForegroundColor White
        
        # Step 4: Cleanup
        # Delete old scan file if it exists
        $oldFile = Get-MostRecentScanFile -Prefix $DrivePrefix -Path $OutputPath
        if ($oldFile -and $oldFile.FullName -ne $finalGzipFile) {
            Write-TimestampedHost "Deleting old scan file: $($oldFile.Name)" -ForegroundColor Yellow
            Remove-Item $oldFile.FullName -Force
            Write-TimestampedHost "Old file deleted" -ForegroundColor Green
        }
        
        # Delete progress file
        if (Test-Path $progressFile) {
            Remove-Item $progressFile -Force
            Write-TimestampedHost "Progress file deleted" -ForegroundColor Green
        }
        
        # Return success result
        return @{
            Success = $true
            DrivePath = $DrivePath
            DrivePrefix = $DrivePrefix
            OutputFile = $finalGzipFile
            ItemsProcessed = $previousTotal + $script:counter
            FilesCount = $script:fileCounter
            FoldersCount = $script:folderCounter
            GDBCount = $script:gdbCounter
            ErrorsCount = $script:errorCounter
            Duration = $scanDuration
        }
        
    } catch {
        Write-TimestampedHost "" -ForegroundColor White
        Write-TimestampedHost "ERROR: Post-processing failed: $_" -ForegroundColor Red
        Write-TimestampedHost "Stack trace: $($_.ScriptStackTrace)" -ForegroundColor DarkGray
        Write-TimestampedHost "Temp files preserved for manual recovery" -ForegroundColor Yellow
        
        return @{
            Success = $false
            Error = "Post-processing failed: $_"
            DrivePath = $DrivePath
            DrivePrefix = $DrivePrefix
        }
    }
}
