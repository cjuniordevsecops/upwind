# Upwind Sensor – Prerequisites Check

A read-only Bash script that checks whether a Linux host meets the prerequisites to install the **Upwind Sensor** (US region).

It **does not install anything** and does not change the system. It only reads system information and tests network connectivity.

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

## Disclaimer

This is an unofficial helper script. Always confirm the current requirements and endpoint list with Upwind's official documentation, since they may change.