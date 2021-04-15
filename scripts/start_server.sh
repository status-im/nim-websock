#!/bin/bash

 nim c -r examples/server.nim &

 max_iterations=10
 wait_seconds=6
 http_endpoint="http://127.0.0.1:8888/"

 iterations=0
 while true
 do
 	((iterations++))
 	echo "Attempt $iterations"
 	sleep $wait_seconds

 	http_code=$(curl --verbose -s -o /tmp/result.txt -w '%{http_code}' "$http_endpoint";)

 	if [ "$http_code" -eq 200 ]; then
 		echo "Server Up"
 		break
 	fi

 	if [ "$iterations" -ge "$max_iterations" ]; then
 		echo "Loop Timeout"
 		exit 1
 	fi
 done