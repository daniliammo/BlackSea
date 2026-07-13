#!/bin/bash
# Linux Kernel update script - skips RC releases

set -e

KERNEL_DIR="linux"
REPO_URL="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"

if [ ! -d "$KERNEL_DIR" ]; then
    echo "Cloning Linux kernel (shallow)..."
    git clone --depth=1 --branch=master "$REPO_URL" "$KERNEL_DIR"
else
    echo "Updating Linux kernel (shallow)..."
    cd "$KERNEL_DIR"
    
    # Get latest stable tag (not RC) from remote
    LATEST_STABLE=$(git ls-remote --tags "$REPO_URL" | grep -o 'refs/tags/v[0-9.]\+' | sed 's|refs/tags/||' | grep -v -E 'rc|rc[0-9]' | sort -V | tail -1)
    
    if [ -z "$LATEST_STABLE" ]; then
        echo "No stable release found, updating master"
        git fetch --depth=1 origin master
        git checkout FETCH_HEAD
    else
        echo "Fetching latest stable: $LATEST_STABLE"
        git fetch --depth=1 origin "tag/$LATEST_STABLE"
        git checkout FETCH_HEAD
    fi
    cd ..
fi

echo "Done! Kernel is in ./$KERNEL_DIR"