#!/bin/bash

set -e -o pipefail

USER_AGENT='Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:57.0) Gecko/20100101 Firefox/57.0'
CONNECT_TIMEOUT=10

CURL_FMT="$(cat <<'EOF'
http_code=%{http_code}
local_ip=%{local_ip}
remote_ip=%{remote_ip}
time_connect=%{time_connect}
time_starttransfer=%{time_starttransfer}
time_total=%{time_total}
EOF
)"

fatal() {
  code="$1"
  shift 1
  trap '' TERM EXIT INT
  ( >&2 echo $@ )
  exit "$code"
}

usage() {
  fatal 1 "$0 [-4|-6] <url>"
}

error() {
  fatal 1 "Unexpected error"
}

trap error TERM EXIT INT

CURL_OPTS=""

while getopts '46' o; do
  case "$o" in
    4)
      CURL_OPTS="-4"
      ;;
    6)
      CURL_OPTS="-6"
      ;;
  esac
done

URL="${!OPTIND}"
[ -z "$URL" ] && usage

set +e
curl_capture="$(curl $CURL_OPTS --connect-timeout "$CONNECT_TIMEOUT" --user-agent "$USER_AGENT" --write-out "$CURL_FMT" -o /dev/null "$URL" 2>&1)"
curl_exit="$?"
set -e

[ "$curl_exit" -ne 0 ] && fatal 3 "Curl execution failed: $curl_capture"

echo "$curl_capture" | grep -q time_connect && {
  trap '' TERM EXIT INT
  echo 100
  exit 0
}

fatal 1 "Unexpected curl output: $curl_capture"
