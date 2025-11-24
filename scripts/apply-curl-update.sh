#!/usr/bin/env bash
# Apply curl update from Alpine Linux aports repository
# Usage: ./scripts/apply-curl-update.sh <version> <pkgrel>

set -euo pipefail

GITLAB_API="https://gitlab.alpinelinux.org/api/v4/projects/alpine%2Faports"
TEMPLATE="curl/APKBUILD"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

NEW_VERSION="${1:-}"
NEW_PKGREL="${2:-}"

if [ -z "$NEW_VERSION" ] || [ -z "$NEW_PKGREL" ]; then
    echo "Usage: $0 <version> <pkgrel>"
    echo "Example: $0 8.17.0 1"
    exit 1
fi

main() {
    echo "🚀 Applying curl update to $NEW_VERSION-r$NEW_PKGREL"
    echo ""

    # Check if we're in a clean git state
    if ! git diff --quiet HEAD 2>/dev/null; then
        echo "❌ Working directory has uncommitted changes"
        echo "   Please commit or stash your changes first"
        exit 1
    fi

    # Fetch upstream APKBUILD
    echo "📥 Fetching upstream APKBUILD..."
    local upstream_apkbuild=$(curl -s "$GITLAB_API/repository/files/main%2Fcurl%2FAPKBUILD?ref=master" | jq -r '.content' | base64 -d)

    if [ -z "$upstream_apkbuild" ]; then
        echo "❌ Failed to fetch upstream APKBUILD"
        exit 1
    fi

    # Save upstream to temp file for reference
    echo "$upstream_apkbuild" > /tmp/upstream-curl-APKBUILD
    echo "   Saved to /tmp/upstream-curl-APKBUILD for reference"
    echo ""

    # Create update branch
    local branch_name="curl-update-$NEW_VERSION-r$NEW_PKGREL"
    echo "🌿 Creating branch: $branch_name"
    git checkout -b "$branch_name"
    echo ""

    # Update version fields
    echo "📝 Updating version fields..."
    sed -i "s/^pkgver=.*/pkgver=$NEW_VERSION/" "$TEMPLATE"
    sed -i "s/^pkgrel=.*/pkgrel=$NEW_PKGREL/" "$TEMPLATE"
    echo "   ✓ pkgver=$NEW_VERSION"
    echo "   ✓ pkgrel=$NEW_PKGREL"
    echo ""

    # Sync patches
    echo "📦 Syncing patch files..."
    sync_patches "$upstream_apkbuild"
    echo ""

    # Update source array
    echo "📝 Updating source array..."
    update_source_array "$upstream_apkbuild"
    echo ""

    # Update sha512sums
    echo "🔐 Updating sha512sums..."
    update_checksums "$upstream_apkbuild"
    echo ""

    # Update secfixes if changed
    echo "🔒 Checking secfixes..."
    update_secfixes "$upstream_apkbuild"
    echo ""

    # Run apply-templates.sh
    echo "🔨 Running apply-templates.sh..."
    ./apply-templates.sh > /dev/null
    echo "   ✓ Templates regenerated"
    echo ""

    # Show what changed
    echo "📊 Changes summary:"
    git diff --stat
    echo ""

    # Create commit
    echo "💾 Creating commit..."
    git add .
    git commit -m "Update curl to $NEW_VERSION-r$NEW_PKGREL

- Updated pkgver to $NEW_VERSION
- Updated pkgrel to $NEW_PKGREL
- Synced patches from Alpine aports
- Updated sha512sums
- Regenerated all variant Dockerfiles

Alpine upstream: https://gitlab.alpinelinux.org/alpine/aports/-/tree/master/main/curl

Review checklist:
- [ ] Check depends_dev changes (template conditionals)
- [ ] Check build() function changes (template conditionals)
- [ ] Check checkdepends changes (template conditionals)
- [ ] Review new patches if any
- [ ] Test build for PHP 8.0 (without nghttp2/nghttp3)
- [ ] Test build for PHP 8.3+ (with nghttp2/nghttp3)"

    echo "   ✓ Commit created"
    echo ""

    echo "✅ Update applied successfully!"
    echo ""
    echo "📋 Next steps:"
    echo "   1. Review changes: git show"
    echo "   2. Compare with upstream: diff -u curl/APKBUILD /tmp/upstream-curl-APKBUILD"
    echo "   3. Check template sections manually (depends_dev, build())"
    echo "   4. Test builds if needed"
    echo "   5. Push branch: git push -u origin $branch_name"
    echo "   6. Create PR on GitHub"
}

