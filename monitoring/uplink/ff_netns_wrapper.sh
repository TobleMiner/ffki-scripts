#!/usr/bin/env bash

set -e -o pipefail

error() {
  ( >&2 echo $@ )
}

fatal() {
  error $@
  exit 1
}

nw_ns_create() {
  netns="$1"
  [ -z "$netns" ] && fatal "usage: nw_ns_create <netns>"
  ip netns list | grep -q "$netns" || {
    ip netns add "$netns"
  }
}

nw_ns_ensure_member() {
  netns="$1"
  member="$2"
  ip netns exec "$netns" ip link show dev "$member" &> /dev/null || {
    ip link set netns "$netns" dev "$member"
  }
}

nw_veth_pair_create() {
  name="$1"
  peer_name="$2"
  [ -n "$name" ] && [ -n "$peer_name" ] || fatal "usage: nw_veth_pair_create <name> <peer_name>"
  ip link show "$name" &> /dev/null || {
    ip link add name "$name" type veth peer name "$peer_name"
  }
}

nw_bridge_ensure_member() {
  bridge="$1"
  member="$2"
  [ -n "$bridge" ] && [ -n "$member" ] || fatal "usage: nw_bridge_ensure_member <bridge> <member>"
  brctl show "$bridge" | grep -q "$member" || {
    brctl addif "$bridge" "$member"
  }
}

usage() {
  fatal "$0 <mesh bridge> <script> [args]"
}


MESH_BRIDGE="$1"
SCRIPT="$2"

[ -n "$MESH_BRIDGE" ] && [ -n "$SCRIPT" ] || {
  usage
}

shift 2

NETNS="client-$MESH_BRIDGE"

export CLIENT_DEVICE="remote-$MESH_BRIDGE"

nw_ns_create "$NETNS"
nw_veth_pair_create "local-$MESH_BRIDGE" "$CLIENT_DEVICE"
nw_bridge_ensure_member "$MESH_BRIDGE" "local-$MESH_BRIDGE"
nw_ns_ensure_member "$NETNS" "$CLIENT_DEVICE"

ip link set up "local-$MESH_BRIDGE"
ip netns exec "$NETNS" ip link set up "$CLIENT_DEVICE"

ip netns exec "$NETNS" "$SCRIPT" $@
