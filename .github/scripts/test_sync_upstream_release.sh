#!/usr/bin/env bash
# Local end-to-end test for .github/scripts/sync_upstream_release.sh using
# throwaway bare repositories and a stubbed gh. Nothing here touches GitHub.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$REPO_ROOT/.github/scripts/sync_upstream_release.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/sync-upstream-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

STATE="$TMP/state"
BIN="$TMP/bin"
mkdir -p "$STATE" "$BIN" "$TMP/upstream-src"
: >"$STATE/releases.log"

# --- stub gh ---------------------------------------------------------------
cat >"$BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  api)
    cat "$STATE/release.json"
    ;;
  release)
    case "${2:-}" in
      view)
        tag=$3
        if grep -qx "$tag" "$STATE/releases.log" 2>/dev/null; then
          echo "release $tag"
          exit 0
        fi
        exit 1
        ;;
      create)
        tag=$3
        printf '%s\n' "$tag" >>"$STATE/releases.log"
        printf 'stub gh release create %s\n' "$*" >&2
        ;;
      *)
        echo "unexpected gh release command: $*" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "unexpected gh command: $*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$BIN/gh"

release_json() {
  local tag=$1
  jq -n --arg tag "$tag" '{
    tag_name: $tag,
    name: ($tag + ": test release"),
    body: ("Upstream notes for " + $tag + "\n\n* a change"),
    prerelease: false
  }' >"$STATE/release.json"
}

# --- fake upstream and fork ------------------------------------------------
git -C "$TMP/upstream-src" init -q -b master
mkdir -p "$TMP/upstream-src/custom_components/gree"
printf '{\n  "domain": "gree",\n  "name": "Gree A/C",\n  "version": "4.0.16",\n  "documentation": "https://github.com/RobHofmann/HomeAssistant-GreeClimateComponent"\n}\n' \
  >"$TMP/upstream-src/custom_components/gree/manifest.json"
printf 'upstream frame 4.0.16\n' >"$TMP/upstream-src/code.txt"
git -C "$TMP/upstream-src" add .
git -C "$TMP/upstream-src" -c user.name=upstream -c user.email=upstream@example.com commit -qm 'Release 4.0.16'
git -C "$TMP/upstream-src" -c user.name=upstream -c user.email=upstream@example.com tag -a 4.0.16 -m 'Release 4.0.16'

git clone -q --bare "$TMP/upstream-src" "$TMP/upstream.git"
git clone -q --bare "$TMP/upstream-src" "$TMP/fork.git"
git clone -q "$TMP/fork.git" "$TMP/work"
git -C "$TMP/work" config user.name test
git -C "$TMP/work" config user.email test@example.com

# Put the automation on fork master, then apply the fork patch.
mkdir -p "$TMP/work/.github/scripts"
cp "$SCRIPT" "$TMP/work/.github/scripts/sync_upstream_release.sh"
chmod +x "$TMP/work/.github/scripts/sync_upstream_release.sh"
git -C "$TMP/work" add .github
git -C "$TMP/work" commit -qm 'Add sync workflow'
printf 'fork patch: quieter polling\n' >"$TMP/work/patch.txt"
jq --indent 2 '.version = "4.0.16.1"' "$TMP/work/custom_components/gree/manifest.json" >"$TMP/m" && mv "$TMP/m" "$TMP/work/custom_components/gree/manifest.json"
git -C "$TMP/work" add .
git -C "$TMP/work" commit -qm 'Quiet polling patch'
git -C "$TMP/work" tag -a 4.0.16.1 -m 'Release 4.0.16.1'
git -C "$TMP/work" push -q origin master refs/tags/4.0.16.1

export PATH="$BIN:$PATH"
export STATE
export GITHUB_REPOSITORY=test/fork
export UPSTREAM_REPOSITORY=test/upstream
export UPSTREAM_GIT_URL="$TMP/upstream.git"
export DRY_RUN=false

cd "$TMP/work"

echo '== current release already published: should be a no-op =='
release_json 4.0.16
printf '4.0.16.1\n' >"$STATE/releases.log"
before=$(git -C "$TMP/fork.git" rev-parse master)
"$SCRIPT" | tee "$TMP/run1.log"
[[ "$(git -C "$TMP/fork.git" rev-parse master)" == "$before" ]]
grep -q 'already exists; nothing to do' "$TMP/run1.log"

