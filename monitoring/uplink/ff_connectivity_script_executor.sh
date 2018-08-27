#!/usr/bin/env bash

# This script performs setup of the virtual client.
# Ideally this script is executed in a new, clean network namespace
# It can handle being executed in a fairly cluttered environment though

# Checks must use special error codes to signal why the exited:
#   0: No error. Connection quality in range from 0-100 in last output line
#   1: OSI layer 8 error. Unspecific not network-related error. Write stdout+stderr to log
#   2: Network error. Assume connection quality 0
#   3: Unexpected network error. Assume connection quality 0 and write stdout+stderr to log

set -x

set -e -o pipefail

DHCP_TIMEOUT=10
IPV4_ROUTE_TIMEOUT=10
IPV6_ROUTE_TIMEOUT=30

IPV4_TRIES=3
IPV6_TRIES=3

error() {
  ( >&2 echo $@ )
}

fatal() {
  code="$1"
  shift
  error $@
  exit "$code"
}

usage() {
  fatal 1 "$0 [-4 SCRIPT ...] [-6 SCRIPT ...] [-f SCRIPT ...]"
}

ENVVARS=(SITE_CODE CLIENT_NETNS CLIENT_DEVICE)

for var in "${ENVVARS[@]}"; do
  [ -z "${!var}" ] && fatal 1 "Envvar $var must be set"
  # Environment variables are not substituted in heredocs
  # Redeclare relevant environment variables as local variables
  declare -x "$var"="${!var}"
done

declare -A SCRIPTS

INDEX[4]=0
INDEX[6]=0
INDEX[f]=0

