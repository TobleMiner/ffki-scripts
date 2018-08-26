#!/usr/bin/env bash

# This script performs setup of the virtual client.
# Ideally this script is executed in a new, clean network namespace
# It can handle being executed in a fairly cluttered environment though

set -e -o pipefail

DHCP_TIMEOUT=10
IPV4_ROUTE_TIMEOUT=10
IPV6_ROUTE_TIMEOUT=30

IPV4_TRIES=3
IPV6_TRIES=3

fatal() {
  code="$1"
  shift 1
  ( >&2 echo $@ )
  exit "$code"
}

ENVVARS=(SITE_CODE CLIENT_NETNS CLIENT_DEVICE)

for var in "${ENVVARS[@]}"; do
  [ -z "${!var}" ] && fatal 1 "Envvar $var must be set"
done

CHECKS4=()
CHECKS6=()
FAILS=()

while getopts '4:6:f:' arg; do
  case "$arg" in
    4)
      CHECKS4+=("$OPTARG")
      ;;
    6)
      CHECKS6+=("$OPTARG")
      ;;
    f)
      FAILS+=("$OPTARG")
      ;;
  esac
done

teardown_ipv4() {
netns exec "$CLIENT_NETNS" "$SHELL" <<EOF
  set -e -o pipefail

  fatal() {
    ( >&2 echo $@ )
    exit 1
  }

  if_ipv4_cidr() {
    cidrs="$(ip -4 addr show dev "$1" | egrep -o '((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)/[0-9]{1,2}')"
    available=$?
    echo "$cidrs" | head -n1
    return $available
  }

  ipv4_default_route() {
    routes="$(ip -4 route show to match 0.0.0.0/0)"
    available=$?
    echo "$routes" | head -n1
    return $available
  }

  # Exit any existing dhcpcd instance on our interface
  dhcpcd -k "$CLIENT_DEVICE" &> /dev/null || true
  # Remove all existing ipv4 addresses from our interface
  while if_ipv4_cidr "$CLIENT_DEVICE" &> /dev/null; do
    cidr="$(if_ipv4_cidr "$CLIENT_DEVICE")"
    [ -z "$cidr" ] && fatal "inet tag without interface"
    ip addr del "$cidr" dev "$CLIENT_DEVICE"
  done
  # Remove all default routes
  while ipv4_default_route &> /dev/null; do
    ip route del $(ipv4_default_route)
  done
EOF
}

setup_ipv4() {
netns exec "$CLIENT_NETNS" "$SHELL" <<EOF
  set -e -o pipefail

  fatal() {
    ( >&2 echo $@ )
    exit 1
  }

  if_ipv4_cidr() {
    cidrs="$(ip -4 addr show dev "$1" | egrep -o '((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)/[0-9]{1,2}')"
    available=$?
    echo "$cidrs" | head -n1
    return $available
  }

  ipv4_default_route() {
    routes="$(ip -4 route show to match 0.0.0.0/0)"
    available=$?
    echo "$routes" | head -n1
    return $available
  }

  teardown_ipv4

  # Create a new dhcpcd instance on the client device
  dhcpcd --nohook resolv.conf "$CLIENT_DEVICE" &> /dev/null
  # Wait for dhcp lease
  got_lease=''
  for _ in `seq "$DHCP_TIMEOUT"`; do
    sleep 1
    if_ipv4_cidr "$CLIENT_DEVICE" &> /dev/null && {
      got_lease=yes
      break
    }
  done
  if [ "$got_lease" != yes ]; then
    fatal "Failed to obtain ipv4 lease"
  fi
  # Wait for ipv4 default route
  got_ipv4_default_route=''
  for _ in `seq "$IPV4_ROUTE_TIMEOUT"`; do
    ipv4_default_route &> /dev/null && {
      got_ipv4_default_route=yes
      break
    }
    sleep 1
  done
  if [ "$got_ipv4_default_route" != yes ]; then
    fatal "Failed to obtain ipv4 default route"
  fi
EOF
}

# Prepare ipv6
setup_ipv6() {
netns exec "$CLIENT_NETNS" "$SHELL" <<EOF
  set -e -o pipefail

  fatal() {
    ( >&2 echo $@ )
    exit 1
  }

  ipv6_default_route() {
    routes="$(ip -6 route show to match ::/0)"
    available=$?
    echo "$routes" | head -n1
    return $available
  }

  # Wait for ipv6 default route
  got_ipv6_default_route=''
  for _ in `seq "$IPV6_ROUTE_TIMEOUT"`; do
    ipv6_default_route &> /dev/null && {
      got_ipv6_default_route=yes
      break
    }
    sleep 1
  done
  if [ "$got_ipv6_default_route" != yes ]; then
    fatal "Failed to obtain ipv6 default route"
  fi
EOF
}

fail() {
  code="$?"
  trap teardown_ipv4 EXIT INT TERM
  for script in "${FAILS[@]}"; do
    "$script" "$1"
  done
  return "$code"
}

trap fail EXIT INT TERM

# setup
ipv4_ok=''
for _ in `seq $IPV4_TRIES`; do
  setup_ipv4 && {
    ipv4_ok=yes
    break
  }
done
if [[ "$ipv4_ok" != yes ]]; then
  fail ipv4
fi

ipv6_ok=''
for _ in `seq $IPV6_TRIES`; do
  setup_ipv6 && {
    ipv6_ok=yes
    break
  }
done
if [[ "$ipv6_ok" != yes ]]; then
  fail ipv6
fi

# checks
v4_cnt=${#CHECKS4[@]}
v4_ok=0
for script in "${CHECKS4[@]}"; do
  "$script" && v4_ok=$((v4_ok + 1))
done
v6_cnt=${#CHECKS6[@]}
v6_ok=0
for script in "${CHECKS6[@]}"; do
  "$script" && v6_ok=$((v6_ok + 1))
done
