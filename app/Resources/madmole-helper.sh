#!/bin/bash
# MadMole helper: lets the app ask the bundled Mole engine its own safety
# questions instead of re-implementing them in Swift.
#
#   madmole-helper.sh <engine-dir> check PATH...
#       One line per path: "ok<TAB>PATH" or "refused<TAB>REASON<TAB>PATH".
#       A path is refused when the user's protected paths
#       (~/.config/mole/whitelist, loaded by load_mole_whitelist) cover it or
#       anything inside it, or when validate_path_for_deletion rejects it.
#   madmole-helper.sh <engine-dir> trash COMMAND PATH...
#       Runs the same check, then moves each accepted path to the Trash through
#       mole_delete (MOLE_DELETE_MODE=trash), inside one operations.log session
#       named COMMAND. One line per path: "ok<TAB>PATH",
#       "refused<TAB>REASON<TAB>PATH" or "failed<TAB>STATUS<TAB>PATH".
#       Nothing is ever deleted permanently.
#   madmole-helper.sh <engine-dir> appfiles BUNDLE NAME APP_PATH [...]
#       For each triple, the user files find_app_files (the uninstall
#       inventory) attributes to that app: "INDEX<TAB>PATH" lines, then
#       "INDEX<TAB>" when that app is done. Read-only.
#   madmole-helper.sh <engine-dir> orphans ID PATH [...]
#       First "installed<TAB>BUNDLE" for every installed bundle id the engine
#       sees (scan_installed_apps), then one "VERDICT<TAB>PATH" per pair:
#       orphan, keep or unknown for a reverse-DNS id (is_bundle_orphaned),
#       name or keep for any other name (should_protect_data and the
#       never-delete patterns). Read-only.

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "usage: madmole-helper.sh <engine-dir> <check|trash|appfiles|orphans> ..." >&2
    exit 64
fi

ENGINE_DIR="$1"
MODE="$2"
shift 2

# shellcheck source=/dev/null
source "$ENGINE_DIR/lib/core/common.sh"

load_mole_whitelist "${HOME:-}" || {
    echo "protected paths could not be read" >&2
    exit 65
}

