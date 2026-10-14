# Bitwarden SSH agent bridge - Windows prerequisites.
# Run via WSL:  bwssh windows   (or)
#               powershell.exe -NoProfile -Command - < assets/windowsSetup.ps1
$ErrorActionPreference = 'Stop'

function Info($m) { Write-Host "[*] $m" }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

Info 'Bitwarden Desktop SSH agent - Windows prerequisites'

# --- 1. Bitwarden Desktop build ---------------------------------------------
$standalone = @(
  @(
    "$env:LOCALAPPDATA\Programs\Bitwarden\Bitwarden.exe",
    "$env:ProgramFiles\Bitwarden\Bitwarden.exe"
  ) | Where-Object { Test-Path $_ }
)

$store = Get-AppxPackage -Name '*Bitwarden*' -ErrorAction SilentlyContinue

if ($standalone.Count -gt 0) {
  Info "Bitwarden Desktop (standalone) found: $($standalone[0])"
} elseif ($store) {
  Warn 'Only the Microsoft Store (Appx) Bitwarden build was found.'
  Warn 'The Store build cannot serve the SSH agent to external clients. Install the standalone build: https://bitwarden.com/download/'
} else {
  Warn 'Bitwarden Desktop not found. Install the standalone build: https://bitwarden.com/download/'
}

# --- 2. npiperelay ----------------------------------------------------------
$np = (Get-Command npiperelay.exe -ErrorAction SilentlyContinue).Source
if (-not $np) {
  $c = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\albertony.npiperelay_*\npiperelay.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { $np = $c.FullName }
}
if (-not $np) {
  $c = "$env:LOCALAPPDATA\npiperelay\npiperelay.exe"
  if (Test-Path $c) { $np = $c }
}

if ($np) {
  Info "npiperelay present: $np"
} else {
  $winget = (Get-Command winget -ErrorAction SilentlyContinue).Source
  if ($winget) {
    Info 'Installing npiperelay via winget...'
    & winget install --id albertony.npiperelay --accept-source-agreements --accept-package-agreements --silent | Out-Host
  } else {
    Info 'winget not found; downloading npiperelay.exe from GitHub...'
    $dest = "$env:LOCALAPPDATA\npiperelay"
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $url = 'https://github.com/albertony/npiperelay/releases/download/v1.12.2/npiperelay_windows_amd64.exe'
    $out = Join-Path $dest 'npiperelay.exe'
    Invoke-WebRequest -Uri $url -OutFile $out
    $expected = 'e6d3475f8eccd34a5b264ae3946fe0b24154c69fb192fd72e1232f38eeafced8'
    $actual = (Get-FileHash $out -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected) { Fail "npiperelay checksum mismatch (got $actual)" }
    Info "Downloaded and verified: $out"
  }
}

# --- 3. Windows OpenSSH Authentication Agent service ------------------------
# Bitwarden needs to own the pipe; the native OpenSSH agent service must be
# disabled. If we're not elevated, ask Windows for elevation (one UAC prompt).
function Disable-OpensshAgent {
  Set-Service -Name ssh-agent -StartupType Disabled -ErrorAction Stop
  Stop-Service -Name ssh-agent -ErrorAction SilentlyContinue
}

$svc = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
if (-not $svc) {
  Info 'Windows OpenSSH Authentication Agent service not installed (nothing to disable).'
} elseif ($svc.StartType -eq 'Disabled') {
  Info 'Windows OpenSSH Authentication Agent service already disabled.'
} else {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if ($isAdmin) {
    Disable-OpensshAgent
    Info 'Disabled the Windows OpenSSH Authentication Agent service.'
  } else {
    Info 'Disabling the Windows OpenSSH agent service (a UAC prompt will appear)…'
    try {
      Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -ArgumentList @(
        '-NoProfile', '-Command',
        'Set-Service -Name ssh-agent -StartupType Disabled; Stop-Service -Name ssh-agent -ErrorAction SilentlyContinue'
      )
      if ((Get-Service -Name ssh-agent).StartType -eq 'Disabled') {
        Info 'Disabled the Windows OpenSSH Authentication Agent service.'
      } else {
        Warn 'Service is still enabled. Re-run from an elevated PowerShell to disable it.'
      }
    } catch {
      Warn 'Elevation declined. Enable SSH agent in Bitwarden only after disabling the OpenSSH agent service (run PowerShell as administrator).'
    }
  }
}

# --- 4. Bitwarden SSH pipe --------------------------------------------------
$pipe = Get-ChildItem -Path '\\.\pipe\' -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -like '*ssh*' } |
  Select-Object -ExpandProperty Name
if ($pipe) {
  Info "SSH pipe(s) present: $($pipe -join ', ')"
} else {
  Warn 'No SSH pipe yet. In Bitwarden Desktop: Settings -> Enable SSH agent (vault must be unlocked).'
}

Info 'Windows prerequisites done.'
