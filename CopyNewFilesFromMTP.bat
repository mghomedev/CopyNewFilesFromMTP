@echo off
REM ============================================================================
REM  CopyNewFilesFromMTP - Wrapper for PowerShell script
REM  Usage: CopyNewFilesFromMTP.bat [same parameters as the .ps1 script]
REM
REM  This wrapper runs the PowerShell script with the correct execution policy
REM  so you don't need to configure anything on your system.
REM
REM  Examples:
REM    CopyNewFilesFromMTP.bat -DeviceName "Galaxy S24" -SourcePath "Internal storage\DCIM" -ScanOnly
REM
REM    CopyNewFilesFromMTP.bat -DeviceName "Galaxy S24" -SourcePath "Internal storage\DCIM" -IgnoreFilesInFoldersBySizeAndName "D:\Backup\Phone2024" -TargetFolder "D:\Backup\Phone2025"
REM ============================================================================

powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0CopyNewFilesFromMTP.ps1" %*

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Script exited with error code %ERRORLEVEL%
)

pause
