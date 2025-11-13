#!/usr/bin/env bash

# Copyright (c) 2025 Status Research & Development GmbH.
# Licensed under either of:
# - Apache License, version 2.0
# - MIT license
# at your option.

# prevent issue https://github.com/status-im/nimbus-eth1/issues/3661

set -e
trap "trap - SIGTERM && kill -- -$$" SIGINT SIGTERM EXIT

# script arguments
[[ $# -ne 1 ]] && { echo "Usage: $0 NIM_VERSION"; }
NIM_VERSION="$1"

cd "$(dirname "${BASH_SOURCE[0]}")"/..

REPO_DIR="${PWD}"
CFG="server_tls"
REPORT_DIR="autobahn/reports/$CFG-$NIM_VERSION"
mkdir -p autobahn/reports/$CFG

nim c -d:tls -d:release -o:examples/tls_server examples/server.nim
examples/tls_server &

docker run --rm \
  -v ${REPO_DIR}/autobahn:/config \
  -v ${REPO_DIR}/autobahn/reports:/reports \
  --network=host \
  --name fuzzingclient_tls \
  crossbario/autobahn-testsuite wstest --mode fuzzingclient --spec /config/fuzzingclient_tls.json

mv autobahn/reports/$CFG "$REPORT_DIR"

echo "* [Nim-${NIM_VERSION} $CFG summary report]($CFG-${NIM_VERSION}/index.html)" > "$REPORT_DIR.txt"

# squash to single line and look for errors
cat $REPORT_DIR/index.json | tr '\n' '!' | sed "s|\},\!|\n|g" | tr '!' ' ' | tr -s ' ' | grep -v -e '"behavior": "OK"' -e '"behavior": "NON-STRICT"' -e '"behavior": "INFORMATIONAL"' -e '"behavior": "OK"' && quit 1