sync_patches() {
    local upstream="$1"

    # Extract patch filenames from upstream source array
    local upstream_patches=$(echo "$upstream" | awk '/^source="/,/"$/' | grep '\.patch$' | tr -d '\t "' || true)

    if [ -z "$upstream_patches" ]; then
        echo "   ℹ️  No patches in upstream"
        # Remove all local patches
        if ls curl/*.patch > /dev/null 2>&1; then
            echo "   Removing obsolete local patches..."
            rm -f curl/*.patch
        fi
        return
    fi

    # Download new patches
    while IFS= read -r patch; do
        [ -z "$patch" ] && continue
        if [ ! -f "curl/$patch" ]; then
            echo "   📥 Downloading new patch: $patch"
            local encoded_path=$(echo "main/curl/$patch" | jq -sRr @uri)
            curl -s "$GITLAB_API/repository/files/${encoded_path}?ref=master" \
                | jq -r '.content' | base64 -d > "curl/$patch"
        else
            echo "   ✓ Patch exists: $patch"
        fi
    done <<< "$upstream_patches"

    # Remove obsolete patches
    if ls curl/*.patch > /dev/null 2>&1; then
        for patch in curl/*.patch; do
            local basename=$(basename "$patch")
            if ! echo "$upstream_patches" | grep -q "^$basename$"; then
                echo "   🗑️  Removing obsolete patch: $basename"
                rm "$patch"
            fi
        done
    fi
}

update_source_array() {
    local upstream="$1"

    # Extract source array from upstream
    local source_array=$(echo "$upstream" | awk '/^source="/,/"$/')

    # Replace in template (preserving indentation)
    # This is tricky because we need to keep the exact format
    local start_line=$(grep -n '^source=' "$TEMPLATE" | cut -d: -f1)
    local end_line=$(tail -n +$start_line "$TEMPLATE" | grep -n '^"$' | head -1 | cut -d: -f1)
    end_line=$((start_line + end_line - 1))

    # Create temp file with updated source
    head -n $((start_line - 1)) "$TEMPLATE" > /tmp/template-new
    echo "$source_array" >> /tmp/template-new
    tail -n +$((end_line + 1)) "$TEMPLATE" >> /tmp/template-new

    mv /tmp/template-new "$TEMPLATE"
    echo "   ✓ source array updated"
}

update_checksums() {
    local upstream="$1"

    # Extract sha512sums section from upstream
    local checksums=$(echo "$upstream" | awk '/^sha512sums="/,/"$/')

    if [ -z "$checksums" ]; then
        echo "   ⚠️  No sha512sums found in upstream"
        return
    fi

    # Replace in template
    local start_line=$(grep -n '^sha512sums=' "$TEMPLATE" | cut -d: -f1)
    local end_line=$(tail -n +$start_line "$TEMPLATE" | grep -n '^"$' | head -1 | cut -d: -f1)
    end_line=$((start_line + end_line - 1))

    # Create temp file with updated checksums
    head -n $((start_line - 1)) "$TEMPLATE" > /tmp/template-new
    echo "$checksums" >> /tmp/template-new
    tail -n +$((end_line + 1)) "$TEMPLATE" >> /tmp/template-new

    mv /tmp/template-new "$TEMPLATE"
    echo "   ✓ sha512sums updated"
}

update_secfixes() {
    local upstream="$1"

    # Extract newest CVE entry from upstream
    local upstream_secfixes=$(echo "$upstream" | awk '/^# secfixes:/,/^$/' | head -20)
    local upstream_latest_version=$(echo "$upstream_secfixes" | grep '^#   [0-9]' | head -1 | tr -d '# :')

    if [ -z "$upstream_latest_version" ]; then
        echo "   ℹ️  No secfixes changes"
        return
    fi

    # Check if this version already exists in local
    if grep -q "^#   $upstream_latest_version" "$TEMPLATE"; then
        echo "   ℹ️  secfixes already up to date ($upstream_latest_version)"
        return
    fi

    echo "   ⚠️  New security fixes found for $upstream_latest_version"
    echo "   ℹ️  Manual review required - check upstream secfixes section"
}

main "$@"
