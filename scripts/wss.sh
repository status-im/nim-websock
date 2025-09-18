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

mkdir -p reports

docker run -d \
  -v ${REPO_DIR}/autobahn:/config \
  -v ${REPO_DIR}/reports:/reports \
  --network=host \
  --name fuzzingserver \
  crossbario/autobahn-testsuite wstest --webport=0 --mode fuzzingserver --spec /config/fuzzingserver.json

nim c -d:release examples/autobahn_client
examples/autobahn_client

docker kill fuzzingserver
