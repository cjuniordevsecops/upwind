<#
.SYNOPSIS
  Validates prerequisites for a fresh install of the Upwind Sensor
  (https://get.upwind.io/sensor.ps1, v0.7.0, 'install' subcommand).
.DESCRIPTION
  Read-only. Installs nothing, changes no settings and sends no credentials.
  Region is fixed to 'us' (oauth.upwind.io, agent.upwind.io, releases.upwind.io).
  Exit code: 0 = no failures, 1 = one or more FAIL items.
.EXAMPLE
  .\check-sensor.ps1
.EXAMPLE
  [Net.ServicePointManager]::SecurityProtocol = 'Tls12'; irm https://raw.githubusercontent.com/cjuniordevsecops/upwind/refs/heads/main/check-sensor.ps1 | iex
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = $env:UPWIND_CONFIG,
    [int]$MinFreeSpaceMB = 500,
    [int]$TimeoutMs = 5000
)

Write-Host '
 sssss    ccccc      a     n     n   ssssss   eeeeeeee   cccccc 
s     s  c     c    a a    nn    n  s      s  e         c      c
s        c         a   a   n n   n  s         e         c       
 sssss   c        a     a  n  n  n   ssssss   e  eeee   c       
      s  c        a     a  n   n n         s  e         c       
s     s  c     c  a     a  n    nn  s      s  e         c      c
 sssss    ccccc   a     a  n     n   ssssss   eeeeeeee   cccccc 
'

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Check, [ValidateSet('OK','WARN','FAIL','INFO')][string]$Status, [string]$Detail)
    $results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail })
}

# ---------- 1. Administrator rights ----------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Add-Result 'Administrator' OK 'Elevated session'
} else {
    Add-Result 'Administrator' FAIL 'The installer must be run as Administrator'
}

# ---------- 2. CPU architecture ----------
$arch = $env:PROCESSOR_ARCHITECTURE
if ($arch -in 'AMD64','ARM64') {
    Add-Result 'Architecture' OK "$arch"
} elseif ($env:PROCESSOR_ARCHITEW6432 -in 'AMD64','ARM64') {
    # 32-bit PowerShell running on a 64-bit OS
    Add-Result 'Architecture' WARN "32-bit process ($arch) on $($env:PROCESSOR_ARCHITEW6432) OS; run from 64-bit PowerShell"
} else {
    Add-Result 'Architecture' FAIL "Unsupported architecture '$arch' (AMD64/ARM64 only)"
}

# ---------- 3. OS / PowerShell / .NET ----------
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    Add-Result 'Operating system' INFO "$($os.Caption) $($os.Version) build $($os.BuildNumber)"
} catch { Add-Result 'Operating system' WARN "Could not query: $($_.Exception.Message)" }

$psv = $PSVersionTable.PSVersion
if ($psv -ge [version]'5.1') { Add-Result 'PowerShell' OK "$psv ($($PSVersionTable.PSEdition))" }
else { Add-Result 'PowerShell' WARN "$psv - 5.1 or later recommended" }

$ndp = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue
if ($ndp -and $ndp.Release) { Add-Result '.NET Framework 4.x' INFO "Release $($ndp.Release) (version $($ndp.Version))" }
else { Add-Result '.NET Framework 4.x' WARN 'Not found in registry' }

# ---------- 4. Language mode / Add-Type ----------
# The installer compiles C# with Add-Type (P/Invoke into advapi32), which is blocked
# in ConstrainedLanguage mode and may be blocked by AppLocker/WDAC/AV.
$lm = $ExecutionContext.SessionState.LanguageMode
if ($lm -eq 'FullLanguage') { Add-Result 'Language mode' OK $lm }
else { Add-Result 'Language mode' FAIL "$lm - Add-Type (used by the installer) is blocked" }

if ($lm -eq 'FullLanguage') {
    try {
        if (-not ([System.Management.Automation.PSTypeName]'UpwindPrereqAddTypeTest').Type) {
            # Compile-only test: the P/Invoke signature is declared but never called
            Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class UpwindPrereqAddTypeTest {
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredReadW(string target, int type, int flags, out IntPtr cred);
}
'@
        }
        Add-Result 'Add-Type (C# compile)' OK 'Compilation with advapi32 P/Invoke works'
    } catch {
        Add-Result 'Add-Type (C# compile)' FAIL "Failed: $($_.Exception.Message) (check AppLocker/WDAC/antivirus)"
    }
}

