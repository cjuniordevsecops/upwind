#!/usr/bin/env bash
#
# SYNOPSIS
#   Validates prerequisites for a fresh install of the Upwind Sensor on Linux
#   (https://get.upwind.io/sensor.sh).
#
# DESCRIPTION
#   Read-only. Installs nothing, changes no settings and sends no credentials.
#   Checks kernel version (>= 4.14), BPF/BTF support in /boot/config-$(uname -r)
#   (same logic as sensor.sh: std, bcc or unsupported) and DNS/TCP 443/HTTPS/TLS
#   reachability of the Upwind endpoints (console, api, auth, get, agent, oauth,
#   releases, registry .upwind.io).
#   Honors HTTPS_PROXY/https_proxy (direct TCP and certificate checks skipped).
#   TIMEOUT (default 5s) sets the per-test network timeout.
#   Exit code: 0 = no failures, 1 = one or more FAIL items.
#
# EXAMPLE
#   ./check-sensor.sh
#
# EXAMPLE
#   TIMEOUT=10 HTTPS_PROXY=http://proxy:3128 ./check-sensor.sh
#
# EXAMPLE
#   curl -fsSL https://raw.githubusercontent.com/cjuniordevsecops/upwind/refs/heads/main/check-sensor.sh | bash
#

echo '
 sssss    ccccc      a     n     n   ssssss   eeeeeeee   cccccc 
s     s  c     c    a a    nn    n  s      s  e         c      c
s        c         a   a   n n   n  s         e         c       
 sssss   c        a     a  n  n  n   ssssss   e  eeee   c       
      s  c        a     a  n   n n         s  e         c       
s     s  c     c  a     a  n    nn  s      s  e         c      c
 sssss    ccccc   a     a  n     n   ssssss   eeeeeeee   cccccc 
'

TIMEOUT=${TIMEOUT:-5}
MIN_MAJOR=4; MIN_MINOR=14
TARGETS=(
  "console.upwind.io|/|Management console (provided list)"
  "api.upwind.io|/|Sensor/API (provided list)"
  "auth.upwind.io|/|OAuth2 (provided list)"
  "get.upwind.io|/sensor.sh|Installation script"
  "agent.upwind.io|/|Agent API (sensor.sh)"
  "oauth.upwind.io|/oauth/token|OAuth token (sensor.sh)"
  "releases.upwind.io|/checksums|Agent packages (sensor.sh)"
  "registry.upwind.io|/v2/|Container registry - used in bcc/container mode (sensor.sh)"
)
FAIL=0
PROXY="${HTTPS_PROXY:-${https_proxy:-}}"

ok()   { printf "  [OK]    %s\n" "$1"; }
bad()  { printf "  [FAIL]  %s\n" "$1"; FAIL=1; }
warn() { printf "  [WARN]  %s\n" "$1"; }
info() { printf "  [INFO]  %s\n" "$1"; }

echo "Host: $(hostname)  |  $(date '+%F %T')"
[ -r /etc/os-release ] && echo "OS: $(. /etc/os-release; echo "$PRETTY_NAME")"
[ -n "$UPWIND_AGENT_INSTALL_TYPE" ] && echo "UPWIND_AGENT_INSTALL_TYPE=$UPWIND_AGENT_INSTALL_TYPE (forced)"
echo

