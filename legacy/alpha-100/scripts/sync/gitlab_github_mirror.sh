#!/usr/bin/env bash
set -euo pipefail

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

retry() {
  local attempts="$1"; shift
  local n=1
  until "$@"; do
    if [ "$n" -ge "$attempts" ]; then return 1; fi
    n=$((n + 1)); sleep $((2 * n))
  done
}

trim() {
  local s="$1"
  s="${s#${s%%[![:space:]]*}}"
  s="${s%${s##*[![:space:]]}}"
  printf '%s' "$s"
}

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

: "${GITLAB_URL:?Set GITLAB_URL}"
: "${GITLAB_GROUP:?Set GITLAB_GROUP}"
: "${GITLAB_TOKEN:?Set GITLAB_TOKEN}"
: "${GITHUB_OWNER:?Set GITHUB_OWNER}"

REPO_SOURCE_MODE="${REPO_SOURCE_MODE:-api}"          # api or list
REPO_LIST_FILE="${REPO_LIST_FILE:-}"
GITLAB_CLONE_PROTOCOL="${GITLAB_CLONE_PROTOCOL:-https}"  # https or ssh
GITHUB_PUSH_PROTOCOL="${GITHUB_PUSH_PROTOCOL:-ssh}"      # ssh or https

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_SSH_KEY="${GITHUB_SSH_KEY:-}"
WORKDIR="${WORKDIR:-/tmp/gitlab-github-mirror}"
DRY_RUN="${DRY_RUN:-false}"
REPO_MAP_FILE="${REPO_MAP_FILE:-}"
PROTECTED_BRANCHES="${PROTECTED_BRANCHES:-main master develop}"
BRANCH_CONFLICT_POLICY="${BRANCH_CONFLICT_POLICY:-ff-only}"
UNPROTECTED_FORCE_PUSH="${UNPROTECTED_FORCE_PUSH:-false}"

if [ "$REPO_SOURCE_MODE" != "api" ] && [ "$REPO_SOURCE_MODE" != "list" ]; then
  die "REPO_SOURCE_MODE must be api or list"
fi

if [ "$REPO_SOURCE_MODE" = "list" ]; then
  [ -n "$REPO_LIST_FILE" ] || die "REPO_LIST_FILE required when REPO_SOURCE_MODE=list"
  [ -f "$REPO_LIST_FILE" ] || die "REPO_LIST_FILE not found: $REPO_LIST_FILE"
fi

if [ "$GITHUB_PUSH_PROTOCOL" = "https" ] && [ -z "$GITHUB_TOKEN" ]; then
  die "GITHUB_TOKEN required when GITHUB_PUSH_PROTOCOL=https"
fi

mkdir -p "$WORKDIR"
cd "$WORKDIR"

lockfile="/tmp/gitlab_github_mirror.lock"
exec 9>"$lockfile"
flock -n 9 || die "Another mirror run is already in progress"

gh_api="https://api.github.com"
gl_api="$GITLAB_URL/api/v4"

if [ -n "$GITHUB_SSH_KEY" ]; then
  GITHUB_SSH_KEY="${GITHUB_SSH_KEY/#\~/$HOME}"
  [ -f "$GITHUB_SSH_KEY" ] || die "GITHUB_SSH_KEY not found: $GITHUB_SSH_KEY"
  export GIT_SSH_COMMAND="ssh -i $GITHUB_SSH_KEY -o IdentitiesOnly=yes"
fi

encoded_group="$(printf '%s' "$GITLAB_GROUP" | jq -sRr @uri)"
group_json="$(curl -sS --fail --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$gl_api/groups/$encoded_group")" || die "Cannot access GitLab group '$GITLAB_GROUP'"
group_id="$(printf '%s' "$group_json" | jq -r '.id')"
group_full_path="$(printf '%s' "$group_json" | jq -r '.full_path')"

resolve_target_repo() {
  local source_full_path="$1"
  local source_name="$2"

  if [ -n "$REPO_MAP_FILE" ] && [ -f "$REPO_MAP_FILE" ]; then
    local line
    line="$(awk -F'|' -v key="$source_full_path" '$1==key{print $2; exit}' "$REPO_MAP_FILE" || true)"
    if [ -n "$line" ]; then
      printf '%s' "$line"
      return
    fi
  fi

  printf '%s/%s' "$GITHUB_OWNER" "$source_name"
}

ensure_github_repo() {
  local owner_repo="$1"

  if curl -sS --fail -H "Authorization: Bearer $GITHUB_TOKEN" "$gh_api/repos/$owner_repo" >/dev/null 2>&1; then
    return 0
  fi

  local repo_name
  repo_name="${owner_repo##*/}"
  log "Creating GitHub repo: $owner_repo"
  [ "$DRY_RUN" = "true" ] && return 0

  retry 3 curl -sS --fail -X POST \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "$gh_api/user/repos" \
    --data "{\"name\":\"$repo_name\",\"private\":true}" >/dev/null
}

