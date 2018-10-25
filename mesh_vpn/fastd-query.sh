#!/usr/bin/env bash

FASTD_SOCKET=${FASTD_SOCKET:-}
SOCAT=$(which socat 2>/dev/null)
JQ=$(which jq 2>/dev/null)

socketpipe() {
 "$SOCAT" - UNIX:"$FASTD_SOCKET"
}

help_general(){
  echo "Usage: $0 OBJECT { COMMAND | help }"
  echo "where OBJECT := { STATISTICS | connections | peers }"
  echo "      STATISTICS := statistics JQ-STRING"
  echo
  echo "The fastd socket is declared by env variable FASTD_SOCKET."
}

if [ "x${SOCAT}" = "x" ]; then
  echo "Error: 'socat' not found in PATH"
  exit 2
fi

if [ "x${JQ}" = "x" ]; then
  echo "Error: 'jq' not found in PATH"
  exit 2
fi

if [ "x${FASTD_SOCKET}" = "x" ]; then
  echo "Error: No fastd socket declarded"
  help_general
  exit 1
fi

if [ ! -S "${FASTD_SOCKET}" ]; then
  echo "Error: File '${FASTD_SOCKET}' does not exists, or is no socket"
fi

case $1 in
  peers|p)
    shift
    QUERY=".peers[]"
    case $1 in
      name|n)
        QUERY="${QUERY} | select(.name == \"${2}\")"
        shift 2
        ;;
      mac|m)
        QUERY="${QUERY} | select( .connection | .mac_addresses[]? == \"${2}\")"
        shift 2
        ;;
      help|h)
        echo "Usage: $0 peers name STRING JQ-STRING"
        echo "       $0 peers mac LLADDR JQ-STRING"
        echo "       $0 peers JQ-STRING"
        exit 0
        ;;
    esac
    socketpipe | "$JQ" "$QUERY | ${@:-.}"
    ;;
  connections|c)
    socketpipe | "$JQ" '.peers[] | select( .connection ) | .name' | wc -l
    ;;
  statistics|s)
    shift
    socketpipe | "$JQ" ".statistics[] | ${@:-.}"
    ;;
  *|help)
    help_general
  ;;
esac
