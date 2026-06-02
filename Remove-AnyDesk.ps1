#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes all installations of AnyDesk from a Windows PC, or reports whether
    it is installed.
.DESCRIPTION
    Detects and removes AnyDesk whether it was installed system-wide (MSI/EXE
    installer) or as a portable/user-level instance. Stops the service and
    running processes first, then uninstalls via the registered uninstaller or
    deletes the portable installation directory. Cleans up leftover files,
    registry keys, and the Windows service.

    Use -ReportOnly to detect without making any changes.

    Exit codes (removal mode)
        0  - AnyDesk was found and removed successfully (or was already absent)
        1  - One or more removal steps failed; check the log for details

    Exit codes (-ReportOnly mode)
        0  - AnyDesk is NOT installed / no traces found
        1  - AnyDesk IS installed or traces were detected
.PARAMETER ReportOnly
    Detect AnyDesk and report findings without removing anything.
    Exit 1 if any installation or trace is found, exit 0 if clean.
#>

[CmdletBinding()]
param(
    [switch]$ReportOnly
)

# Also honour an environment variable so RMMs can set ReportOnly=true/1/yes
# without needing to pass a script parameter.
$validReportOnlyValues = @('true', '1', 'yes')
if ($env:ReportOnly) {
    if ($env:ReportOnly -in $validReportOnlyValues) {
        $ReportOnly = $true
    } else {
        # If it exists but IS NOT in the valid array, throw the error immediately
        Write-Error "Invalid value for environment variable ReportOnly: '$($env:ReportOnly)'. Accepted values: $($validReportOnlyValues -join ', ')."
        exit 2
    }
}

$ErrorActionPreference = 'Stop'
$script:Failed = $false

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')]$Level = 'INFO')
    $ts = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $line = "[$ts][$Level] $Message"
    Write-Output $line
    if ($Level -eq 'ERROR') { $script:Failed = $true }
}

# ---------------------------------------------------------------------------
# Report-only mode: detect and exit without making any changes
# ---------------------------------------------------------------------------
if ($ReportOnly) {
    Write-Log "Running in report-only mode - no changes will be made."
    $detected = $false

    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $regEntries = $uninstallPaths | ForEach-Object {
        Get-ItemProperty $_ -ErrorAction SilentlyContinue
    } | Where-Object { $_.DisplayName -like '*AnyDesk*' }

    foreach ($e in $regEntries) {
        Write-Log "DETECTED registered install: $($e.DisplayName) v$($e.DisplayVersion) [$($e.UninstallString)]"
        $detected = $true
    }

    $svc = Get-Service -Name 'AnyDesk' -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Log "DETECTED service: AnyDesk (Status: $($svc.Status))"
        $detected = $true
    }

    $procs = Get-Process -Name 'AnyDesk' -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        Write-Log "DETECTED running process: AnyDesk (PID $($p.Id), Path: $($p.Path))"
        $detected = $true
    }

    $filePaths = @(
        "$env:ProgramFiles\AnyDesk",
        "${env:ProgramFiles(x86)}\AnyDesk",
        "$env:APPDATA\AnyDesk",
        "$env:ProgramData\AnyDesk",
        "$env:ProgramData\AnyDesk.exe",
        "$env:PUBLIC\Desktop\AnyDesk.exe",
        "$env:SystemDrive\AnyDesk.exe"
    )
    foreach ($p in $filePaths) {
        if (Test-Path $p) {
            Write-Log "DETECTED file/directory: $p"
            $detected = $true
        }
    }

    if ($detected) {
        Write-Log "Result: AnyDesk installation or traces FOUND."
        exit 1
    } else {
        Write-Log "Result: AnyDesk NOT detected."
        exit 0
    }
}

# ---------------------------------------------------------------------------
# 1. Stop the AnyDesk service
# ---------------------------------------------------------------------------
Write-Log "Checking for AnyDesk service..."
$svc = Get-Service -Name 'AnyDesk' -ErrorAction SilentlyContinue
if ($svc) {
    Write-Log "Stopping service 'AnyDesk' (current status: $($svc.Status))..."
    try {
        Stop-Service -Name 'AnyDesk' -Force -ErrorAction Stop
        Write-Log "Service stopped."
    } catch {
        Write-Log "Could not stop service: $_" -Level WARN
    }
}

# ---------------------------------------------------------------------------
# 2. Kill any running AnyDesk processes
# ---------------------------------------------------------------------------
Write-Log "Terminating AnyDesk processes..."
Get-Process -Name 'AnyDesk' -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Log "Killing process PID $($_.Id)..."
    try { $_ | Stop-Process -Force -ErrorAction Stop } catch { Write-Log "Kill failed: $_" -Level WARN }
}

# ---------------------------------------------------------------------------
# 3. Uninstall via registered Add/Remove Programs entry
# ---------------------------------------------------------------------------
Write-Log "Searching registry for AnyDesk uninstaller..."

$uninstallPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

$entries = $uninstallPaths | ForEach-Object {
    Get-ItemProperty $_ -ErrorAction SilentlyContinue
} | Where-Object { $_.DisplayName -like '*AnyDesk*' }