# ================= KERNEL =================
KREL=$(uname -r)
echo "== Kernel ($KREL)"
ver=${KREL%%-*}
major=${ver%%.*}; rest=${ver#*.}; minor=${rest%%.*}
if [ "$major" -gt "$MIN_MAJOR" ] || { [ "$major" -eq "$MIN_MAJOR" ] && [ "$minor" -ge "$MIN_MINOR" ]; }; then
  ok "Version $major.$minor >= $MIN_MAJOR.$MIN_MINOR"
else
  bad "Version $major.$minor < $MIN_MAJOR.$MIN_MINOR - sensor not supported (installer only allows scanner-only mode; confirm support with Upwind)"
fi
echo

# ================= BPF / INSTALL TYPE =================
# same logic as sensor.sh: reads ONLY /boot/config-$(uname -r)
echo "== BPF / expected install type"
KCFG="/boot/config-$KREL"
if [ -r "$KCFG" ]; then
  has_bpf=no; has_btf=no
  grep -qsF "CONFIG_BPF=y" "$KCFG" && has_bpf=yes
  grep -qsF "CONFIG_DEBUG_INFO_BTF=y" "$KCFG" && has_btf=yes
  info "CONFIG_BPF=y: $has_bpf  |  CONFIG_DEBUG_INFO_BTF=y: $has_btf"

  if [ "$has_btf" = yes ]; then
    ok "Expected install type: std (BPF CO-RE / BTF)"
  elif [ "$has_bpf" = yes ]; then
    warn "Expected install type: bcc (no BTF) - containerized sensor + kernel headers"
    if [ -d "/lib/modules/$KREL/build" ] || [ -d "/usr/src/kernels/$KREL" ] || [ -d "/usr/src/linux-headers-$KREL" ]; then
      info "Kernel headers already installed"
    else
      info "Kernel headers missing - installer will try to install them (requires package repository access)"
    fi
    if [ -d /usr/src ]; then info "/usr/src exists"; else info "/usr/src does not exist"; fi
    rt=""
    for c in docker containerd podman; do command -v "$c" >/dev/null 2>&1 && rt="$rt $c"; done
    info "Container runtimes found:${rt:- none}"
  else
    bad "No CONFIG_BPF=y - installer exits with error (except scanner-only)"
  fi
else
  bad "$KCFG not found - sensor.sh reads only this file"
  [ -r /proc/config.gz ] && info "/proc/config.gz exists, but the installer does not use it"
fi
if [ -e /sys/kernel/btf/vmlinux ]; then info "/sys/kernel/btf/vmlinux present"; else info "/sys/kernel/btf/vmlinux missing"; fi
echo

# ================= NETWORK =================
if [ -n "$PROXY" ]; then echo "Proxy: $PROXY"; else echo "Proxy: none"; fi
echo

for t in "${TARGETS[@]}"; do
  IFS='|' read -r host path desc <<< "$t"
  echo "== $host ($desc)"

  # 1. DNS
  ip=$(getent hosts "$host" | awk '{print $1; exit}')
  if [ -n "$ip" ]; then ok "DNS -> $ip"; else bad "DNS does not resolve"; fi

  # 2. Direct TCP 443 (skipped when using a proxy)
  if [ -z "$PROXY" ]; then
    if timeout "$TIMEOUT" bash -c "</dev/tcp/$host/443" 2>/dev/null; then
      ok "TCP 443 open"
    else
      bad "TCP 443 blocked or timed out"
    fi
  else
    info "Direct TCP test skipped (using proxy)"
  fi

  # 3. HTTPS (any HTTP code, including 401/403/404, means the host was reached)
  if command -v curl >/dev/null 2>&1; then
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "https://$host$path" 2>/dev/null)
    rc=$?
    if [ "$rc" -eq 0 ] && [ "$code" != "000" ]; then
      ok "HTTPS responded (HTTP $code)"
    elif [ "$rc" -eq 60 ] || [ "$rc" -eq 35 ]; then
      bad "TLS error (curl rc=$rc) - possible HTTPS inspection or untrusted CA"
    else
      bad "HTTPS failed (curl rc=$rc)"
    fi
  elif command -v wget >/dev/null 2>&1; then
    wget -q --spider --timeout="$TIMEOUT" --tries=1 "https://$host$path" 2>/dev/null
    rc=$?
    case $rc in
      0|8) ok "HTTPS responded (wget rc=$rc)" ;;
      5)   bad "TLS/certificate error (wget rc=5) - possible HTTPS inspection" ;;
      *)   bad "HTTPS failed (wget rc=$rc)" ;;
    esac
  else
    bad "Neither curl nor wget available to test HTTPS"
  fi

  # 4. Certificate issuer (helps detect HTTPS inspection)
  if [ -z "$PROXY" ] && command -v openssl >/dev/null 2>&1; then
    issuer=$(echo | timeout "$TIMEOUT" openssl s_client -connect "$host:443" -servername "$host" 2>/dev/null \
             | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer= *//')
    [ -n "$issuer" ] && info "Certificate issuer: $issuer"
  fi
  echo
done

if [ "$FAIL" -eq 0 ]; then
  echo "RESULT: all prerequisites OK"
else
  echo "RESULT: failures found - check the [FAIL] items"
fi
exit "$FAIL"