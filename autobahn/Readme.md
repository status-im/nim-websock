## Running autobahn test suite.

### Start the websocket server

```bash
nim c -r examples/server.nim
```

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
```bash
 wstest --mode fuzzingclient --spec fuzzingclient.json
```

Reports will be generated in `reports/server` which can be configured in `fuzzingclient.json`