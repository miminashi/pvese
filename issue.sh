#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ISSUES_DIR="${SCRIPT_DIR}/issues"
ISSUES_FILE="${ISSUES_DIR}/issues.yml"
LOCK_FILE="${ISSUES_DIR}/.issues.lock"

YQ="${YQ:-yq}"
if ! command -v "$YQ" >/dev/null 2>&1; then
    if [ -x "${SCRIPT_DIR}/bin/yq" ]; then
        YQ="${SCRIPT_DIR}/bin/yq"
    else
        echo "Error: yq not found. Install mikefarah/yq first." >&2
        exit 1
    fi
fi

VALID_LABELS="ceph gluster ipmi infra bench script doc"
VALID_STATUSES="plan active verify blocked done"

usage() {
    cat <<'USAGE'
Usage: issue.sh <command> [options]

Commands:
  list [--status STATUS] [--label LABEL]  List issues (default: exclude done)
  show <id>                               Show issue details
  add <title> [--label LABEL]...          Create new issue (status=plan)
  edit <id> [options]                     Edit issue fields
  start <id> [--owner OWNER]             plan/blocked → active
  block <id> [REASON]                    active → blocked
  verify <id>                            active → verify
  done <id> [--report PATH]             verify → done
  reopen <id>                            done/verify → active
USAGE
}

validate_label() {
    local label="$1"
    for valid in $VALID_LABELS; do
        if [ "$label" = "$valid" ]; then
            return 0
        fi
    done
    echo "Error: Invalid label '$label'. Valid labels: $VALID_LABELS" >&2
    return 1
}

validate_status() {
    local status="$1"
    for valid in $VALID_STATUSES; do
        if [ "$status" = "$valid" ]; then
            return 0
        fi
    done
    echo "Error: Invalid status '$status'. Valid statuses: $VALID_STATUSES" >&2
    return 1
}

find_issue_index() {
    local id="$1"
    local idx
    idx=$(YQ_ID="$id" "$YQ" '.issues | to_entries | map(select(.value.id == env(YQ_ID))) | .[0].key // "-1"' "$ISSUES_FILE")
    if [ "$idx" = "-1" ] || [ "$idx" = "null" ]; then
        echo "Error: Issue #${id} not found" >&2
        return 1
    fi
    echo "$idx"
}

with_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    flock -w 10 9 || { echo "Error: Could not acquire lock" >&2; exit 1; }
    "$@"
    exec 9>&-
}

format_issue_line() {
    local idx="$1"
    local id status title owner labels_str line
    id=$(YQ_IDX="$idx" "$YQ" '.issues[env(YQ_IDX)].id' "$ISSUES_FILE")
    status=$(YQ_IDX="$idx" "$YQ" '.issues[env(YQ_IDX)].status' "$ISSUES_FILE")
    title=$(YQ_IDX="$idx" "$YQ" '.issues[env(YQ_IDX)].title' "$ISSUES_FILE")
    owner=$(YQ_IDX="$idx" "$YQ" '.issues[env(YQ_IDX)].owner' "$ISSUES_FILE")
    labels_str=$(YQ_IDX="$idx" "$YQ" '.issues[env(YQ_IDX)].labels // [] | join(",")' "$ISSUES_FILE")
    line="#${id}  [${status}]  ${title}"
    if [ -n "$owner" ]; then
        line="${line}  (@${owner})"
    fi
    if [ -n "$labels_str" ]; then
        line="${line}  {${labels_str}}"
    fi
    echo "$line"
}

