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
    [bool]$StopService,
    [string]$BackupDir
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

  Export-ServiceRegistry -Name $Name -BackupDir $BackupDir
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
$backupDir = Join-Path $BackupRoot "server2022-recommended-$timestamp"

Write-Host "Windows Server 2022 recommended low-memory service changes"
Write-Host "Use case   : crawler + headed Chrome + VPN + RDP"
Write-Host "Apply mode : $Apply"
Write-Host "Stop now   : $StopNow"
Write-Host "Backup dir : $backupDir"
Write-Host ""
Write-Host "This script intentionally does not touch RDP, VPN, QCloud/cloud agents,"
Write-Host "Defender, BFE, mpssvc, RPC, WMI, DNS, DHCP, or core networking services."
Write-Host ""

if ($Apply) {
  New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
}

# Recommended to disable for a low-memory crawler server.
$disableRegular = @(
  "SysMain",
  "DiagTrack",
  "CDPSvc",
  "WSearch",
  "WpnService",
  "TabletInputService",
  "TrkWks",
  "UALSVC"
)

# Recommended to keep available but not always running.
$manualRegular = @(
  "MSDTC",
  "LicenseManager",
  "TimeBrokerSvc",
  "TokenBroker",
  "CertPropSvc",
  "DeviceInstall",
  "Vds"
)

# Per-user services. Their suffix changes between logons, so handle both template and instances.
$disablePerUserFamilies = @(
  "CDPUserSvc",
  "cbdhsvc",
  "WpnUserService"
)

Write-Host "=== Regular services -> Disabled ==="
foreach ($name in $disableRegular) {
  Set-RegularServiceStartup -Name $name -StartupType Disabled -StopService:$StopNow -BackupDir $backupDir
}

Write-Host ""
Write-Host "=== Regular services -> Manual ==="
foreach ($name in $manualRegular) {
  Set-RegularServiceStartup -Name $name -StartupType Manual -StopService:$StopNow -BackupDir $backupDir
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
  "DiagTrack",
  "CDPSvc",
  "WSearch",
  "WpnService",
  "TabletInputService",
  "TrkWks",
  "UALSVC",
  "MSDTC",
  "LicenseManager",
  "TimeBrokerSvc",
  "TokenBroker",
  "CertPropSvc",
  "DeviceInstall",
  "Vds",
  "CDPUserSvc",
  "cbdhsvc",
  "WpnUserService"
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
  Write-Host "Reboot once, then re-check the Result table and memory baseline."
} else {
  Write-Host "Dry-run only. Re-run with -Apply to change startup types."
  Write-Host "Use -Apply -StopNow to also stop currently running target services before reboot."
}
