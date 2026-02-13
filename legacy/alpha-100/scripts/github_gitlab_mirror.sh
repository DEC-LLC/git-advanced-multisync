#!/usr/bin/env bash
set -euo pipefail

# Hardened GitHub -> GitLab mirror script.
# Supports:
# - GitHub clone via SSH or HTTPS (GITHUB_CLONE_PROTOCOL)
# - GitLab push via SSH or HTTPS (GITLAB_PUSH_PROTOCOL)
# - Optional repo list file mode (REPO_SOURCE_MODE=list)

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

retry() {
  local attempts="$1"
  shift
  local n=1
  until "$@"; do
    if [ "$n" -ge "$attempts" ]; then
      return 1
    fi
    n=$((n + 1))
    sleep $((2 * n))
  done
}

trim() {
  local s="$1"
  s="${s#${s%%[![:space:]]*}}"
  s="${s%${s##*[![:space:]]}}"
  printf '%s' "$s"
}

# Optional env file for secrets and settings
if [ -n "${MIRROR_ENV_FILE:-}" ]; then
  [ -f "$MIRROR_ENV_FILE" ] || die "MIRROR_ENV_FILE does not exist: $MIRROR_ENV_FILE"
  # shellcheck source=/dev/null
  . "$MIRROR_ENV_FILE"
fi

need_cmd curl
need_cmd jq
need_cmd git
need_cmd mktemp
need_cmd flock

: "${GITLAB_URL:?Set GITLAB_URL, e.g. https://gitlab.example.com}"
: "${GITLAB_GROUP:?Set GITLAB_GROUP, e.g. team/platform}"
: "${GITLAB_TOKEN:?Set GITLAB_TOKEN}"

REPO_SOURCE_MODE="${REPO_SOURCE_MODE:-api}"          # api or list
REPO_LIST_FILE="${REPO_LIST_FILE:-}"

SOURCE_TYPE="${SOURCE_TYPE:-user}"                  # user or org (api mode)
SOURCE_NAME="${SOURCE_NAME:-}"                      # required when SOURCE_TYPE=org (api mode)

GITHUB_CLONE_PROTOCOL="${GITHUB_CLONE_PROTOCOL:-ssh}"  # ssh or https
GITLAB_PUSH_PROTOCOL="${GITLAB_PUSH_PROTOCOL:-https}"  # ssh or https

WORKDIR="${WORKDIR:-/tmp/github-gitlab-mirror}"
DRY_RUN="${DRY_RUN:-false}"
PROTECTED_BRANCHES="${PROTECTED_BRANCHES:-main master develop}"
BRANCH_CONFLICT_POLICY="${BRANCH_CONFLICT_POLICY:-ff-only}"
UNPROTECTED_FORCE_PUSH="${UNPROTECTED_FORCE_PUSH:-false}"

# Optional SSH behavior overrides
# Example: GITHUB_SSH_KEY=~/.ssh/id_github_mdiwan_diwanconsulting_ed25519
GITHUB_SSH_KEY="${GITHUB_SSH_KEY:-}"
GITLAB_SSH_KEY="${GITLAB_SSH_KEY:-}"

# Optional SSH host/port overrides for GitLab push URL
GITLAB_SSH_HOST="${GITLAB_SSH_HOST:-}"
GITLAB_SSH_PORT="${GITLAB_SSH_PORT:-22}"

if [ "$REPO_SOURCE_MODE" != "api" ] && [ "$REPO_SOURCE_MODE" != "list" ]; then
  die "REPO_SOURCE_MODE must be api or list"
fi

if [ "$GITHUB_CLONE_PROTOCOL" != "ssh" ] && [ "$GITHUB_CLONE_PROTOCOL" != "https" ]; then
  die "GITHUB_CLONE_PROTOCOL must be ssh or https"
fi

if [ "$GITLAB_PUSH_PROTOCOL" != "ssh" ] && [ "$GITLAB_PUSH_PROTOCOL" != "https" ]; then
  die "GITLAB_PUSH_PROTOCOL must be ssh or https"
