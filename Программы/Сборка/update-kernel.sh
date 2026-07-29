#!/bin/bash
# Linux Kernel update script - shallow only (no commit history), skips RC releases

set -e

KERNEL_DIR="linux"
REPO_URL="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"

# Get latest stable tag (not RC) from remote
echo "Looking up latest stable release..."
LATEST_STABLE=$(git ls-remote --tags --refs "$REPO_URL" \
    | grep -o 'refs/tags/v[0-9.]\+$' \
    | sed 's|refs/tags/||' \
    | grep -v -E 'rc' \
    | sort -V \
    | tail -1)

if [ -z "$LATEST_STABLE" ]; then
    REF="master"
    echo "No stable release found, using master"
else
    REF="$LATEST_STABLE"
    echo "Latest stable: $LATEST_STABLE"
fi

if [ ! -d "$KERNEL_DIR" ]; then
    echo "Cloning Linux kernel (shallow, no history)..."
    git clone --depth=1 --branch="$REF" --single-branch "$REPO_URL" "$KERNEL_DIR"
else
    echo "Updating Linux kernel (shallow, no history)..."
    cd "$KERNEL_DIR"

    # Fetch only the target ref at depth 1 - never grows history
    git fetch --depth=1 origin "$REF"
    git checkout -f FETCH_HEAD

    # Drop any dangling objects from previous states so the repo stays small
    git reflog expire --expire=all --all
    git gc --prune=all --quiet
    cd ..
fi

echo "Done! Kernel ($REF) is in ./$KERNEL_DIR"
