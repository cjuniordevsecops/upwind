# Upwind Sensor – Prerequisites Check


It **does not install anything** and does not change the system. It only reads system information and tests network connectivity.


# Linux Sensor

A read-only Bash script that checks whether a Linux host meets the prerequisites to install the **Upwind Sensor** (US region).

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/cjuniordevsecops/upwind/refs/heads/main/check-sensor.sh | bash
```

Behind a proxy:

```bash
export HTTPS_PROXY=http://proxy.example.com:3128
curl -fsSL https://raw.githubusercontent.com/cjuniordevsecops/upwind/refs/heads/main/check-sensor.sh | bash
```

Prefer to review before running:

```bash
curl -fsSLO https://raw.githubusercontent.com/cjuniordevsecops/upwind/refs/heads/main/check-sensor.sh
less check-sensor.sh
bash check-sensor.sh
```

> Note: the host itself must reach `raw.githubusercontent.com` on port 443 to download the script.

## What it checks

### 1. Kernel version
- Requires kernel **4.14 or newer**.
- Below 4.14 the sensor is not supported (the Upwind installer only allows `scanner-only` mode in that case).

### 2. BPF support and expected install type
Mirrors the logic of the official installer (`https://get.upwind.io/sensor.sh`), which reads **only** `/boot/config-$(uname -r)`:

| Kernel config                         | Expected install type | Result |
|---------------------------------------|-----------------------|--------|
| `CONFIG_DEBUG_INFO_BTF=y`             | `std` (BPF CO-RE)     | OK     |
| `CONFIG_BPF=y` only (no BTF)          | `bcc`                 | WARN   |
| Neither                               | installer fails       | FAIL   |

In `bcc` mode the sensor runs containerized and needs kernel headers, so the script also reports:
- whether kernel headers are installed
- whether `/usr/src` exists
- which container runtimes are available (`docker`, `containerd`, `podman`)

It also reports, for information only, whether `/sys/kernel/btf/vmlinux` exists.

### 3. Network connectivity
For each host below the script tests:
1. **DNS** resolution
2. **TCP 443** (skipped when a proxy is set)
3. **HTTPS** request – any HTTP status (including 401/403/404) means the host was reached
4. **Certificate issuer** – helps detect HTTPS/TLS inspection

| Host                 | Purpose                                     |
|----------------------|---------------------------------------------|
| `console.upwind.io`  | Management console                          |
| `api.upwind.io`      | Sensor/API                                  |
| `auth.upwind.io`     | OAuth2 authentication                       |
| `get.upwind.io`      | Installation script                         |
| `agent.upwind.io`    | Agent API (referenced by `sensor.sh`)       |
| `oauth.upwind.io`    | OAuth token (referenced by `sensor.sh`)     |
| `releases.upwind.io` | Agent packages (referenced by `sensor.sh`)  |
| `registry.upwind.io` | Container registry (bcc/container mode)     |

## Output

Each check prints one of:

| Tag      | Meaning                                         |
|----------|-------------------------------------------------|
| `[OK]`   | Check passed                                    |
| `[WARN]` | Not a failure, but changes how the sensor installs |
| `[FAIL]` | Prerequisite not met                            |
| `[INFO]` | Information only                                |

Example (illustrative):

```
== Kernel (5.15.0-122-generic)
  [OK]    Version 5.15 >= 4.14

== BPF / expected install type
  [INFO]  CONFIG_BPF=y: yes  |  CONFIG_DEBUG_INFO_BTF=y: yes
  [OK]    Expected install type: std (BPF CO-RE / BTF)

== api.upwind.io (Sensor/API (provided list))
  [OK]    DNS -> 203.0.113.10
  [OK]    TCP 443 open
  [OK]    HTTPS responded (HTTP 404)
  [INFO]  Certificate issuer: ...

RESULT: all prerequisites OK
```

## Exit codes

| Code | Meaning                         |
|------|---------------------------------|
| `0`  | All prerequisites OK            |
| `1`  | One or more `[FAIL]` items      |

Useful for automation (Ansible, CI pipelines, etc.).

## Troubleshooting