echo '== upstream 4.0.17 released: merge, bump, tag, release =='
release_json 4.0.17
: >"$STATE/releases.log"
jq --indent 2 '.version = "4.0.17"' "$TMP/upstream-src/custom_components/gree/manifest.json" >"$TMP/m" && mv "$TMP/m" "$TMP/upstream-src/custom_components/gree/manifest.json"
printf 'upstream frame 4.0.17\n' >"$TMP/upstream-src/code.txt"
git -C "$TMP/upstream-src" add .
git -C "$TMP/upstream-src" -c user.name=upstream -c user.email=upstream@example.com commit -qm 'Release 4.0.17'
git -C "$TMP/upstream-src" -c user.name=upstream -c user.email=upstream@example.com tag -a 4.0.17 -m 'Release 4.0.17'
git -C "$TMP/upstream-src" push -q "$TMP/upstream.git" master refs/tags/4.0.17
"$SCRIPT"
[[ "$(git -C "$TMP/fork.git" rev-parse 'refs/tags/4.0.17.1^{commit}')" == "$(git -C "$TMP/fork.git" rev-parse master)" ]]
grep -qx '4.0.17.1' "$STATE/releases.log"
[[ "$(git -C "$TMP/fork.git" show master:custom_components/gree/manifest.json | jq -r .version)" == '4.0.17.1' ]]
grep -q 'upstream frame 4.0.17' <(git -C "$TMP/fork.git" show master:code.txt)
grep -q 'fork patch: quieter polling' <(git -C "$TMP/fork.git" show master:patch.txt)
# Upstream release metadata and the fork patch commit are both ancestors.
git -C "$TMP/fork.git" cat-file -e "$(git -C "$TMP/work" rev-parse '4.0.17^{commit}')"
git -C "$TMP/fork.git" merge-base --is-ancestor 4.0.16.1 master
# The merge did not touch the manifest version line messily: the release commit
# is exactly the bump from the upstream base.
[[ "$(git -C "$TMP/fork.git" log -1 --format=%s master)" == 'Release 4.0.17.1' ]]

echo '== rerun after release: should be a no-op =='
before=$(git -C "$TMP/fork.git" rev-parse master)
"$SCRIPT" | tee "$TMP/run3.log"
[[ "$(git -C "$TMP/fork.git" rev-parse master)" == "$before" ]]
grep -q 'already exists; nothing to do' "$TMP/run3.log"

echo '== upstream 4.0.18 with a manifest-only release: clean merge again =='
release_json 4.0.18
: >"$STATE/releases.log"
jq --indent 2 '.version = "4.0.18"' "$TMP/upstream-src/custom_components/gree/manifest.json" >"$TMP/m" && mv "$TMP/m" "$TMP/upstream-src/custom_components/gree/manifest.json"
printf 'upstream frame 4.0.18\n' >"$TMP/upstream-src/code.txt"
git -C "$TMP/upstream-src" add .
git -C "$TMP/upstream-src" -c user.name=upstream -c user.email=upstream@example.com commit -qm 'Release 4.0.18'
git -C "$TMP/upstream-src" -c user.name=upstream -c user.email=upstream@example.com tag -a 4.0.18 -m 'Release 4.0.18'
git -C "$TMP/upstream-src" push -q "$TMP/upstream.git" master refs/tags/4.0.18
"$SCRIPT"
[[ "$(git -C "$TMP/fork.git" show master:custom_components/gree/manifest.json | jq -r .version)" == '4.0.18.1' ]]
grep -qx '4.0.18.1' "$STATE/releases.log"
grep -q 'fork patch: quieter polling' <(git -C "$TMP/fork.git" show master:patch.txt)
[[ "$(git -C "$TMP/fork.git" log -1 --format=%s master)" == 'Release 4.0.18.1' ]]

echo '== dry run builds a release commit without pushing =='
release_json 4.0.19
jq --indent 2 '.version = "4.0.19"' "$TMP/upstream-src/custom_components/gree/manifest.json" >"$TMP/m" && mv "$TMP/m" "$TMP/upstream-src/custom_components/gree/manifest.json"
git -C "$TMP/upstream-src" add .
git -C "$TMP/upstream-src" -c user.name=upstream -c user.email=upstream@example.com commit -qm 'Release 4.0.19'
git -C "$TMP/upstream-src" -c user.name=upstream -c user.email=upstream@example.com tag -a 4.0.19 -m 'Release 4.0.19'
git -C "$TMP/upstream-src" push -q "$TMP/upstream.git" master refs/tags/4.0.19
before_master=$(git -C "$TMP/fork.git" rev-parse master)
before_tags=$(git -C "$TMP/fork.git" tag -l '4.0.19*')
DRY_RUN=true "$SCRIPT" | tee "$TMP/run5.log"
[[ "$(git -C "$TMP/fork.git" rev-parse master)" == "$before_master" ]]
[[ "$(git -C "$TMP/fork.git" tag -l '4.0.19*')" == "$before_tags" ]]
grep -q 'Dry run: would push master' "$TMP/run5.log"

echo
echo 'All local sync tests passed.'
