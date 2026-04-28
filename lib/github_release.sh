#!/bin/bash
# GitHub release helpers for Teranode version tracking.

set -eo pipefail

TERANODE_REPO="bsv-blockchain/teranode"
GH_API="https://api.github.com/repos/${TERANODE_REPO}"

latest_release_tag() {
    curl -sSL -H "Accept: application/vnd.github+json" "${GH_API}/releases/latest" \
        | grep -E '"tag_name"' \
        | head -1 \
        | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
}

release_html_url() {
    local tag="$1"
    echo "https://github.com/${TERANODE_REPO}/releases/tag/${tag}"
}

release_body_summary() {
    local tag="$1"
    curl -sSL -H "Accept: application/vnd.github+json" "${GH_API}/releases/tags/${tag}" \
        | grep -E '"body"' \
        | head -1 \
        | sed -E 's/.*"body"[[:space:]]*:[[:space:]]*"(.*)".*/\1/' \
        | sed 's/\\r\\n/\n/g; s/\\n/\n/g' \
        | head -20
}

versions_equal() {
    [ "$1" = "$2" ]
}

if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    case "$1" in
        latest) latest_release_tag ;;
        url)    release_html_url "$2" ;;
        body)   release_body_summary "$2" ;;
        *) echo "usage: github_release.sh {latest|url <tag>|body <tag>}" >&2; exit 2 ;;
    esac
fi