- **TLS error / unexpected certificate issuer** – traffic is likely being inspected by a firewall or proxy. Consider an HTTPS inspection bypass for `*.upwind.io`.
- **DNS does not resolve** – check the host's DNS servers or internal DNS forwarding.
- **TCP 443 blocked** – request a firewall rule for outbound HTTPS to the hosts above, or set `HTTPS_PROXY`.
- **`/boot/config-*` not found** – common in minimal images or when running inside a container. Run the script on the host.

## Requirements

- Bash
- `curl` or `wget`
- `openssl` (optional, for the certificate issuer check)
- `getent`, `timeout` (coreutils)
- No root required


# Windows

## Quick start

`check-sensor.ps1` validates prerequisites for a fresh install of the Upwind Sensor on Windows
(`https://get.upwind.io/sensor.ps1`, v0.7.0, `install` subcommand). Region is fixed to `us`.

Read-only: it installs nothing, changes no settings and sends no credentials.

### Parameters

| Parameter         | Default            | Description                                   |
|-------------------|--------------------|-----------------------------------------------|
| `-ConfigPath`     | `$env:UPWIND_CONFIG` | Path to the config YAML (checked if set)    |
| `-MinFreeSpaceMB` | `500`              | Minimum free space on the `%TEMP%` drive      |
| `-TimeoutMs`      | `5000`             | Network timeout per test                      |

```PS
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'; irm https://raw.githubusercontent.com/cjuniordevsecops/upwind/refs/heads/main/check-sensor.ps1 | iex
```

There is no proxy parameter: HTTPS tests use the system proxy (see Quick start).

```PS
$p = New-Object Net.WebProxy('http://proxy.suaempresa:8080', $true)
$p.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials
[Net.WebRequest]::DefaultWebProxy = $p
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
irm https://raw.githubusercontent.com/cjuniordevsecops/upwind/refs/heads/main/check-sensor.ps1 | iex
```

### What it checks

1. **Administrator** – the installer must run elevated (FAIL otherwise).
2. **Architecture** – AMD64 or ARM64. WARN if running 32-bit PowerShell on a 64-bit OS.
3. **OS / PowerShell / .NET** – OS version (INFO), PowerShell 5.1+ (WARN if older), .NET Framework 4.x release (INFO).
4. **Language mode and Add-Type** – the installer compiles C# with `Add-Type` (P/Invoke into `advapi32`).
   Requires `FullLanguage` mode; a compile-only test detects blocks by AppLocker, WDAC or antivirus.
5. **Execution policy** – WARN if `Restricted` or `AllSigned`.
6. **Required cmdlets** – `Invoke-RestMethod`, `Get-FileHash`, `Get-WinEvent`, `Get-Service`, `Start-Service`, `Stop-Service`.
7. **`UPWIND_CONFIG`** – if set, the file must exist.
8. **Optional variables (format only)** – `UPWIND_ENABLE_SCANNER`, `UPWIND_ENABLE_HOST_SCAN`, `UPWIND_AUTO_UPDATE`
   (true/false) and `UPWIND_HOST_SCAN_INTERVAL`, `UPWIND_AUTO_UPDATE_INTERVAL` (integer, minutes).
9. **Windows Installer** – `msiexec.exe` present, `msiserver` service not disabled, no other MSI install
   in progress (would fail with error 1618), no pending reboot.
10. **`%TEMP%`** – writable, with at least `-MinFreeSpaceMB` free (the installer downloads the MSI and writes logs there).
11. **Existing installation** – Upwind entries in the Uninstall registry and the `UpwindSensor` service (INFO).
12. **Network** – TLS 1.2 enabled in the session, WinHTTP proxy (INFO), then for each host: DNS, TCP 443 and HTTPS.
    Finally, a real download of `https://releases.upwind.io/upwind-agent/stable-windows.txt`.

| Host                 | Purpose                    |
|----------------------|----------------------------|
| `releases.upwind.io` | Agent packages (MSI)       |
| `oauth.upwind.io`    | OAuth token                |
| `agent.upwind.io`    | Agent API                  |

### Notes behind a proxy

- **TCP 443** returns WARN when direct outbound traffic is blocked. This is expected.
- If internal DNS does not resolve external names, the **DNS** test fails and the HTTPS test for that host is skipped.
  The **Stable version (download)** test still runs and is the one that confirms access through the proxy.
- Unlike the Linux script, it does not report the certificate issuer.

# Disclaimer

This is an unofficial helper script. Always confirm the current requirements and endpoint list with Upwind's official documentation, since they may change.