#!/usr/bin/env bash
set -euo pipefail

# Usage: ./run_sync_profile.sh /path/to/profile.env
PROFILE_FILE="${1:?profile env file required}"
[ -f "$PROFILE_FILE" ] || { echo "Profile not found: $PROFILE_FILE"; exit 1; }

# shellcheck source=/dev/null
. "$PROFILE_FILE"

: "${SYNC_DIRECTION:?Set SYNC_DIRECTION in profile}"

case "$SYNC_DIRECTION" in
  github_to_gitlab)
    MIRROR_ENV_FILE="$PROFILE_FILE" "$(dirname "$0")/../github_gitlab_mirror.sh"
    ;;
  gitlab_to_github)
    MIRROR_ENV_FILE="$PROFILE_FILE" "$(dirname "$0")/gitlab_github_mirror.sh"
    ;;
  *)
    echo "Unsupported SYNC_DIRECTION: $SYNC_DIRECTION"
    exit 1
    ;;
esac