# True when a protected pattern could match something below PATH: its first
# components match PATH and it continues past it.
helper_contains_whitelisted() {
    local path="${1%/}"
    [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]] || return 1
    local -a path_parts pattern_parts
    IFS='/' read -r -a path_parts <<< "$path"
    local depth=${#path_parts[@]}
    local pattern prefix i
    for pattern in "${WHITELIST_PATTERNS[@]}"; do
        [[ "$pattern" == /* ]] || continue
        IFS='/' read -r -a pattern_parts <<< "${pattern%/}"
        [[ ${#pattern_parts[@]} -gt $depth ]] || continue
        prefix="${pattern_parts[0]}"
        for ((i = 1; i < depth; i++)); do
            prefix+="/${pattern_parts[$i]}"
        done
        # shellcheck disable=SC2053
        if [[ "$path" == "$prefix" || "$path" == $prefix ]]; then
            return 0
        fi
    done
    return 1
}

# Prints the refusal reason and returns 1, or returns 0 for an allowed path.
helper_refusal() {
    local path="$1"
    if [[ "$path" != /* ]]; then
        printf 'not-absolute'
        return 1
    fi
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        printf 'missing'
        return 1
    fi
    if is_path_whitelisted "$path"; then
        printf 'whitelist'
        return 1
    fi
    if helper_contains_whitelisted "$path"; then
        printf 'contains-whitelisted'
        return 1
    fi
    local rc=0
    validate_path_for_deletion "$path" 2> /dev/null || rc=$?
    if [[ $rc -ne 0 ]]; then
        printf '%s' "${_MOLE_VALIDATION_REASON:-protected}"
        return 1
    fi
    return 0
}

helper_check() {
    local path reason
    for path in "$@"; do
        if reason=$(helper_refusal "$path"); then
            printf 'ok\t%s\n' "$path"
        else
            printf 'refused\t%s\t%s\n' "$reason" "$path"
        fi
    done
}

helper_trash() {
    local command="$1"
    shift
    export MOLE_CURRENT_COMMAND="$command"
    export MOLE_DELETE_MODE="trash"
    log_operation_session_start "$command"
    local items=0 total_kb=0 path reason size_kb rc
    for path in "$@"; do
        if ! reason=$(helper_refusal "$path"); then
            log_operation "$command" "SKIPPED" "$path" "$reason"
            printf 'refused\t%s\t%s\n' "$reason" "$path"
            continue
        fi
        size_kb=$(get_path_size_kb "$path" 2> /dev/null || echo 0)
        [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
        rc=0
        mole_delete "$path" 2> /dev/null || rc=$?
        if [[ $rc -eq 0 && ! -e "$path" && ! -L "$path" ]]; then
            items=$((items + 1))
            total_kb=$((total_kb + size_kb))
            printf 'ok\t%s\n' "$path"
        else
            [[ $rc -ne 0 ]] || rc=1
            printf 'failed\t%s\t%s\n' "$rc" "$path"
        fi
    done
    log_operation_session_end "$command" "$items" "$total_kb"
}

helper_appfiles() {
    local index=0 bundle name app_path file
    while [[ $# -ge 3 ]]; do
        bundle="$1"
        name="$2"
        app_path="$3"
        shift 3
        while IFS= read -r file; do
            [[ -n "$file" ]] && printf '%s\t%s\n' "$index" "$file"
        done < <(find_app_files "$bundle" "$name" "$app_path" 2> /dev/null || true)
        printf '%s\t\n' "$index"
        index=$((index + 1))
    done
}

helper_orphans() {
    # shellcheck source=/dev/null
    source "$ENGINE_DIR/lib/clean/apps.sh"
    local installed
    installed=$(create_temp_file) || exit 1
    # Fail closed like mo clean: without a complete installed-app list no
    # folder can be called orphaned.
    if ! scan_installed_apps "$installed" > /dev/null 2>&1; then
        rm -f -- "$installed" # SAFE: exact temp file created above
        echo "installed apps could not be scanned${MOLE_APP_SCAN_FAILURE_DETAIL:+: $MOLE_APP_SCAN_FAILURE_DETAIL}" >&2
        exit 66
    fi
    local bundle
    while IFS= read -r bundle; do
        [[ -n "$bundle" ]] && printf 'installed\t%s\n' "$bundle"
    done < "$installed"

    local id path rc lower pattern never
    while [[ $# -ge 2 ]]; do
        id="$1"
        path="$2"
        shift 2
        if mole_is_reverse_dns_bundle_id "$id"; then
            rc=0
            is_bundle_orphaned "$id" "$path" "$installed" > /dev/null 2>&1 || rc=$?
            case "$rc" in
                0) printf 'orphan\t%s\n' "$path" ;;
                1) printf 'keep\t%s\n' "$path" ;;
                *) printf 'unknown\t%s\n' "$path" ;;
            esac
            continue
        fi
        if should_protect_data "$id"; then
            printf 'keep\t%s\n' "$path"
            continue
        fi
        never=false
        mole_ascii_lowercase lower "$id"
        for pattern in "${ORPHAN_NEVER_DELETE_PATTERNS[@]}"; do
            # shellcheck disable=SC2053
            if [[ "$lower" == $pattern ]]; then
                never=true
                break
            fi
        done
        if [[ "$never" == "true" ]]; then
            printf 'keep\t%s\n' "$path"
        else
            printf 'name\t%s\n' "$path"
        fi
    done
    rm -f -- "$installed" # SAFE: exact temp file created above
}

case "$MODE" in
    check) helper_check "$@" ;;
    trash)
        [[ $# -ge 1 ]] || exit 64
        helper_trash "$@"
        ;;
    appfiles) helper_appfiles "$@" ;;
    orphans) helper_orphans "$@" ;;
    *)
        echo "unknown mode: $MODE" >&2
        exit 64
        ;;
esac
