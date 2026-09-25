#!/usr/bin/env bash
# Sourced only by the three root entrypoints; no installations here.
set -euo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
fail() { printf 'infra: %s\n' "$*" >&2; exit 4; }
ROOT=''
OWNER_ID=''
while (($#)); do
    case "$1" in
        --root) (($# >= 2)) || fail 'Missing --root value'; ROOT=$2; shift 2 ;;
        --owner-id) (($# >= 2)) || fail 'Missing --owner-id value'; OWNER_ID=$2; shift 2 ;;
        *) fail 'Expected --root /opt/infra --owner-id UUID' ;;
    esac
done
[[ $EUID == 0 && $ROOT == /opt/infra && -n $OWNER_ID ]] || fail 'Run as root with --root /opt/infra --owner-id UUID'
[[ -x /usr/bin/python3 ]] || fail 'The Ubuntu rootfs must contain python3 to verify ownership before bootstrap.'
/usr/bin/python3 "$ROOT/scripts/guest/guard.py" owner --root "$ROOT" --owner-id "$OWNER_ID" || exit 4
# Owner verification must precede even lock/log creation.
exec 9>/run/infra-guest.lock
flock -n 9 || fail 'Another guest operation holds /run/infra-guest.lock; wait and retry.'
export DOCKER_HOST=unix:///var/run/docker.sock
unset DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH
export KIND_EXPERIMENTAL_PROVIDER=docker
export KUBECONFIG="$ROOT/.local/kubeconfig"
guard() { /usr/bin/python3 "$ROOT/scripts/guest/guard.py" "$1" --root "$ROOT" --owner-id "$OWNER_ID"; }
check_platform() {
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ $ID == ubuntu && $VERSION_ID == 24.04 && $(dpkg --print-architecture) == amd64 ]] || fail 'Requires Ubuntu 24.04 amd64.'
    [[ $(cat /proc/1/comm) == systemd ]] || fail 'systemd is not PID 1. Check this distro boot configuration and explicitly Stop/Start infra; no global WSL restart is performed.'
    [[ $(stat -fc %T /sys/fs/cgroup) == cgroup2fs ]] || fail 'Kubernetes 1.37 requires cgroup v2. Update the WSL kernel/configuration manually; no global settings were changed.'
    local state=''
    for ((attempt=0; attempt<30; attempt++)); do
        state=$(systemctl is-system-running 2>/dev/null || true)
        case "$state" in
            running|degraded) return 0 ;;
            initializing|starting) sleep 2 ;;
            *) fail 'systemd is unavailable; inspect this distro with systemctl. No restart was attempted.' ;;
        esac
    done
    fail 'systemd startup exceeded 60s; inspect failed units and retry after startup settles.'
}
check_ready() {
    check_platform
    [[ -f $ROOT/.local/cluster.json && -f $KUBECONFIG && -x $ROOT/.venv/bin/python ]] || return 3
    systemctl is-active --quiet docker || return 4
    timeout 20s docker info >/dev/null 2>&1 || return 4
    guard preflight >/dev/null || return 4
    guard versions || return 4
    [[ $(stat -c %a "$KUBECONFIG") == 600 ]] || return 4
    kubectl --kubeconfig "$KUBECONFIG" --request-timeout=20s get --raw=/readyz >/dev/null 2>&1 || return 4
    guard nodes || return 4
}
