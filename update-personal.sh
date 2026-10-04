#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Pull upstream Vorssaint main into this personal branch and rebuild the
# Developer app. That app has its own bundle id, so it runs beside the
# official one, which keeps updating on its own.
#
# Local edits that would block the merge are stashed and restored afterward.
# A conflict is left marked in the worktree. Resolve it by keeping the
# personal change and the upstream change together. The merge is the only
# commit this script creates.
set -euo pipefail
cd "$(dirname "$0")"
branch=$(git branch --show-current)
if [[ "$branch" != "personal" ]]; then
    echo "Checkout the personal branch first (current: $branch)." >&2
    exit 1
fi

git fetch upstream

if git merge-base --is-ancestor upstream/main HEAD; then
    echo "personal already contains upstream/main."
    exit 0
fi

restore_stash() {
    if ! git stash pop; then
        echo "Local edits conflict with the new upstream changes. Combine both sides, then drop the stash if it is still listed." >&2
        exit 1
    fi
}

set +e
git merge --no-edit upstream/main
merge_code=$?
set -e

if [[ "$merge_code" -eq 0 ]]; then
    ./build.sh --dev --install
    exit 0
fi

if [[ -f .git/MERGE_HEAD ]]; then
    echo "Merge conflict bringing upstream/main into personal. Combine both sides in the conflicted files." >&2
    exit 1
fi

git stash push -u -m "personal-daily-update" -- . ':!update-personal.sh'
if ! git merge --no-edit upstream/main; then
    echo "Merge conflict bringing upstream/main into personal. Local edits are in the stash. Combine both sides, then restore the stash." >&2
    exit 1
fi
restore_stash
./build.sh --dev --install