fi

if [ "$REPO_SOURCE_MODE" = "api" ]; then
  : "${GITHUB_TOKEN:?Set GITHUB_TOKEN for REPO_SOURCE_MODE=api}"
  if [ "$SOURCE_TYPE" = "org" ] && [ -z "$SOURCE_NAME" ]; then
    die "SOURCE_NAME is required when SOURCE_TYPE=org"
  fi
fi

if [ "$REPO_SOURCE_MODE" = "list" ]; then
  [ -n "$REPO_LIST_FILE" ] || die "REPO_LIST_FILE is required when REPO_SOURCE_MODE=list"
  [ -f "$REPO_LIST_FILE" ] || die "REPO_LIST_FILE not found: $REPO_LIST_FILE"
fi

mkdir -p "$WORKDIR"
cd "$WORKDIR"

lockfile="/tmp/github_gitlab_mirror.lock"
exec 9>"$lockfile"
if ! flock -n 9; then
  die "Another mirror run is already in progress"
fi

gh_api="https://api.github.com"
gl_api="$GITLAB_URL/api/v4"

if [ -n "$GITHUB_SSH_KEY" ]; then
  GITHUB_SSH_KEY="${GITHUB_SSH_KEY/#\~/$HOME}"
  [ -f "$GITHUB_SSH_KEY" ] || die "GITHUB_SSH_KEY not found: $GITHUB_SSH_KEY"
  export GIT_SSH_COMMAND="ssh -i $GITHUB_SSH_KEY -o IdentitiesOnly=yes"
fi

# Resolve GitLab group info once
encoded_group="$(printf '%s' "$GITLAB_GROUP" | jq -sRr @uri)"
group_json="$(curl -sS --fail --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$gl_api/groups/$encoded_group")" || die "Cannot access GitLab group '$GITLAB_GROUP'"
group_full_path="$(printf '%s' "$group_json" | jq -r '.full_path')"
group_id="$(printf '%s' "$group_json" | jq -r '.id')"

if [ -z "$GITLAB_SSH_HOST" ]; then
  GITLAB_SSH_HOST="$(printf '%s' "$GITLAB_URL" | sed -E 's#^https?://([^/:]+).*$#\1#')"
fi

log "Mirroring into GitLab group: $group_full_path (id=$group_id)"

fetch_github_repos() {
  local page=1
  local url
  while :; do
    if [ "$SOURCE_TYPE" = "org" ]; then
      url="$gh_api/orgs/$SOURCE_NAME/repos?per_page=100&page=$page&type=all"
    else
      url="$gh_api/user/repos?per_page=100&page=$page&affiliation=owner"
    fi

    local resp
    resp="$(curl -sS --fail -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" "$url")" || return 1

    local count
    count="$(printf '%s' "$resp" | jq 'length')"
    if [ "$count" -eq 0 ]; then
      break
    fi

    printf '%s\n' "$resp" | jq -c '.[]'
    page=$((page + 1))
  done
}

