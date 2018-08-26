#!/usr/bin/env bash

DIR="$(dirname "$(readlink -f "$0")")"
"$DIR/curl_wrapper.sh" -6 "${0##*_}"
