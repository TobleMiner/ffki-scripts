#!/usr/bin/env bash

DIR="$(dirname "$(readlink -f "$0")")"
"$DIR/curl_wrapper.sh" -4 "${0##*_}"
