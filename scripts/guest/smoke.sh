#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
check_ready || fail 'Smoke requires a ready owned cluster; run Apply/Doctor first.'
touch "$ROOT/.local/smoke.log"
chmod 0600 "$ROOT/.local/smoke.log"
trap 'printf "infra: Smoke failed; inspect /opt/infra/.local/smoke.log.\\n" >&2' ERR
(
    kubectl --kubeconfig "$KUBECONFIG" --request-timeout=30s apply -f "$ROOT/examples/smoke/app.yaml"
    kubectl --kubeconfig "$KUBECONFIG" --request-timeout=30s -n infra-smoke rollout status deployment/nginx --timeout=180s
    kubectl --kubeconfig "$KUBECONFIG" --request-timeout=30s -n infra-smoke wait --for=condition=Ready pod -l app=infra-smoke --timeout=60s
    for ((attempt=0; attempt<30; attempt++)); do
        response=$(curl --noproxy '*' --fail --silent --show-error --max-time 3 http://127.0.0.1:18080/ || true)
        if [[ $response == infra-ready ]]; then exit 0; fi
        sleep 2
    done
    exit 4
) >"$ROOT/.local/smoke.log" 2>&1
trap - ERR
printf 'infra-ready\n'
