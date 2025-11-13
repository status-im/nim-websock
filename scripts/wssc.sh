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
CFG="client_tls"
REPORT_DIR="autobahn/reports/$CFG-$NIM_VERSION"
mkdir -p autobahn/reports/$CFG

docker run -d --rm \
  -v ${REPO_DIR}/autobahn:/config \
  -v ${REPO_DIR}/autobahn/reports:/reports \
  --network=host \
  --name fuzzingserver_tls \
  crossbario/autobahn-testsuite wstest --webport=0 --mode fuzzingserver --spec /config/fuzzingserver_tls.json

trap "docker kill fuzzingserver_tls" SIGINT SIGTERM EXIT

nim c -d:tls -d:release -o:examples/autobahn_tlsclient examples/autobahn_client
examples/autobahn_tlsclient

mv autobahn/reports/$CFG $REPORT_DIR

echo "* [Nim-${NIM_VERSION} $CFG summary report]($CFG-${NIM_VERSION}/index.html)" > "$REPORT_DIR.txt"

# squash to single line and look for errors
cat $REPORT_DIR/index.json | tr '\n' '!' | sed "s|\},\!|\n|g" | tr '!' ' ' | tr -s ' ' | grep -v -e '"behavior": "OK"' -e '"behavior": "NON-STRICT"' -e '"behavior": "INFORMATIONAL"' -e '"behavior": "OK"' && quit 1
