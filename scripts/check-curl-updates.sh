#!/usr/bin/env bash
# Check Alpine Linux aports repository for curl package updates
# Usage: ./scripts/check-curl-updates.sh

set -euo pipefail

GITLAB_API="https://gitlab.alpinelinux.org/api/v4/projects/alpine%2Faports"
STATE_FILE=".curl-upstream-state.json"
TEMPLATE="curl/APKBUILD"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

main() {
    echo "🔍 Checking Alpine curl for updates..."
    echo ""

    # Get current state
    local last_commit=""
    local last_version=""
    if [ -f "$STATE_FILE" ]; then
        last_commit=$(jq -r '.last_commit // ""' "$STATE_FILE" 2>/dev/null || echo "")
        last_version=$(jq -r '.last_version // ""' "$STATE_FILE" 2>/dev/null || echo "")
    fi

    # Get local version
    local local_version=$(grep '^pkgver=' "$TEMPLATE" | head -1 | cut -d= -f2)
    local local_pkgrel=$(grep '^pkgrel=' "$TEMPLATE" | head -1 | cut -d= -f2)

    echo "📦 Local version: $local_version-r$local_pkgrel"

    # Get upstream info
    echo "🌐 Fetching upstream info from Alpine GitLab..."
    local commits=$(curl -s "$GITLAB_API/repository/commits?path=main/curl&per_page=10")
    local latest_commit=$(echo "$commits" | jq -r '.[0].id')
    local latest_date=$(echo "$commits" | jq -r '.[0].created_at')

    if [ -z "$latest_commit" ]; then
        echo "❌ Failed to fetch commits from Alpine GitLab"
        exit 1
    fi

    local upstream_apkbuild=$(curl -s "$GITLAB_API/repository/files/main%2Fcurl%2FAPKBUILD?ref=master" | jq -r '.content' | base64 -d)
    local upstream_version=$(echo "$upstream_apkbuild" | grep '^pkgver=' | head -1 | cut -d= -f2)
    local upstream_pkgrel=$(echo "$upstream_apkbuild" | grep '^pkgrel=' | head -1 | cut -d= -f2)

    echo "📦 Upstream version: $upstream_version-r$upstream_pkgrel"
    echo "📅 Last commit: ${latest_date}"
    echo ""

    # Check if already up to date
    if [ "$latest_commit" == "$last_commit" ]; then
        echo "✅ Already up to date (commit: ${latest_commit:0:8})"
        exit 0
    fi

    # Show new commits since last check
    if [ -n "$last_commit" ]; then
        echo "📝 New commits since last check:"
        echo "$commits" | jq -r --arg last "$last_commit" '
            [.[] | select(.id != $last)] |
            .[] | "  - \(.created_at | split("T")[0]) | \(.title) (\(.id[0:8]))"
        '
        echo ""
    else
        echo "📝 Recent commits:"
        echo "$commits" | jq -r '.[:5] | .[] | "  - \(.created_at | split("T")[0]) | \(.title) (\(.id[0:8]))"'
        echo ""
    fi

    # Check version change
    if [ "$upstream_version" != "$local_version" ] || [ "$upstream_pkgrel" != "$local_pkgrel" ]; then
        echo "🆕 UPDATE AVAILABLE: $local_version-r$local_pkgrel -> $upstream_version-r$upstream_pkgrel"
        echo ""

        # Check if patches changed
        local upstream_patches=$(echo "$upstream_apkbuild" | awk '/^source="/,/"$/' | grep '\.patch$' | tr -d '\t "' || true)
        local local_patches=$(ls curl/*.patch 2>/dev/null | xargs -n1 basename || true)

        if [ "$upstream_patches" != "$local_patches" ]; then
            echo "⚠️  Patches have changed:"
            echo ""
            echo "Upstream patches:"
            echo "$upstream_patches" | sed 's/^/  - /'
            echo ""
            echo "Local patches:"
            echo "$local_patches" | sed 's/^/  - /'
            echo ""
        fi

        # Offer to create update branch
        if [ -t 0 ]; then
            # Interactive mode
            read -p "Create update branch? (y/n) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                "$SCRIPT_DIR/apply-curl-update.sh" "$upstream_version" "$upstream_pkgrel"
            fi
        else
            # Non-interactive mode (CI)
            echo "ℹ️  Running in non-interactive mode"
            echo "ℹ️  To apply update, run: ./scripts/apply-curl-update.sh $upstream_version $upstream_pkgrel"
        fi
    else
        echo "ℹ️  Version unchanged ($local_version-r$local_pkgrel)"
        if [ "$latest_commit" != "$last_commit" ]; then
            echo "   New commits exist - review above for backports/fixes"
        fi
    fi
    echo ""

    # Update state
    jq -n \
        --arg commit "$latest_commit" \
        --arg version "$upstream_version" \
        --arg pkgrel "$upstream_pkgrel" \
        '{
            last_commit: $commit,
            last_version: $version,
            last_pkgrel: $pkgrel,
            checked_at: (now | todate)
        }' > "$STATE_FILE"

    echo "✅ State updated in $STATE_FILE"
}

main "$@"