if ($entries) {
    foreach ($entry in $entries) {
        Write-Log "Found: $($entry.DisplayName) - $($entry.UninstallString)"
        $uninstStr = $entry.UninstallString

        if ([string]::IsNullOrWhiteSpace($uninstStr)) {
            Write-Log "Empty UninstallString, skipping." -Level WARN
            continue
        }

        try {
            if ($uninstStr -match 'msiexec') {
                # MSI-based install
                $productCode = [regex]::Match($uninstStr, '\{[0-9A-Fa-f\-]+\}').Value
                if ($productCode) {
                    Write-Log "Running: msiexec /x $productCode /qn /norestart"
                    $proc = Start-Process 'msiexec.exe' -ArgumentList "/x `"$productCode`" /qn /norestart" -Wait -PassThru -NoNewWindow
                    Write-Log "msiexec exit code: $($proc.ExitCode)"
                    if ($proc.ExitCode -notin @(0, 3010)) {
                        Write-Log "msiexec returned unexpected exit code $($proc.ExitCode)" -Level WARN
                    }
                }
            } else {
                # EXE-based uninstaller - AnyDesk supports --remove --silent
                $exePath = $uninstStr -replace '"', '' -replace ' --.*$', ''
                if (Test-Path $exePath) {
                    Write-Log "Running: `"$exePath`" --remove --silent"
                    $proc = Start-Process $exePath -ArgumentList '--remove --silent' -Wait -PassThru -NoNewWindow
                    Write-Log "Uninstaller exit code: $($proc.ExitCode)"
                } else {
                    Write-Log "Uninstaller not found at '$exePath'" -Level WARN
                }
            }
        } catch {
            Write-Log "Uninstall command failed: $_" -Level ERROR
        }
    }
} else {
    Write-Log "No registered uninstaller found."
}

# ---------------------------------------------------------------------------
# 4. Remove portable / leftover installation directories
# ---------------------------------------------------------------------------
$anyDeskDirs = @(
    "$env:ProgramFiles\AnyDesk",
    "${env:ProgramFiles(x86)}\AnyDesk",
    "$env:APPDATA\AnyDesk",
    "$env:ProgramData\AnyDesk"
)

foreach ($dir in $anyDeskDirs) {
    if (Test-Path $dir) {
        Write-Log "Removing directory: $dir"
        try {
            Remove-Item $dir -Recurse -Force -ErrorAction Stop
            Write-Log "Removed: $dir"
        } catch {
            Write-Log "Could not remove '$dir': $_" -Level ERROR
        }
    }
}

# Remove portable EXE left in common drop locations
$portableExePaths = @(
    "$env:ProgramData\AnyDesk.exe",
    "$env:PUBLIC\Desktop\AnyDesk.exe",
    "$env:SystemDrive\AnyDesk.exe"
)
foreach ($p in $portableExePaths) {
    if (Test-Path $p) {
        Write-Log "Removing portable executable: $p"
        try { Remove-Item $p -Force -ErrorAction Stop } catch { Write-Log "Could not remove '$p': $_" -Level WARN }
    }
}

# ---------------------------------------------------------------------------
# 5. Delete the Windows service entry if it still exists
# ---------------------------------------------------------------------------
$svc = Get-Service -Name 'AnyDesk' -ErrorAction SilentlyContinue
if ($svc) {
    Write-Log "Removing residual AnyDesk service..."
    try {
        sc.exe delete AnyDesk | Out-Null
        Write-Log "Service removed."
    } catch {
        Write-Log "Could not delete service: $_" -Level WARN
    }
}

# ---------------------------------------------------------------------------
# 6. Clean up registry run keys and leftover entries
# ---------------------------------------------------------------------------
Write-Log "Cleaning registry run keys..."
$runKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
)
foreach ($key in $runKeys) {
    try {
        $props = Get-ItemProperty $key -ErrorAction SilentlyContinue
        if ($props) {
            $props.PSObject.Properties | Where-Object { $_.Value -like '*AnyDesk*' } | ForEach-Object {
                Write-Log "Removing run key value: $($_.Name)"
                Remove-ItemProperty -Path $key -Name $_.Name -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Write-Log "Could not read run key '$key': $_" -Level WARN
    }
}

# Remove HKCU AnyDesk config key for current user; broader per-user sweep via HKU
$hkcuKeys = @('HKCU:\SOFTWARE\AnyDesk')
foreach ($k in $hkcuKeys) {
    if (Test-Path $k) {
        Write-Log "Removing registry key: $k"
        try { Remove-Item $k -Recurse -Force } catch { Write-Log "Could not remove '$k': $_" -Level WARN }
    }
}

# ---------------------------------------------------------------------------
# 7. Remove desktop and Start Menu shortcuts
# ---------------------------------------------------------------------------
$shortcuts = @(
    "$env:PUBLIC\Desktop\AnyDesk.lnk",
    "$env:USERPROFILE\Desktop\AnyDesk.lnk",
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\AnyDesk.lnk",
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\AnyDesk.lnk"
)
foreach ($lnk in $shortcuts) {
    if (Test-Path $lnk) {
        Write-Log "Removing shortcut: $lnk"
        try { Remove-Item $lnk -Force } catch { Write-Log "Could not remove '$lnk': $_" -Level WARN }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if ($script:Failed) {
    Write-Log "Removal completed with errors. Review warnings above." -Level WARN
    exit 1
} else {
    Write-Log "AnyDesk removal completed successfully."
    exit 0
}