# ---------- 5. Execution policy (informational) ----------
$ep = Get-ExecutionPolicy
$epStatus = if ($ep -in 'Restricted','AllSigned') { 'WARN' } else { 'INFO' }
Add-Result 'Execution policy' $epStatus "$ep (effective). Running sensor.ps1 as a file may require -ExecutionPolicy Bypass"

# ---------- 6. Required cmdlets ----------
foreach ($c in 'Invoke-RestMethod','Get-FileHash','Get-WinEvent','Get-Service','Start-Service','Stop-Service') {
    if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { Add-Result "Cmdlet $c" FAIL 'Not available' }
}
Add-Result 'Required cmdlets' INFO 'Checked (failures are listed individually)'

# ---------- 7. Config YAML ----------
if ($ConfigPath) {
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) { Add-Result 'UPWIND_CONFIG' OK $ConfigPath }
    else { Add-Result 'UPWIND_CONFIG' FAIL "File not found: $ConfigPath" }
}

# ---------- 8. Optional variables (format only) ----------
foreach ($v in 'UPWIND_ENABLE_SCANNER','UPWIND_ENABLE_HOST_SCAN','UPWIND_AUTO_UPDATE') {
    $val = [Environment]::GetEnvironmentVariable($v)
    if ($val -and $val -notmatch '^(true|false)$') { Add-Result $v WARN "Value '$val' - expected true/false" }
}
foreach ($v in 'UPWIND_HOST_SCAN_INTERVAL','UPWIND_AUTO_UPDATE_INTERVAL') {
    $val = [Environment]::GetEnvironmentVariable($v)
    if ($val -and $val -notmatch '^\d+$') { Add-Result $v WARN "Value '$val' - expected integer (minutes)" }
}

# ---------- 9. Windows Installer ----------
if (Test-Path "$env:SystemRoot\System32\msiexec.exe") { Add-Result 'msiexec.exe' OK 'Present' }
else { Add-Result 'msiexec.exe' FAIL 'Not found' }

$msi = Get-Service msiserver -ErrorAction SilentlyContinue
if (-not $msi) { Add-Result 'msiserver service' FAIL 'Not found' }
elseif ($msi.StartType -eq 'Disabled') { Add-Result 'msiserver service' FAIL 'Disabled' }
else { Add-Result 'msiserver service' OK "StartType=$($msi.StartType), Status=$($msi.Status)" }

# Another MSI install in progress makes msiexec fail with 1618
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\InProgress') {
    Add-Result 'MSI install in progress' WARN 'Another MSI installation is running (msiexec may fail with 1618)'
}
# Pending reboot indicators
$rebootKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
              'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
if ($rebootKeys | Where-Object { Test-Path $_ }) { Add-Result 'Pending reboot' WARN 'Reboot recommended before installing' }

# ---------- 10. %TEMP% (write access and free space) ----------
# The installer downloads the MSI and writes its logs to %TEMP%
try {
    $probe = Join-Path $env:TEMP ("upwind-prereq-{0}.tmp" -f [guid]::NewGuid())
    Set-Content -LiteralPath $probe -Value 'x' -ErrorAction Stop
    Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
    Add-Result 'TEMP writable' OK $env:TEMP
} catch { Add-Result 'TEMP writable' FAIL "$env:TEMP - $($_.Exception.Message)" }

try {
    $drive = Get-PSDrive -Name ($env:TEMP.Substring(0,1)) -ErrorAction Stop
    $freeMB = [math]::Round($drive.Free / 1MB)
    if ($freeMB -ge $MinFreeSpaceMB) { Add-Result 'Free space (TEMP)' OK "$freeMB MB" }
    else { Add-Result 'Free space (TEMP)' WARN "$freeMB MB (< $MinFreeSpaceMB MB)" }
} catch { Add-Result 'Free space (TEMP)' WARN 'Could not measure' }

# ---------- 11. Existing installation ----------
# Same registry locations the installer uses to find the product code / version
$uninstallKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
$existing = Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'Upwind*' }
if ($existing) {
    $existing | ForEach-Object { Add-Result 'Upwind installed' INFO "$($_.DisplayName) v$($_.DisplayVersion)" }
} else {
    Add-Result 'Upwind installed' INFO 'No previous installation'
}
$svc = Get-Service UpwindSensor -ErrorAction SilentlyContinue
if ($svc) { Add-Result 'UpwindSensor service' INFO "Status=$($svc.Status)" }

