#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
check_platform
install -d -m 0700 "$ROOT/.local" "$ROOT/.local/ansible" "$ROOT/.local/ansible/tmp" "$ROOT/.local/tmp"
export TMPDIR="$ROOT/.local/tmp"
export ANSIBLE_LOCAL_TEMP="$ROOT/.local/ansible/tmp"
export ANSIBLE_REMOTE_TEMP="$ROOT/.local/ansible/tmp"
export ANSIBLE_CONFIG="$ROOT/ansible/ansible.cfg"
export ANSIBLE_NOCOLOR=1
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
printf 'infra: applying; private log: /opt/infra/.local/apply.log\n'
touch "$ROOT/.local/apply.log"
chmod 0600 "$ROOT/.local/apply.log"
trap 'printf "infra: Apply failed; inspect /opt/infra/.local/apply.log. No automatic recreation.\\n" >&2' ERR
(
    # The baseline includes python3; only venv/CA bootstrap uses apt before Ansible.
    if ! dpkg-query -W -f='${Status}\n' python3-venv ca-certificates 2>/dev/null | grep -qv '^install ok installed$' &&
       dpkg-query -W python3-venv ca-certificates >/dev/null 2>&1; then
        :
    else
        apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update
        apt-get -o DPkg::Lock::Timeout=120 -y --no-install-recommends install python3-venv ca-certificates
    fi
    [[ -x $ROOT/.venv/bin/python ]] || python3 -m venv "$ROOT/.venv"
    "$ROOT/.venv/bin/python" -m pip --isolated install --disable-pip-version-check --no-cache-dir \
        --require-hashes --only-binary=:all: --index-url https://pypi.org/simple \
        -r "$ROOT/ansible/requirements.lock"
    cd "$ROOT"
    args=(-i localhost, -c local -e "infra_root=$ROOT" -e "infra_owner=$OWNER_ID" "$ROOT/ansible/site.yaml")
    "$ROOT/.venv/bin/ansible-playbook" "${args[@]}" --syntax-check
    "$ROOT/.venv/bin/ansible-playbook" "${args[@]}"
) >"$ROOT/.local/apply.log" 2>&1
trap - ERR
check_ready || fail 'Convergence ended but readiness failed; inspect the private apply log and run Doctor.'
grep '^localhost[[:space:]]*:' "$ROOT/.local/apply.log" || true
printf 'infra: ready; explicit kubeconfig: /opt/infra/.local/kubeconfig\n'
