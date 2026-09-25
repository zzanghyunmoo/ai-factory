#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
if check_ready; then
    printf 'ready\n'
else
    status=$?
    if [[ $status == 3 ]]; then printf 'unconfigured\n'; else printf 'unready\n'; status=4; fi
    exit "$status"
fi
