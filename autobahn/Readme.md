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

* wss server: `nim c -r examples/tlsserver.nim`
  * autobahn: `wstest --mode fuzzingclient --spec fuzzingclient_tls.json`
  * Reports will be generated in `reports/server_tls` which can be configured in `fuzzingclient_tls.json`