fetch_repos_from_list() {
  # Supported line formats in REPO_LIST_FILE:
  # 1) owner/repo
  # 2) repo_name|git@github.com:owner/repo.git
  # 3) repo_name|https://github.com/owner/repo.git
  # Blank lines and lines starting with # are ignored.
  local raw line
  while IFS= read -r raw || [ -n "$raw" ]; do
    line="$(trim "$raw")"
    [ -n "$line" ] || continue
    case "$line" in
      \#*) continue ;;
    esac

    if [[ "$line" == *"|"* ]]; then
      local repo_name clone_url
      repo_name="$(trim "${line%%|*}")"
      clone_url="$(trim "${line#*|}")"
      [ -n "$repo_name" ] || die "Invalid repo list line (missing repo_name): $line"
      [ -n "$clone_url" ] || die "Invalid repo list line (missing clone_url): $line"
      jq -cn --arg name "$repo_name" --arg clone "$clone_url" '{name:$name,clone_url:$clone,ssh_url:$clone,archived:false,disabled:false}'
      continue
    fi

    # owner/repo short form
    if [[ "$line" =~ ^[^[:space:]]+/[^[:space:]]+$ ]]; then
      local owner_repo repo_name
      owner_repo="$line"
      repo_name="${owner_repo##*/}"
      jq -cn --arg name "$repo_name" \
        --arg clone "https://github.com/$owner_repo.git" \
        --arg ssh "git@github.com:$owner_repo.git" \
        '{name:$name,clone_url:$clone,ssh_url:$ssh,archived:false,disabled:false}'
      continue
    fi

    die "Unsupported line in REPO_LIST_FILE: $line"
  done < "$REPO_LIST_FILE"
}

ensure_gitlab_project() {
  local repo_name="$1"
  local encoded_project
  encoded_project="$(printf '%s/%s' "$group_full_path" "$repo_name" | jq -sRr @uri)"

  if curl -sS --fail --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$gl_api/projects/$encoded_project" >/dev/null 2>&1; then
    return 0
  fi

  log "Creating GitLab project: $repo_name"
  if [ "$DRY_RUN" = "true" ]; then
    return 0
  fi

  retry 3 curl -sS --fail -X POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    --data-urlencode "name=$repo_name" \
    --data "namespace_id=$group_id" \
    --data "visibility=private" \
    "$gl_api/projects" >/dev/null
}

build_gitlab_push_url() {
  local repo_name="$1"
  if [ "$GITLAB_PUSH_PROTOCOL" = "ssh" ]; then
    if [ "$GITLAB_SSH_PORT" = "22" ]; then
      printf 'git@%s:%s/%s.git' "$GITLAB_SSH_HOST" "$group_full_path" "$repo_name"
    else
      printf 'ssh://git@%s:%s/%s/%s.git' "$GITLAB_SSH_HOST" "$GITLAB_SSH_PORT" "$group_full_path" "$repo_name"
    fi
  else
    local gitlab_scheme
    local gitlab_host
    gitlab_scheme="https"
    if [[ "$GITLAB_URL" == http://* ]]; then
      gitlab_scheme="http"
    fi
    gitlab_host="${GITLAB_URL#https://}"
    gitlab_host="${gitlab_host#http://}"
    printf '%s://oauth2:%s@%s/%s/%s.git' "$gitlab_scheme" "$GITLAB_TOKEN" "$gitlab_host" "$group_full_path" "$repo_name"
  fi
}

is_protected_branch() {
  local branch="$1"
  local p
  for p in $PROTECTED_BRANCHES; do
    if [ "$branch" = "$p" ]; then
      return 0
    fi
  done
  return 1
}

mirror_one_repo() {
  local clone_url="$1"
  local repo_name="$2"

  ensure_gitlab_project "$repo_name"

  local mirror_dir="$WORKDIR/$repo_name.git"
  local push_url
  push_url="$(build_gitlab_push_url "$repo_name")"

  if [ ! -d "$mirror_dir" ]; then
    log "Cloning mirror: $repo_name"
    [ "$DRY_RUN" = "true" ] || retry 3 git clone --mirror "$clone_url" "$mirror_dir"
  else
    log "Updating mirror: $repo_name"
    [ "$DRY_RUN" = "true" ] || retry 3 git -C "$mirror_dir" remote update --prune
  fi

  log "Pushing mirror: $repo_name via $GITLAB_PUSH_PROTOCOL"
  if [ "$DRY_RUN" = "true" ]; then
    return 0
  fi

  if [ "$BRANCH_CONFLICT_POLICY" = "ff-only" ]; then
    if [ "$GITLAB_PUSH_PROTOCOL" = "ssh" ] && [ -n "$GITLAB_SSH_KEY" ]; then
      GITLAB_SSH_KEY="${GITLAB_SSH_KEY/#\~/$HOME}"
      [ -f "$GITLAB_SSH_KEY" ] || die "GITLAB_SSH_KEY not found: $GITLAB_SSH_KEY"
      GIT_SSH_COMMAND="ssh -i $GITLAB_SSH_KEY -o IdentitiesOnly=yes" retry 3 git -C "$mirror_dir" fetch --prune "$push_url" '+refs/heads/*:refs/remotes/destination/*' || true
    else
      retry 3 git -C "$mirror_dir" fetch --prune "$push_url" '+refs/heads/*:refs/remotes/destination/*' || true
    fi
  fi

  local -a refspecs
  refspecs=('refs/tags/*:refs/tags/*')

  local branch src_ref dst_ref
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    src_ref="refs/heads/$branch"

    if is_protected_branch "$branch" && [ "$BRANCH_CONFLICT_POLICY" = "ff-only" ]; then
      dst_ref="refs/remotes/destination/$branch"
      if git -C "$mirror_dir" rev-parse -q --verify "$dst_ref" >/dev/null 2>&1; then
        if ! git -C "$mirror_dir" merge-base --is-ancestor "$dst_ref" "$src_ref"; then
          log "Protected branch conflict (non-FF), skipping push for $repo_name:$branch"
          continue
        fi
      fi
      refspecs+=("$src_ref:$src_ref")
    else
      if [ "$UNPROTECTED_FORCE_PUSH" = "true" ]; then
        refspecs+=("+$src_ref:$src_ref")
      else
        refspecs+=("$src_ref:$src_ref")
      fi
    fi
  done < <(git -C "$mirror_dir" for-each-ref --format='%(refname:strip=2)' refs/heads)

  if [ "$GITLAB_PUSH_PROTOCOL" = "ssh" ] && [ -n "$GITLAB_SSH_KEY" ]; then
    GITLAB_SSH_KEY="${GITLAB_SSH_KEY/#\~/$HOME}"
    [ -f "$GITLAB_SSH_KEY" ] || die "GITLAB_SSH_KEY not found: $GITLAB_SSH_KEY"
    GIT_SSH_COMMAND="ssh -i $GITLAB_SSH_KEY -o IdentitiesOnly=yes" retry 3 git -C "$mirror_dir" push --prune "$push_url" "${refspecs[@]}"
  else
    retry 3 git -C "$mirror_dir" push --prune "$push_url" "${refspecs[@]}"
  fi
}

main() {
  local repos
  repos="$(mktemp)"

  if [ "$REPO_SOURCE_MODE" = "list" ]; then
    fetch_repos_from_list >"$repos" || die "Failed to parse REPO_LIST_FILE"
  else
    retry 3 fetch_github_repos >"$repos" || die "Failed to fetch repositories from GitHub API"
  fi

  local total
  total="$(wc -l < "$repos" | tr -d ' ')"
  log "Found $total repositories to process"

  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue

    local archived disabled repo_name clone_url
    archived="$(printf '%s' "$line" | jq -r '.archived // false')"
    disabled="$(printf '%s' "$line" | jq -r '.disabled // false')"
    repo_name="$(printf '%s' "$line" | jq -r '.name')"

    if [ "$GITHUB_CLONE_PROTOCOL" = "ssh" ]; then
      clone_url="$(printf '%s' "$line" | jq -r '.ssh_url // empty')"
      [ -n "$clone_url" ] || clone_url="$(printf '%s' "$line" | jq -r '.clone_url')"
    else
      clone_url="$(printf '%s' "$line" | jq -r '.clone_url')"
    fi

    if [ "$archived" = "true" ] || [ "$disabled" = "true" ]; then
      log "Skipping archived/disabled repo: $repo_name"
      continue
    fi

    mirror_one_repo "$clone_url" "$repo_name"
  done < "$repos"

  rm -f "$repos"
  log "Mirror run completed"
}

main "$@"