cmd_list() {
    local filter_status="" filter_label=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --status) filter_status="$2"; validate_status "$filter_status"; shift 2 ;;
            --label)  filter_label="$2"; validate_label "$filter_label"; shift 2 ;;
            *) echo "Error: Unknown option '$1'" >&2; return 1 ;;
        esac
    done

    local count
    count=$("$YQ" '.issues | length' "$ISSUES_FILE")
    if [ "$count" = "0" ]; then
        echo "No issues found."
        return 0
    fi

    local found=0
    local i=0
    while [ "$i" -lt "$count" ]; do
        local status
        status=$(YQ_IDX="$i" "$YQ" '.issues[env(YQ_IDX)].status' "$ISSUES_FILE")

        if [ -n "$filter_status" ]; then
            if [ "$status" != "$filter_status" ]; then
                i=$((i + 1))
                continue
            fi
        else
            if [ "$status" = "done" ]; then
                i=$((i + 1))
                continue
            fi
        fi

        if [ -n "$filter_label" ]; then
            local has_label
            has_label=$(YQ_IDX="$i" YQ_LBL="$filter_label" "$YQ" '.issues[env(YQ_IDX)].labels // [] | map(select(. == env(YQ_LBL))) | length' "$ISSUES_FILE")
            if [ "$has_label" = "0" ]; then
                i=$((i + 1))
                continue
            fi
        fi

        format_issue_line "$i"
        found=$((found + 1))
        i=$((i + 1))
    done

    if [ "$found" -eq 0 ]; then
        echo "No matching issues found."
    fi
}

cmd_show() {
    if [ $# -lt 1 ]; then
        echo "Usage: issue.sh show <id>" >&2
        return 1
    fi
    local id="$1"
    local idx
    idx=$(find_issue_index "$id") || return 1
    YQ_IDX="$idx" "$YQ" '.issues[env(YQ_IDX)]' "$ISSUES_FILE"
}

do_add() {
    local title="" desc="" labels=""
    if [ $# -lt 1 ]; then
        echo "Usage: issue.sh add <title> [--label LABEL]... [--desc DESCRIPTION]" >&2
        return 1
    fi
    title="$1"; shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --label) validate_label "$2"; labels="${labels:+${labels} }$2"; shift 2 ;;
            --desc)  desc="$2"; shift 2 ;;
            *) echo "Error: Unknown option '$1'" >&2; return 1 ;;
        esac
    done

    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local next_id
    next_id=$("$YQ" '.next_id' "$ISSUES_FILE")
    local new_next_id=$((next_id + 1))

    export YQ_TITLE="$title" YQ_NOW="$now" YQ_ID="$next_id" YQ_NID="$new_next_id" YQ_DESC="$desc"
    "$YQ" -i '
        .issues += [{"id": env(YQ_ID), "title": strenv(YQ_TITLE), "status": "plan", "owner": "", "created": strenv(YQ_NOW), "updated": strenv(YQ_NOW), "blocked_by": "", "report": "", "labels": [], "description": strenv(YQ_DESC)}] |
        .next_id = env(YQ_NID)
    ' "$ISSUES_FILE"
    unset YQ_TITLE YQ_NOW YQ_ID YQ_NID YQ_DESC

    if [ -n "$labels" ]; then
        local last_idx
        last_idx=$("$YQ" '.issues | length - 1' "$ISSUES_FILE")
        for lbl in $labels; do
            YQ_IDX="$last_idx" YQ_LBL="$lbl" "$YQ" -i '.issues[env(YQ_IDX)].labels += [strenv(YQ_LBL)]' "$ISSUES_FILE"
        done
    fi

    echo "Created issue #${next_id}: ${title}"
}

cmd_add() {
    with_lock do_add "$@"
}

