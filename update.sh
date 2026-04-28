#!/bin/bash
# Check GitHub for a newer Teranode release, bump TERANODE_VERSION in .env.

set -eo pipefail

USAGE=$(cat <<'EOF'
Usage: ./update.sh [flags]

Check GitHub for a newer Teranode release, bump TERANODE_VERSION in .env,
print next steps. (Use ./start.sh afterwards to pull and recreate services.)

Flags:
  --check         Dry-run: show current vs latest, exit without changing .env
  --to <tag>      Pin to a specific tag (downgrade or forward-pin)
  --yes           Non-interactive: accept the prompt
  -h, --help      Show this help and exit
EOF
)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

source "${REPO_ROOT}/lib/colors.sh"
source "${REPO_ROOT}/lib/github_release.sh"

if [ ! -f .env ]; then
    echo_error ".env not found. Run ./setup.sh first."
    exit 1
fi

CHECK=0
AUTO_YES=0
PIN_TAG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --check)   CHECK=1 ;;
        --to)      PIN_TAG="$2"; shift ;;
        --yes)     AUTO_YES=1 ;;
        -h|--help) echo "$USAGE"; exit 0 ;;
        *)         echo_error "Unknown flag: $1"; echo "$USAGE" >&2; exit 2 ;;
    esac
    shift
done

set -a
# shellcheck disable=SC1091
source .env
set +a

CURRENT="${TERANODE_VERSION:-unknown}"
# Strip whitespace / CR (defends against hand-edits, Windows line endings).
CURRENT="${CURRENT//[[:space:]]/}"

if [ -n "$PIN_TAG" ]; then
    TARGET="$PIN_TAG"
    echo_info "Pinning to user-specified tag: $TARGET"
else
    echo_info "Checking github.com/bsv-blockchain/teranode for latest release..."
    TARGET=$(latest_release_tag)
    if [ -z "$TARGET" ]; then
        echo_error "Failed to query GitHub Releases API."
        exit 1
    fi
fi

echo ""
echo_white "Current:  $CURRENT"
echo_white "Target:   $TARGET"
echo_white "Release:  $(release_html_url "$TARGET")"
echo ""

if versions_equal "$CURRENT" "$TARGET"; then
    echo_success "Already on $TARGET. Nothing to do."
    exit 0
fi

if [ "$CHECK" -eq 1 ]; then
    echo_info "--check: not modifying .env or pulling images."
    exit 0
fi

if [ "$AUTO_YES" -ne 1 ]; then
    read -r -p "Apply update? [y/N]: " ans
    [[ "$ans" =~ ^[Yy] ]] || { echo_warning "Aborted."; exit 0; }
fi

"${REPO_ROOT}/lib/env_writer.sh" .env TERANODE_VERSION "$TARGET"
echo_success "Set TERANODE_VERSION=$TARGET in .env (was $CURRENT)"

echo ""
echo_info "Next: ./start.sh"
echo_info "  (docker compose pulls the new image and recreates only the changed services;"
echo_info "   running on top of an existing stack is fine — data volumes persist)"
