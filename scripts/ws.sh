#!/usr/bin/env bash

# Copyright (c) 2025 Status Research & Development GmbH.
# Licensed under either of:
# - Apache License, version 2.0
# - MIT license
# at your option.

# prevent issue https://github.com/status-im/nimbus-eth1/issues/3661

set -e

cd "$(dirname "${BASH_SOURCE[0]}")"/..

REPO_DIR="${PWD}"

nim c -d:release examples/server
examples/server &
server=$!

mkdir -p reports

docker run \
  -v ${REPO_DIR}/autobahn:/config \
  -v ${REPO_DIR}/reports:/reports \
  --network=host \
  --name fuzzingclient \
  crossbario/autobahn-testsuite wstest --mode fuzzingclient --spec /config/fuzzingclient.json

kill $server