do_edit() {
    if [ $# -lt 1 ]; then
        echo "Usage: issue.sh edit <id> [--title T] [--desc D] [--label LABEL]... [--owner O]" >&2
        return 1
    fi
    local id="$1"; shift
    local idx
    idx=$(find_issue_index "$id") || return 1

    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    while [ $# -gt 0 ]; do
        case "$1" in
            --title)
                YQ_IDX="$idx" YQ_VAL="$2" "$YQ" -i '.issues[env(YQ_IDX)].title = strenv(YQ_VAL)' "$ISSUES_FILE"
                shift 2 ;;
            --desc)
                YQ_IDX="$idx" YQ_VAL="$2" "$YQ" -i '.issues[env(YQ_IDX)].description = strenv(YQ_VAL)' "$ISSUES_FILE"
                shift 2 ;;
            --label)
                validate_label "$2"
                YQ_IDX="$idx" YQ_VAL="$2" "$YQ" -i '.issues[env(YQ_IDX)].labels += [strenv(YQ_VAL)] | .issues[env(YQ_IDX)].labels = (.issues[env(YQ_IDX)].labels | unique)' "$ISSUES_FILE"
                shift 2 ;;
            --owner)
                YQ_IDX="$idx" YQ_VAL="$2" "$YQ" -i '.issues[env(YQ_IDX)].owner = strenv(YQ_VAL)' "$ISSUES_FILE"
                shift 2 ;;
            *)
                echo "Error: Unknown option '$1'" >&2; return 1 ;;
        esac
    done

    YQ_IDX="$idx" YQ_NOW="$now" "$YQ" -i '.issues[env(YQ_IDX)].updated = strenv(YQ_NOW)' "$ISSUES_FILE"
    echo "Updated issue #${id}"
}

cmd_edit() {
    with_lock do_edit "$@"
}

do_start() {
    if [ $# -lt 1 ]; then
        echo "Usage: issue.sh start <id> [--owner OWNER]" >&2
        return 1
    fi
    local id="$1"; shift
    local owner=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --owner) owner="$2"; shift 2 ;;
            *) echo "Error: Unknown option '$1'" >&2; return 1 ;;
        esac
    done

    local idx
    idx=$(find_issue_index "$id") || return 1
    local current_status
    current_status=$(YQ_IDX="$idx" "$YQ" '.issues[env(YQ_IDX)].status' "$ISSUES_FILE")

    if [ "$current_status" != "plan" ] && [ "$current_status" != "blocked" ]; then
        echo "Error: Cannot start issue #${id} (status=${current_status}). Only plan/blocked → active allowed." >&2
        return 1
    fi

    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    YQ_IDX="$idx" YQ_NOW="$now" "$YQ" -i '.issues[env(YQ_IDX)].status = "active" | .issues[env(YQ_IDX)].updated = strenv(YQ_NOW) | .issues[env(YQ_IDX)].blocked_by = ""' "$ISSUES_FILE"
    if [ -n "$owner" ]; then
        YQ_IDX="$idx" YQ_OWNER="$owner" "$YQ" -i '.issues[env(YQ_IDX)].owner = strenv(YQ_OWNER)' "$ISSUES_FILE"
    fi

    echo "Issue #${id} is now active"
}

cmd_start() {
    with_lock do_start "$@"
}

