#!/usr/bin/env bash
# =============================================================================
# 00-check-prereqs.sh — confirm the laptop can run the stack.
# Supported: Linux (x86_64/arm64) or Windows 10/11 + WSL2 (Ubuntu) with Docker
# Desktop "WSL integration" enabled. Run every script from the Linux/WSL shell.
# =============================================================================
source "$(dirname "$0")/lib.sh"
FAIL=0
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else warn "$1 — $3"; FAIL=1; fi; }

log "Host tools"
for c in bash docker curl openssl perl tar sha256sum base64; do
  chk "$c" "command -v $c" "install it (apt-get install $c)"
done
log "Bundled tools (bundle/bin)"
for c in kind kubectl helm crane cosign jq; do
  chk "$c" "command -v $c" "missing — run 01-build-offline-bundle.sh while online"
done

log "Docker"
chk "docker daemon reachable" "docker info" "start Docker / Docker Desktop"
MEM_GB=$(( $(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))
if (( MEM_GB >= 6 )); then ok "docker memory ${MEM_GB} GiB"; else warn "docker memory ${MEM_GB} GiB — give Docker >= 8 GiB (Docker Desktop: Settings > Resources; WSL: .wslconfig memory=8GB)"; FAIL=1; fi
CPUS="$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)"
(( CPUS >= 4 )) && ok "docker CPUs ${CPUS}" || warn "docker CPUs ${CPUS} — 4+ recommended"

log "Ports (127.0.0.1)"
for p in 80 443 5000 6443; do
  if (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
    docker ps --format '{{.Names}} {{.Ports}}' | grep -q "127.0.0.1:${p}->" \
      && ok "port $p used by our containers" \
      || { warn "port $p is busy — stop the process using it (IIS, Skype, another registry...)"; FAIL=1; }
  else
    ok "port $p free"
  fi
done

log "Kernel limits (kind needs more inotify watches than defaults)"
W="$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)"
I="$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)"
(( W >= 524288 )) && ok "inotify watches ${W}" || warn "sudo sysctl fs.inotify.max_user_watches=524288"
(( I >= 512 ))    && ok "inotify instances ${I}" || warn "sudo sysctl fs.inotify.max_user_instances=512"

log "Name resolution (laptop hosts file)"
for hname in ${ALL_HOSTS}; do
  chk "$hname -> 127.0.0.1" "getent hosts $hname | grep -q '127.0.0.1'" "run: sudo scripts/setup-hosts.sh (Windows: windows\\Setup-Hosts.ps1)"
done

echo
[[ $FAIL -eq 0 ]] && ok "All prerequisites satisfied" || warn "Fix the items above, then re-run (hosts entries can be added after 05-deploy-ingress.sh)"
exit 0
