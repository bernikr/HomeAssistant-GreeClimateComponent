#!/usr/bin/env bash
# Merge the latest upstream release into master and publish the matching fork
# release. The fork release is the upstream version plus one numeric component
# (4.0.17 -> 4.0.17.1), because the fork keeps a small local patch on master.
#
# Environment:
#   UPSTREAM_REPOSITORY  upstream repo as owner/name
#   UPSTREAM_TAG         optional release tag to sync instead of the latest stable
#   UPSTREAM_GIT_URL     optional clone URL (used by the local tests)
#   DRY_RUN              "true" to build the commits without pushing or releasing
#   GITHUB_REPOSITORY    fork repo as owner/name (set by GitHub Actions)
#   GH_TOKEN             token for the GitHub API and gh release

set -euo pipefail

UPSTREAM_REPOSITORY="${UPSTREAM_REPOSITORY:-RobHofmann/HomeAssistant-GreeClimateComponent}"
UPSTREAM_GIT_URL="${UPSTREAM_GIT_URL:-https://github.com/${UPSTREAM_REPOSITORY}.git}"
REPOSITORY="${GITHUB_REPOSITORY:-}"
MANIFEST="custom_components/gree/manifest.json"
DRY_RUN="${DRY_RUN:-false}"

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ -n "$REPOSITORY" ]] || die "GITHUB_REPOSITORY is not set"

# Fetch the upstream release metadata. /releases/latest only returns published,
# non-prerelease releases, which is what a HACS install should track.
if [[ -n "${UPSTREAM_TAG:-}" ]]; then
  release_json=$(gh api "repos/${UPSTREAM_REPOSITORY}/releases/tags/${UPSTREAM_TAG}")
else
  release_json=$(gh api "repos/${UPSTREAM_REPOSITORY}/releases/latest")
fi

upstream_tag=$(jq -r '.tag_name // empty' <<<"$release_json")
[[ -n "$upstream_tag" ]] || die "could not determine the upstream release tag"
fork_tag="${upstream_tag}.1"

if [[ ! "$upstream_tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  die "unsupported upstream tag '$upstream_tag'"
fi

if gh release view "$fork_tag" --repo "$REPOSITORY" >/dev/null 2>&1; then
  log "Fork release $fork_tag already exists; nothing to do."
  exit 0
fi

log "Latest upstream release: $upstream_tag (fork release: $fork_tag)"

# The upstream tag is the release commit. Fetch it explicitly so this works
# even when the release tag is not on the default branch.
git remote add upstream "$UPSTREAM_GIT_URL" 2>/dev/null || true
git fetch --force --no-tags upstream "+refs/tags/${upstream_tag}:refs/tags/${upstream_tag}"
upstream_commit=$(git rev-parse "refs/tags/${upstream_tag}^{commit}")

git fetch --force origin "refs/tags/${fork_tag}:refs/tags/${fork_tag}" 2>/dev/null || true

set_version() {
  local version=$1 tmp
  tmp=$(mktemp)
  jq --indent 2 --arg v "$version" '.version = $v' "$MANIFEST" >"$tmp"
  mv "$tmp" "$MANIFEST"
}

# Remove the fork's trailing build component (4.0.17.1 -> 4.0.17) before the
# merge. Otherwise master and upstream both change the same manifest line and
# every upstream release conflicts.
base_version() {
  local version=$1
  if [[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?)\.[0-9]+$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "$version"
  fi
}

notes_file=$(mktemp)
upstream_body=$(jq -r '.body // ""' <<<"$release_json")
{
  if [[ -n "$upstream_body" ]]; then
    printf '%s\n\n' "$upstream_body"
  fi
  printf -- '---\n\n'
  printf "**Fork build:** \`%s\` is upstream [\`%s\`](https://github.com/%s/releases/tag/%s) plus this fork's local polling patch on \`master\`.\n" \
    "$fork_tag" "$upstream_tag" "$UPSTREAM_REPOSITORY" "$upstream_tag"
} >"$notes_file"

publish_release() {
  local -a args=(
    release create "$fork_tag"
    --repo "$REPOSITORY"
    --title "$fork_tag"
    --notes-file "$notes_file"
  )
  if [[ "$(jq -r '.prerelease // false' <<<"$release_json")" == "true" ]]; then
    args+=(--prerelease)
  fi
  gh "${args[@]}"
}

# If a previous run pushed the tag but died before creating the release, just
# publish the release for the existing tag.
if git rev-parse -q --verify "refs/tags/${fork_tag}" >/dev/null; then
  log "Tag $fork_tag already exists; publishing its release."
  if [[ "$DRY_RUN" == "true" ]]; then
    log "Dry run: would create the GitHub release for the existing tag."
    exit 0
  fi
  publish_release
  exit 0
fi

current_version=$(jq -r '.version' "$MANIFEST")
base=$(base_version "$current_version")
if [[ "$current_version" != "$base" ]]; then
  log "Resetting manifest version $current_version -> $base for a clean upstream merge."
  set_version "$base"
  git add "$MANIFEST"
  git commit -m "Reset manifest version to upstream base ${base}"
fi

if git merge-base --is-ancestor "$upstream_commit" HEAD; then
  log "Upstream $upstream_tag is already part of master."
else
  log "Merging upstream $upstream_tag into master."
  if ! git merge --no-ff --no-edit -m "Sync upstream release ${upstream_tag}" "$upstream_commit"; then
    git merge --abort 2>/dev/null || true
    die "could not merge upstream $upstream_tag cleanly; resolve the conflict on master and rerun the workflow"
  fi
fi

log "Setting manifest version to $fork_tag."
set_version "$fork_tag"
git add "$MANIFEST"
git commit -m "Release ${fork_tag}"

git tag -a "$fork_tag" -m "Release ${fork_tag} (upstream ${upstream_tag})"

if [[ "$DRY_RUN" == "true" ]]; then
  log "Dry run: would push master and tag $fork_tag, then create the GitHub release."
  log "Dry run: manifest version in the release commit is $(jq -r '.version' "$MANIFEST")."
  exit 0
fi

log "Pushing master and tag $fork_tag."
git push --atomic origin HEAD:master "refs/tags/${fork_tag}"

log "Creating GitHub release $fork_tag."
publish_release
log "Released $fork_tag."