do_block() {
    if [ $# -lt 1 ]; then
        echo "Usage: issue.sh block <id> [REASON]" >&2
        return 1
    fi
    local id="$1"; shift
    local reason="${1:-}"

    local idx
    idx=$(find_issue_index "$id") || return 1
    local current_status
    current_status=$(YQ_IDX="$idx" "$YQ" '.issues[env(YQ_IDX)].status' "$ISSUES_FILE")

    if [ "$current_status" != "active" ]; then
        echo "Error: Cannot block issue #${id} (status=${current_status}). Only active → blocked allowed." >&2
        return 1
    fi

    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    YQ_IDX="$idx" YQ_NOW="$now" YQ_REASON="$reason" "$YQ" -i '.issues[env(YQ_IDX)].status = "blocked" | .issues[env(YQ_IDX)].updated = strenv(YQ_NOW) | .issues[env(YQ_IDX)].blocked_by = strenv(YQ_REASON)' "$ISSUES_FILE"

    echo "Issue #${id} is now blocked${reason:+ (${reason})}"
}

cmd_block() {
    with_lock do_block "$@"
}

do_verify() {
    if [ $# -lt 1 ]; then
        echo "Usage: issue.sh verify <id>" >&2
        return 1
    fi
    local id="$1"

    local idx
    idx=$(find_issue_index "$id") || return 1
    local current_status
    current_status=$(YQ_IDX="$idx" "$YQ" '.issues[env(YQ_IDX)].status' "$ISSUES_FILE")

    if [ "$current_status" != "active" ]; then
        echo "Error: Cannot verify issue #${id} (status=${current_status}). Only active → verify allowed." >&2
        return 1
    fi

    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    YQ_IDX="$idx" YQ_NOW="$now" "$YQ" -i '.issues[env(YQ_IDX)].status = "verify" | .issues[env(YQ_IDX)].updated = strenv(YQ_NOW)' "$ISSUES_FILE"

    echo "Issue #${id} is now in verify"
}

cmd_verify() {
    with_lock do_verify "$@"
}

do_done() {
    if [ $# -lt 1 ]; then
        echo "Usage: issue.sh done <id> [--report PATH]" >&2
        return 1
    fi
    local id="$1"; shift
    local report=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --report) report="$2"; shift 2 ;;
            *) echo "Error: Unknown option '$1'" >&2; return 1 ;;
        esac
    done

    local idx
    idx=$(find_issue_index "$id") || return 1
    local current_status
    current_status=$(YQ_IDX="$idx" "$YQ" '.issues[env(YQ_IDX)].status' "$ISSUES_FILE")

    if [ "$current_status" != "verify" ]; then
        echo "Error: Cannot complete issue #${id} (status=${current_status}). Only verify → done allowed." >&2
        return 1
    fi

    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    YQ_IDX="$idx" YQ_NOW="$now" "$YQ" -i '.issues[env(YQ_IDX)].status = "done" | .issues[env(YQ_IDX)].updated = strenv(YQ_NOW)' "$ISSUES_FILE"
    if [ -n "$report" ]; then
        YQ_IDX="$idx" YQ_REPORT="$report" "$YQ" -i '.issues[env(YQ_IDX)].report = strenv(YQ_REPORT)' "$ISSUES_FILE"
    fi

    echo "Issue #${id} is done"
}

cmd_done() {
    with_lock do_done "$@"
}

do_reopen() {
    if [ $# -lt 1 ]; then
        echo "Usage: issue.sh reopen <id>" >&2
        return 1
    fi
    local id="$1"

    local idx
    idx=$(find_issue_index "$id") || return 1
    local current_status
    current_status=$(YQ_IDX="$idx" "$YQ" '.issues[env(YQ_IDX)].status' "$ISSUES_FILE")

    if [ "$current_status" != "done" ] && [ "$current_status" != "verify" ]; then
        echo "Error: Cannot reopen issue #${id} (status=${current_status}). Only done/verify → active allowed." >&2
        return 1
    fi

    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    YQ_IDX="$idx" YQ_NOW="$now" "$YQ" -i '.issues[env(YQ_IDX)].status = "active" | .issues[env(YQ_IDX)].updated = strenv(YQ_NOW)' "$ISSUES_FILE"

    echo "Issue #${id} is now active (reopened)"
}

cmd_reopen() {
    with_lock do_reopen "$@"
}

if [ $# -lt 1 ]; then
    usage
    exit 1
fi

command="$1"; shift
case "$command" in
    list)   cmd_list "$@" ;;
    show)   cmd_show "$@" ;;
    add)    cmd_add "$@" ;;
    edit)   cmd_edit "$@" ;;
    start)  cmd_start "$@" ;;
    block)  cmd_block "$@" ;;
    verify) cmd_verify "$@" ;;
    done)   cmd_done "$@" ;;
    reopen) cmd_reopen "$@" ;;
    help|-h|--help) usage ;;
    *)
        echo "Error: Unknown command '$command'" >&2
        usage
        exit 1
        ;;
esac
