<#
.SYNOPSIS
    S Drive Scanner
    
.DESCRIPTION
    Scans the S:\ drive using the Network Drive Scanner Module.
    
.NOTES
    Author: Ryan Benac
    Version: 1.0
    Module Location: C:\Workspace\LOCAL SANDBOX\Network_Drive_Metadata\MODULE_scan_network_drive.ps1
#>

# ============================================================================
# CONFIGURATION
# ============================================================================

# Import the scanner module
$modulePath = "C:\Workspace\LOCAL SANDBOX\Network_Drive_Metadata\MODULE_scan_network_drive.ps1"
. $modulePath

# Configuration
$drivePath = "S:\"
$drivePrefix = "S"
$outputPath = "C:\Workspace\LOCAL SANDBOX\Network_Drive_Metadata"
$rescanThresholdDays = 1

# ============================================================================
# SCAN S DRIVE
# ============================================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "S Drive Scanner" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Configuration:" -ForegroundColor Cyan
Write-Host "  Drive: $drivePath" -ForegroundColor White
Write-Host "  Prefix: $drivePrefix" -ForegroundColor White
Write-Host "  Output Path: $outputPath" -ForegroundColor White
Write-Host "  Rescan Threshold: $rescanThresholdDays days" -ForegroundColor White
Write-Host ""

$startTime = Get-Date

$result = Invoke-NetworkDriveScan `
    -DrivePath $drivePath `
    -DrivePrefix $drivePrefix `
    -OutputPath $outputPath `
    -RescanThresholdDays $rescanThresholdDays

$endTime = Get-Date
$duration = $endTime - $startTime

# ============================================================================
# DISPLAY RESULTS
# ============================================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "SCAN COMPLETE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green

if ($result.Success) {
    if ($result.Skipped) {
        Write-Host "Status: SKIPPED (recent scan exists)" -ForegroundColor Yellow
    } else {
        Write-Host "Status: SUCCESS" -ForegroundColor Green
        Write-Host ""
        Write-Host "Results:" -ForegroundColor Cyan
        Write-Host "  Total Items: $($result.ItemsProcessed)" -ForegroundColor White
        Write-Host "  Files: $($result.FilesCount)" -ForegroundColor White
        Write-Host "  Folders: $($result.FoldersCount)" -ForegroundColor White
        Write-Host "  Geodatabases (.gdb): $($result.GDBCount)" -ForegroundColor White
        Write-Host "  Inaccessible Items: $($result.ErrorsCount)" -ForegroundColor White
        Write-Host ""
        Write-Host "  Output File: $($result.OutputFile)" -ForegroundColor White
        Write-Host "  Scan Duration: $($result.Duration.ToString('hh\:mm\:ss'))" -ForegroundColor White
    }
} else {
    Write-Host "Status: FAILED" -ForegroundColor Red
    Write-Host "Error: $($result.Error)" -ForegroundColor Red
    if ($result.ProgressFile) {
        Write-Host ""
        Write-Host "Progress file saved for resume: $($result.ProgressFile)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Total Execution Time: $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor Cyan
Write-Host ""
pause