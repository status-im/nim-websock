#!/usr/bin/env bash

# Copyright (c) 2025 Status Research & Development GmbH.
# Licensed under either of:
# - Apache License, version 2.0
# - MIT license
# at your option.

# prevent issue https://github.com/status-im/nimbus-eth1/issues/3661

set -e

# script arguments
[[ $# -ne 1 ]] && { echo "Usage: $0 NIM_VERSION"; }
NIM_VERSION="$1"

cd "$(dirname "${BASH_SOURCE[0]}")"/..

REPO_DIR="${PWD}"

mkdir -p autobahn/reports

docker run -d \
  -v ${REPO_DIR}/autobahn:/config \
  -v ${REPO_DIR}/autobahn/reports:/reports \
  --network=host \
  --name fuzzingserver_tls \
  crossbario/autobahn-testsuite wstest --webport=0 --mode fuzzingserver --spec /config/fuzzingserver_tls.json

nim c -d:tls -d:release -o:examples/autobahn_tlsclient examples/autobahn_client
examples/autobahn_tlsclient

docker kill fuzzingserver_tls

mv autobahn/reports/client_tls autobahn/reports/client_tls-${NIM_VERSION}

echo "* [Nim-${NIM_VERSION} wss client summary report](client_tls-${NIM_VERSION}/index.html)" > "autobahn/reports/client_tls-${NIM_VERSION}.txt"
