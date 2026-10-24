#!/usr/bin/env bash
# =============================================================================
# setup-hosts.sh — map *.sigstore.local to 127.0.0.1 in /etc/hosts and
# (optionally) trust the TLS root CA system-wide.  Needs root:
#   sudo scripts/setup-hosts.sh            # hosts entry only
#   sudo scripts/setup-hosts.sh --trust-ca # also add pki/tls/ca.crt to the OS store
#   sudo scripts/setup-hosts.sh --remove   # undo both
#
# WSL2 note: WSL regenerates /etc/hosts from Windows' hosts file unless
# /etc/wsl.conf has [network] generateHosts=false. Easiest: run
# windows\Setup-Hosts.ps1 on Windows (fixes both sides after `wsl --shutdown`).
# =============================================================================
source "$(dirname "$0")/lib.sh"
[[ $EUID -eq 0 ]] || die "run with sudo"
MARK="# sigstore-offline"
LINE="127.0.0.1 ${ALL_HOSTS} ${MARK}"

sed -i "/${MARK}/d" /etc/hosts
if [[ "${1:-}" != "--remove" ]]; then
  echo "$LINE" >>/etc/hosts
  ok "/etc/hosts: $LINE"
else
  ok "hosts entry removed"
fi

CA_NAME="sigstore-offline-tls-root.crt"
if [[ -d /usr/local/share/ca-certificates ]]; then        # Debian/Ubuntu
  DEST="/usr/local/share/ca-certificates/${CA_NAME}"; UPDATE="update-ca-certificates"
elif [[ -d /etc/pki/ca-trust/source/anchors ]]; then      # RHEL/Fedora
  DEST="/etc/pki/ca-trust/source/anchors/${CA_NAME}"; UPDATE="update-ca-trust"
fi
case "${1:-}" in
  --trust-ca) cp "$(tls_ca)" "$DEST" && $UPDATE >/dev/null && ok "TLS root trusted system-wide ($DEST)"
              mkdir -p "/etc/docker/certs.d/${REGISTRY_HOST}" && cp "$(tls_ca)" "/etc/docker/certs.d/${REGISTRY_HOST}/ca.crt" \
                && ok "docker trusts https://${REGISTRY_HOST}" ;;
  --remove)   [[ -n "${DEST:-}" && -f "$DEST" ]] && rm -f "$DEST" && $UPDATE >/dev/null && ok "TLS root removed"
              rm -rf "/etc/docker/certs.d/${REGISTRY_HOST}" ;;
esac
