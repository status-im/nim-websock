## Running autobahn test suite.

### Install autobahn
```bash
# Set up virtualenv in autobahn folder
virtualenv --python=/usr/bin/python2 autobahn

# Activate the virtualenv
source autobahn/bin/activate

# Install autobahn
pip install autobahntestsuite
```

### Run the test Websocket client.
* ws server: `nim c -r examples/server.nim`
  * autobahn: `wstest --mode fuzzingclient --spec fuzzingclient.json`
  * Reports will be generated in `reports/server` which can be configured in `fuzzingclient.json`

* wss server: `nim c -r -d:tls examples/server.nim`
  * autobahn: `wstest --mode fuzzingclient --spec fuzzingclient_tls.json`
  * Reports will be generated in `reports/server_tls` which can be configured in `fuzzingclient_tls.json`

* ws client:
  * autobahn: `wstest --mode fuzzingserver --spec fuzzingserver.json`
  * ws: `nim c -r examples/autobahn_client.nim`

* wss client:
  * autobahn: `wstest --mode fuzzingserver --spec fuzzingserver_tls.json`
  * ws: `nim c -r -d:tls examples/autobahn_client.nim`