fetch_gitlab_repos_api() {
  local page=1
  while :; do
    local url="$gl_api/groups/$group_id/projects?include_subgroups=true&per_page=100&page=$page"
    local resp
    resp="$(curl -sS --fail --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$url")" || return 1

    local count
    count="$(printf '%s' "$resp" | jq 'length')"
    [ "$count" -eq 0 ] && break

    printf '%s\n' "$resp" | jq -c '.[]'
    page=$((page + 1))
  done
}

fetch_gitlab_repos_list() {
  while IFS= read -r raw || [ -n "$raw" ]; do
    local line
    line="$(trim "$raw")"
    [ -n "$line" ] || continue
    case "$line" in \#*) continue ;; esac

    local full_path="$line"
    local repo_name="${full_path##*/}"

    local http_url="$GITLAB_URL/$full_path.git"
    local ssh_url="git@${GITLAB_URL#https://}:$full_path.git"
    ssh_url="${ssh_url#git@http://}"

    jq -cn --arg name "$repo_name" --arg path "$full_path" --arg http "$http_url" --arg ssh "$ssh_url" '{name:$name,path_with_namespace:$path,http_url_to_repo:$http,ssh_url_to_repo:$ssh,archived:false}'
  done < "$REPO_LIST_FILE"
}

build_gitlab_clone_url() {
  local line="$1"
  if [ "$GITLAB_CLONE_PROTOCOL" = "ssh" ]; then
    printf '%s' "$line" | jq -r '.ssh_url_to_repo'
  else
    local http_url
    http_url="$(printf '%s' "$line" | jq -r '.http_url_to_repo')"
    local scheme="https"
    [[ "$http_url" == http://* ]] && scheme="http"
    local host_path
    host_path="${http_url#https://}"
    host_path="${host_path#http://}"
    printf '%s://oauth2:%s@%s' "$scheme" "$GITLAB_TOKEN" "$host_path"
  fi
}

build_github_push_url() {
  local owner_repo="$1"
  if [ "$GITHUB_PUSH_PROTOCOL" = "ssh" ]; then
    printf 'git@github.com:%s.git' "$owner_repo"
  else
    printf 'https://%s@github.com/%s.git' "$GITHUB_TOKEN" "$owner_repo"
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
  local line="$1"
  local archived repo_name source_full_path clone_url owner_repo push_url mirror_dir

  archived="$(printf '%s' "$line" | jq -r '.archived // false')"
  [ "$archived" = "true" ] && return 0

  repo_name="$(printf '%s' "$line" | jq -r '.name')"
  source_full_path="$(printf '%s' "$line" | jq -r '.path_with_namespace')"
  clone_url="$(build_gitlab_clone_url "$line")"
  owner_repo="$(resolve_target_repo "$source_full_path" "$repo_name")"
  push_url="$(build_github_push_url "$owner_repo")"

  if [ -n "$GITHUB_TOKEN" ]; then
    ensure_github_repo "$owner_repo"
  fi

  mirror_dir="$WORKDIR/$repo_name.git"
  if [ ! -d "$mirror_dir" ]; then
    log "Cloning mirror from GitLab: $source_full_path"
    [ "$DRY_RUN" = "true" ] || retry 3 git clone --mirror "$clone_url" "$mirror_dir"
  else
    log "Updating mirror from GitLab: $source_full_path"
    [ "$DRY_RUN" = "true" ] || retry 3 git -C "$mirror_dir" remote update --prune
  fi

  log "Pushing heads/tags to GitHub: $owner_repo via $GITHUB_PUSH_PROTOCOL"
  if [ "$DRY_RUN" = "true" ]; then
    return 0
  fi

  if [ "$BRANCH_CONFLICT_POLICY" = "ff-only" ]; then
    retry 3 git -C "$mirror_dir" fetch --prune "$push_url" '+refs/heads/*:refs/remotes/destination/*' || true
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
          log "Protected branch conflict (non-FF), skipping push for $owner_repo:$branch"
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

  retry 3 git -C "$mirror_dir" push --prune "$push_url" "${refspecs[@]}"
}

main() {
  local repos
  repos="$(mktemp)"

  if [ "$REPO_SOURCE_MODE" = "list" ]; then
    fetch_gitlab_repos_list >"$repos" || die "Failed to parse REPO_LIST_FILE"
  else
    retry 3 fetch_gitlab_repos_api >"$repos" || die "Failed to fetch GitLab projects"
  fi

  local total
  total="$(wc -l < "$repos" | tr -d ' ')"
  log "Found $total repositories to process"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    mirror_one_repo "$line"
  done < "$repos"

  rm -f "$repos"
  log "Mirror run completed"
}

main "$@"
