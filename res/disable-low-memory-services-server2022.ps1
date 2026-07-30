param(
  [switch]$Apply,
  [switch]$StopNow,
  [string]$BackupRoot = "$env:SystemDrive\ServiceStartBackup"
)

$ErrorActionPreference = "Stop"

function Assert-Admin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script in an elevated PowerShell session."
  }
}

function Get-ServiceSafe {
  param([string]$Name)
  Get-Service -Name $Name -ErrorAction SilentlyContinue
}

function Export-ServiceRegistry {
  param(
    [string]$Name,
    [string]$BackupDir
  )

  $regPath = "HKLM\SYSTEM\CurrentControlSet\Services\$Name"
  $psPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
  if (Test-Path $psPath) {
    $out = Join-Path $BackupDir "$Name.reg"
    & reg.exe export $regPath $out /y | Out-Null
  }
}

function Set-RegularServiceStartup {
  param(
    [string]$Name,
    [ValidateSet("Disabled", "Manual")]
    [string]$StartupType,
    [bool]$StopService
  )

  $svc = Get-ServiceSafe -Name $Name
  if (-not $svc) {
    Write-Host "[skip] service not found: $Name"
    return
  }

  Write-Host "[plan] $Name -> StartupType=$StartupType"
  if (-not $Apply) {
    return
  }

  Set-Service -Name $Name -StartupType $StartupType
  if ($StopService -and $svc.Status -ne "Stopped") {
    try {
      Stop-Service -Name $Name -Force -ErrorAction Stop
      Write-Host "[done] stopped $Name"
    } catch {
      Write-Warning "Could not stop $Name immediately: $($_.Exception.Message)"
    }
  }
}

function Disable-PerUserServiceFamily {
  param(
    [string]$BaseName,
    [string]$BackupDir,
    [bool]$StopService
  )

  $items = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services" |
    Where-Object { $_.PSChildName -eq $BaseName -or $_.PSChildName -like "$BaseName`_*" }

  if (-not $items) {
    Write-Host "[skip] service family not found: $BaseName"
    return
  }

  foreach ($item in $items) {
    $name = $item.PSChildName
    Write-Host "[plan] $name -> registry Start=4 (Disabled)"

    if ($Apply) {
      Export-ServiceRegistry -Name $name -BackupDir $BackupDir
      Set-ItemProperty -Path $item.PSPath -Name Start -Type DWord -Value 4
    }

    $svc = Get-ServiceSafe -Name $name
    if ($Apply -and $StopService -and $svc -and $svc.Status -ne "Stopped") {
      try {
        Stop-Service -Name $name -Force -ErrorAction Stop
        Write-Host "[done] stopped $name"
      } catch {
        Write-Warning "Could not stop $name immediately: $($_.Exception.Message)"
      }
    }
  }
}

Assert-Admin

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $BackupRoot "service-start-$timestamp"

Write-Host "Low-memory Server 2022 service optimizer"
Write-Host "Apply mode : $Apply"
Write-Host "Stop now   : $StopNow"
Write-Host "Backup dir : $backupDir"
Write-Host ""

if ($Apply) {
  New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
}

# Disabled: low-value on a crawler/RDP server, safe to keep off for most server workloads.
$disableRegular = @(
  "SysMain",
  "CDPSvc",
  "WSearch"
)

# Manual: not needed as always-on services for the crawler use case, but easy for Windows to start if required.
$manualRegular = @(
  "InstallService",
  "MSDTC"
)

# Per-user services. These often cannot be disabled through Set-Service/sc.exe,
# so the script changes the service template and any current instance in the registry.
$disablePerUserFamilies = @(
  "CDPUserSvc",
  "OneSyncSvc",
  "WpnUserService",
  "cbdhsvc"
)

Write-Host "=== Regular services -> Disabled ==="
foreach ($name in $disableRegular) {
  if ($Apply) {
    Export-ServiceRegistry -Name $name -BackupDir $backupDir
  }
  Set-RegularServiceStartup -Name $name -StartupType Disabled -StopService:$StopNow
}

Write-Host ""
Write-Host "=== Regular services -> Manual ==="
foreach ($name in $manualRegular) {
  if ($Apply) {
    Export-ServiceRegistry -Name $name -BackupDir $backupDir
  }
  Set-RegularServiceStartup -Name $name -StartupType Manual -StopService:$StopNow
}

Write-Host ""
Write-Host "=== Per-user service families -> Disabled ==="
foreach ($family in $disablePerUserFamilies) {
  Disable-PerUserServiceFamily -BaseName $family -BackupDir $backupDir -StopService:$StopNow
}

Write-Host ""
Write-Host "=== Result ==="
$namePatterns = @(
  "SysMain",
  "CDPSvc",
  "WSearch",
  "InstallService",
  "MSDTC",
  "CDPUserSvc",
  "OneSyncSvc",
  "WpnUserService",
  "cbdhsvc"
)

Get-Service |
  Where-Object {
    $serviceName = $_.Name
    $namePatterns | Where-Object { $serviceName -eq $_ -or $serviceName -like "$_`_*" }
  } |
  Select-Object Name, Status, StartType |
  Sort-Object Name |
  Format-Table -AutoSize

Write-Host ""
if ($Apply) {
  Write-Host "Applied. Registry backups were written to: $backupDir"
  Write-Host "Reboot once, then re-check the Result table."
} else {
  Write-Host "Dry-run only. Re-run with -Apply to change startup types."
  Write-Host "Use -Apply -StopNow to also stop currently running target services before reboot."
}
