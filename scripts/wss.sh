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

nim c -d:tls -d:release -o:examples/tls_server examples/server.nim
examples/tls_server &
server=$!

mkdir -p autobahn/reports

docker run \
  -v ${REPO_DIR}/autobahn:/config \
  -v ${REPO_DIR}/autobahn/reports:/reports \
  --network=host \
  --name fuzzingclient_tls \
  crossbario/autobahn-testsuite wstest --mode fuzzingclient --spec /config/fuzzingclient_tls.json

kill $server

mv autobahn/reports/server_tls autobahn/reports/server_tls-${NIM_VERSION}

echo "* [Nim-${NIM_VERSION} wss server summary report](server_tls-${NIM_VERSION}/index.html)" > "autobahn/reports/server_tls-${NIM_VERSION}.txt"
