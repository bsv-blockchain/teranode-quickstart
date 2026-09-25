#!/bin/bash
# Make bind-mounted config readable by the non-root monitoring containers.
#
# prometheus (uid 65534), grafana (uid 472) and the Redpanda console
# (redpandaconsole) read host files under config/ through bind mounts, so
# they need the other-read bit (and other-execute on mounted directories).
# git does not record those bits; they come from the umask at clone/pull
# time. A 027/077 umask (CIS, STIG and similar hardening baselines) clears
# them and those containers exit with "permission denied".
#
# Every path listed here becomes world-readable, so none of them may ever
# hold credentials. Keep the list in step with the monitoring mounts in
# compose/docker-services.yml.
#
# Only regular, single-link files and directories owned by the invoking user
# are touched, and symlinks under config/ are never followed (find -P,
# -type f/d, -links 1). This guards against a stray link in a checkout; it is
# not a boundary against someone who can already write to it. Under sudo the
# user's files are left alone and listed instead: fix them as their owner.
#
# Set QUICKSTART_SKIP_CONFIG_PERMS=1 to manage these modes yourself.
# Sourced by setup.sh and start.sh.

fix_config_perms() {
    local root="$1"
    local cfg="${root}/config"
    local candidates=(
        "${cfg}/protos"
        "${cfg}/grafana_dashboards"
        "${cfg}/prometheus.yml"
        "${cfg}/grafana_datasource.yaml"
        "${cfg}/kafka-console-config.yml"
    )

    if [ "${QUICKSTART_SKIP_CONFIG_PERMS:-0}" = "1" ]; then
        return 0
    fi

    local paths=() p
    for p in "${candidates[@]}"; do
        [ -e "$p" ] && paths+=("$p")
    done
    # With no paths GNU find would default to ".".
    [ "${#paths[@]}" -eq 0 ] && return 0

    local uid changed
    uid="$(id -u)"
    # find exits non-zero on any unreadable subdirectory; that must not abort
    # a caller running under set -e -o pipefail. Unreadable paths are reported
    # below instead.
    changed=$( {
        find -P "${paths[@]}" -type d -user "$uid" ! -perm -0005 -exec chmod a+rx {} \; -print
        find -P "${paths[@]}" -type f -links 1 -user "$uid" ! -perm -0004 -exec chmod a+r {} \; -print
    } 2>/dev/null | wc -l | tr -d ' ') || true
    if [ "${changed:-0}" -gt 0 ]; then
        echo_info "Made ${changed} config path(s) readable for the monitoring containers (restrictive umask)."
    fi

    local unreadable
    unreadable=$(find -P "${paths[@]}" \( -type d ! -perm -0005 \) -o \( -type f ! -perm -0004 \) 2>/dev/null) || true
    if [ -n "$unreadable" ]; then
        echo_warning "These are not readable by the prometheus/grafana/kafka-console containers:"
        while IFS= read -r p; do echo "    $p"; done <<< "$unreadable"
        echo_warning "Fix as their owner with chmod a+r (files) / a+rx (directories), or those containers will exit with 'permission denied'."
    fi
}
