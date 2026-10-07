#!/bin/bash
set -euo pipefail

# Application source follows upstream. Executable CI configuration belongs to
# the fork and is reviewed separately, never changed by the weekly merge.
if [[ "$#" != 1 ]]; then
    echo 'Usage: sync-upstream.sh UPSTREAM_REF' >&2
    exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
    echo '::error title=Dirty checkout::Commit or stash local changes before syncing upstream.'
    exit 1
fi

before="$(git rev-parse --verify HEAD)"
upstream="$(git rev-parse --verify --end-of-options "$1^{commit}")"
base="$(git merge-base "$before" "$upstream")"

if git merge-base --is-ancestor "$upstream" "$before"; then
    echo 'Upstream is already integrated.'
    exit 0
fi

if ! git diff --quiet "$base" "$upstream" -- .github/workflows; then
    echo '::notice title=Upstream CI changes need review::Keeping the fork workflows unchanged. Review the upstream workflow changes listed below separately.'
    git diff --name-status "$base" "$upstream" -- .github/workflows
fi

if ! git merge --no-ff --no-commit "$upstream"; then
    # Only an actual merge conflict may be inspected/resolved below. Do not
    # continue after unrelated Git errors or a merge that never started.
    git rev-parse --verify MERGE_HEAD >/dev/null
fi

# Restore only this explicitly fork-owned directory, including additions,
# removals and conflicts. Never prefer our version of application source.
git restore --source="$before" --staged --worktree -- .github/workflows

conflicts="$(git diff --name-only --diff-filter=U)"
if [[ -n "$conflicts" ]]; then
    echo '::error title=Upstream source conflict::Resolve the application source conflicts on master, then run the sync again.'
    printf '%s\n' "$conflicts"
    exit 1
fi

git diff --cached --exit-code "$before" -- .github/workflows
git commit --no-edit
