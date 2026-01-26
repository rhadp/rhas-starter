#!/bin/bash
set -e

#while true; do
#  sleep 30s
#  echo "radioapp-container is running"
#done

# Create log directory
mkdir -p /tmp/log

echo "=== Container starting at $(date) ==="

echo "Starting dlt-daemon..."
dlt-daemon 2>&1 | tee /tmp/log/dlt-daemon.log &
sleep 1

echo "Starting routingmanagerd..."
routingmanagerd 2>&1 | tee /tmp/log/routingmanagerd.log &
sleep 1

echo "Starting engine-service..."
engine-service 2>&1 | tee /tmp/log/engine.log &
sleep 1

echo "Starting radio-service..."
radio-service 2>&1 | tee /tmp/log/radio.log &
sleep 1

echo "Starting socat (radio-client)..."
socat TCP-LISTEN:8000,reuseaddr,fork EXEC:radio-client,pty 2>&1 | tee /tmp/log/socat.log

# socat -,raw,echo=0 TCP-CONNECT:127.0.0.1:8000