current_key=''
while [ $# -gt 0 ]; do
  unset OPTIND
  while getopts '46f' arg; do
    current_key="$arg"
  done
  [[ -v OPTIND ]] && shift $((OPTIND - 1))
  [ $# -eq 0 ] && break
  [ -n "$current_key" ] || usage
  SCRIPTS["${current_key}_${INDEX["$current_key"]}"]="$1"
  INDEX["$current_key"]="$((${INDEX["$current_key"]} + 1))"
  shift || true
done

CHECKS4=()
for i in `seq 0 $((${INDEX[4]} - 1))`; do
  CHECKS4+=("${SCRIPTS[4_$i]}")
done

CHECKS6=()
for i in `seq 0 $((${INDEX[6]} - 1))`; do
  CHECKS6+=("${SCRIPTS[6_$i]}")
done

FAILS=()
for i in `seq 0 $((${INDEX[f]} - 1))`; do
  FAILS+=("${SCRIPTS[f_$i]}")
done

echo "init done"

teardown_ipv4() {
echo "teardown ipv4"
ip netns exec "$CLIENT_NETNS" "$SHELL" <<EOF
  set -x

  set -e -o pipefail

  fatal() {
    ( >&2 echo \$@ )
    exit 1
  }

  if_ipv4_cidr() {
    cidrs="\$(ip -4 addr show dev "\$1" | egrep -o '((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)/[0-9]{1,2}')"
    available="\$?"
    echo "\$cidrs" | head -n1
    return "\$available"
  }

  ipv4_default_route() {
    routes="\$(ip -4 route show to match 0.0.0.0/0 | egrep 'default|0\.0\.0\.0')"
    available="\$?"
    echo "\$routes" | head -n1
    return "\$available"
  }

  # Exit any existing dhcpcd instance on our interface
  dhcpcd -4 -k "$CLIENT_DEVICE" &> /dev/null || true
  # Remove all existing ipv4 addresses from our interface
  while if_ipv4_cidr "$CLIENT_DEVICE" &> /dev/null; do
    cidr="\$(if_ipv4_cidr "$CLIENT_DEVICE")"
    ip addr del "\$cidr" dev "$CLIENT_DEVICE"
  done
  # Remove all default routes
  while ipv4_default_route &> /dev/null; do
    ip route del \$(ipv4_default_route)
  done
EOF
}

setup_ipv4() {
echo "setup ipv4"
teardown_ipv4
ip netns exec "$CLIENT_NETNS" "$SHELL" <<EOF
  set -x

  set -e -o pipefail

  fatal() {
    ( >&2 echo \$@ )
    exit 1
  }

  if_ipv4_cidr() {
    cidrs="\$(ip -4 addr show dev "\$1" | egrep -o '((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)/[0-9]{1,2}')"
    available="\$?"
    echo "\$cidrs" | head -n1
    return "\$available"
  }

  ipv4_default_route() {
    routes="\$(ip -4 route show to match 0.0.0.0/0 | egrep 'default|0\.0\.0\.0')"
    available="\$?"
    echo "\$routes" | head -n1
    return "\$available"
  }


  # Create a new dhcpcd instance on the client device
  dhcpcd -4 --nohook resolv.conf "$CLIENT_DEVICE" &> /dev/null
  # Wait for dhcp lease
  got_lease=''
  for _ in \$(seq "$DHCP_TIMEOUT"); do
    sleep 1
    if_ipv4_cidr "$CLIENT_DEVICE" &> /dev/null && {
      got_lease=yes
      break
    }
  done
  if [ "\$got_lease" != yes ]; then
    fatal "Failed to obtain ipv4 lease"
  fi
  # Wait for ipv4 default route
  got_ipv4_default_route=''
  for _ in \$(seq "$IPV4_ROUTE_TIMEOUT"); do
    ipv4_default_route &> /dev/null && {
      got_ipv4_default_route=yes
      break
    }
    sleep 1
  done
  if [ "\$got_ipv4_default_route" != yes ]; then
    fatal "Failed to obtain ipv4 default route"
  fi
  exit 0
EOF
}

# Prepare ipv6
setup_ipv6() {
echo "setup ipv6"
ip netns exec "$CLIENT_NETNS" "$SHELL" <<EOF
  set -x
  set -e -o pipefail

  fatal() {
    ( >&2 echo \$@ )
    exit 1
  }

  ipv6_default_route() {
    routes="\$(ip -6 route show to match ::/0 | grep default)"
    available=\$?
    echo "\$routes" | head -n1
    return \$available
  }

  # Wait for ipv6 default route
  got_ipv6_default_route=''
  for _ in \$(seq "$IPV6_ROUTE_TIMEOUT"); do
    ipv6_default_route &> /dev/null && {
      got_ipv6_default_route=yes
      break
    }
    sleep 1
  done
  if [ "\$got_ipv6_default_route" != yes ]; then
    fatal "Failed to obtain ipv6 default route"
  fi
  exit 0
EOF
}

fail() {
  code="$?"
  echo "TRAP HANDLER"
  trap 'code=$?; teardown_ipv4 || true; exit $?' EXIT INT TERM
  for script in "${FAILS[@]}"; do
    "$script" "$1"
  done
  exit "$code"
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
for v in 4 6; do
  declare -n arr="CHECKS${v}"
  quality_max=$((${#arr[@]} * 100))
  quality_sum=0
  for script in "${arr[@]}"; do
    set +e
    check_output="$(ip netns exec "$CLIENT_NETNS" "$script" 2>&1)"
    check_exit="$?"
    set -e
    case "$check_exit" in
      0)
        score="$(echo "$check_output" | tail -n1 | egrep -o '[0-9]+')"
        quality_sum="$((quality_sum + score))"
        ;;
      1)
        fatal 1 "Check '$script' failed: $check_output"
        ;;
      2)
         # Assume score of zero
        ;;
      3)
        error "Check '$script' failed: $check_output"
        ;;
      *)
        error "Check '$script' returned unexpected exit code '$check_exit': $check_output"
        ;;
    esac
  done

  echo "IPv${v}: Quality $quality_sum/$quality_max"
done