# ---------- 12. Network: TLS, proxy, DNS, TCP 443, HTTPS ----------
# SystemDefault (0) lets the OS choose; otherwise Tls12 must be in the enabled set
$sp = [Net.ServicePointManager]::SecurityProtocol
if ($PSVersionTable.PSEdition -ne 'Core' -and [int]$sp -ne 0 -and -not ($sp -band [Net.SecurityProtocolType]::Tls12)) {
    Add-Result 'TLS 1.2 in session' WARN "SecurityProtocol=$sp. Before sensor.ps1 run: [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 'Tls12'"
} else { Add-Result 'TLS 1.2 in session' OK "SecurityProtocol=$sp" }

try {
    $winhttp = (netsh winhttp show proxy) -join ' ' -replace '\s+',' '
    Add-Result 'WinHTTP proxy' INFO $winhttp.Trim()
} catch {}

# Fixed endpoints for the 'us' region
$releasesHost = 'releases.upwind.io'
$hosts = @($releasesHost, 'oauth.upwind.io', 'agent.upwind.io')

# Temporarily enable TLS 1.2 for the tests; original value is restored in finally
$origSp = [Net.ServicePointManager]::SecurityProtocol
try {
    if ($PSVersionTable.PSEdition -ne 'Core' -and [int]$origSp -ne 0) {
        [Net.ServicePointManager]::SecurityProtocol = $origSp -bor [Net.SecurityProtocolType]::Tls12
    }
    foreach ($h in $hosts) {
        # DNS resolution
        try {
            $ips = [System.Net.Dns]::GetHostAddresses($h) | ForEach-Object { $_.IPAddressToString }
            Add-Result "DNS $h" OK ($ips -join ', ')
        } catch { Add-Result "DNS $h" FAIL $_.Exception.Message; continue }

        # Direct TCP 443 (may fail behind a mandatory proxy even when HTTPS works)
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $ar = $tcp.BeginConnect($h, 443, $null, $null)
            if ($ar.AsyncWaitHandle.WaitOne($TimeoutMs) -and $tcp.Connected) { Add-Result "TCP 443 $h" OK 'Connected' }
            else { Add-Result "TCP 443 $h" WARN "No direct connection within ${TimeoutMs}ms (expected if a proxy is mandatory)" }
        } catch { Add-Result "TCP 443 $h" WARN $_.Exception.Message } finally { $tcp.Close() }

        # HTTPS: any HTTP response (including 401/404) proves TLS handshake + routing
        try {
            $r = Invoke-WebRequest -Uri "https://$h/" -UseBasicParsing -TimeoutSec ([math]::Ceiling($TimeoutMs/1000)) -ErrorAction Stop
            Add-Result "HTTPS $h" OK "HTTP $($r.StatusCode)"
        } catch {
            $resp = $_.Exception.Response
            if ($resp) { Add-Result "HTTPS $h" OK "HTTP $([int]$resp.StatusCode) (server responded)" }
            else { Add-Result "HTTPS $h" FAIL $_.Exception.Message }
        }
    }

    # Real download of the stable version pointer used by the installer
    try {
        $u = "https://$releasesHost/upwind-agent/stable-windows.txt"
        $v = (Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop).Content
        if ($v -is [byte[]]) { $v = [Text.Encoding]::UTF8.GetString($v) }
        Add-Result 'Stable version (download)' OK "stable-windows.txt = $($v.Trim())"
    } catch { Add-Result 'Stable version (download)' FAIL $_.Exception.Message }
} finally {
    [Net.ServicePointManager]::SecurityProtocol = $origSp
}

# ---------- Report ----------
$color = @{ OK = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; INFO = 'Gray' }
Write-Host "`nUpwind Sensor - install prerequisites check (region: us)`n"
foreach ($r in $results) {
    Write-Host ("[{0,-4}] {1,-30} {2}" -f $r.Status, $r.Check, $r.Detail) -ForegroundColor $color[$r.Status]
}
$fail = @($results | Where-Object Status -eq 'FAIL').Count
$warn = @($results | Where-Object Status -eq 'WARN').Count
Write-Host "`nSummary: $fail failure(s), $warn warning(s)." -ForegroundColor $(if ($fail) { 'Red' } elseif ($warn) { 'Yellow' } else { 'Green' })

# Exit only when running as a .ps1 file; when run via 'irm | iex' or a scriptblock,
# 'exit' would close the host, so set $LASTEXITCODE and return instead.
$code = if ($fail) { 1 } else { 0 }
if ($MyInvocation.MyCommand.Path) { exit $code }
else { $global:LASTEXITCODE = $code; return }