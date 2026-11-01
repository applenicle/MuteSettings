#!/usr/bin/env bash
# Read-only: report exact image digest of the RUNNING NL Remnawave panel.
set -Eeuo pipefail
[[ $(id -u) -eq 0 ]] || { echo 'ERROR=NEED_ROOT' >&2; exit 2; }
[[ $(docker inspect -f '{{.State.Running}}' remnawave 2>/dev/null) == true ]] || {
  echo 'ERROR=NL_PANEL_NOT_RUNNING' >&2; exit 2;
}
image_id=$(docker inspect -f '{{.Image}}' remnawave)
repo_digests=$(docker image inspect -f '{{json .RepoDigests}}' "$image_id")
python3 - "$repo_digests" <<'PY'
import json, re, sys
items=json.loads(sys.argv[1]) or []
images=[x for x in items if re.fullmatch(r'remnawave/backend@sha256:[0-9a-f]{64}',x)]
if not images:
    print('ERROR=RUNNING_PANEL_IMAGE_HAS_NO_PINNABLE_REPO_DIGEST',file=sys.stderr)
    sys.exit(2)
print(images[0])
PY
