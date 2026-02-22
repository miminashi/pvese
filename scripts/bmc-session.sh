#!/bin/sh
set -eu

usage() {
    echo "Usage: bmc-session.sh <command> <args...>"
    echo ""
    echo "Commands:"
    echo "  login <bmc_ip> <user> <pass> <cookie_file>   Login and save session cookie"
    echo "  csrf  <bmc_ip> <cookie_file>                  Get CSRF token (prints to stdout)"
    echo "  check <bmc_ip> <cookie_file>                  Check if session is valid (exit 0/1)"
    exit 1
}

cmd_login() {
    bmc_ip="$1"
    user="$2"
    pass="$3"
    cookie_file="$4"

    http_code=$(curl -sk -o /dev/null -w '%{http_code}' \
        -X POST "https://${bmc_ip}/cgi/login.cgi" \
        -d "name=${user}&pwd=${pass}" \
        -c "$cookie_file")

    if [ "$http_code" = "200" ]; then
        echo "Login OK (cookie: $cookie_file)"
    else
        echo "Login failed: HTTP $http_code" >&2
        exit 1
    fi
}

cmd_csrf() {
    bmc_ip="$1"
    cookie_file="$2"

    body=$(curl -sk -b "$cookie_file" "https://${bmc_ip}/cgi/url_redirect.cgi?url_name=topmenu")

    token=$(echo "$body" | sed -n 's/.*CSRF_TOKEN", "\([^"]*\)".*/\1/p' | head -1)

    if [ -z "$token" ]; then
        echo "CSRF token not found in response" >&2
        exit 1
    fi

    echo "$token"
}

cmd_check() {
    bmc_ip="$1"
    cookie_file="$2"

    if [ ! -f "$cookie_file" ]; then
        exit 1
    fi

    http_code=$(curl -sk -o /dev/null -w '%{http_code}' \
        -b "$cookie_file" \
        "https://${bmc_ip}/cgi/url_redirect.cgi?url_name=topmenu")

    if [ "$http_code" = "200" ]; then
        exit 0
    else
        exit 1
    fi
}

if [ $# -lt 1 ]; then
    usage
fi

command="$1"; shift

case "$command" in
    login)
        if [ $# -lt 4 ]; then usage; fi
        cmd_login "$1" "$2" "$3" "$4"
        ;;
    csrf)
        if [ $# -lt 2 ]; then usage; fi
        cmd_csrf "$1" "$2"
        ;;
    check)
        if [ $# -lt 2 ]; then usage; fi
        cmd_check "$1" "$2"
        ;;
    *)
        usage
        ;;
esac
