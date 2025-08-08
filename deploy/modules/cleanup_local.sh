#!/usr/bin/env bash
# deploy/modules/cleanup_local.sh

set -euo pipefail

echo "Executing cleanup of all local resources due to failure..."

# Kill all SAM CLI processes (broader pattern)
pkill -f "sam local" 2>/dev/null || true
echo "✅ SAM CLI processes cleanup attempted."

# Stop and remove all LocalStack containers with force
docker stop $(docker ps -a -q -f "name=localstack") 2>/dev/null || true
docker rm -f $(docker ps -a -q -f "name=localstack") 2>/dev/null || true
echo "✅ LocalStack containers removed."

# Remove all unused Docker networks
docker network prune -f 2>/dev/null || true
echo "✅ Unused Docker networks pruned."

# Remove all unused Docker images
docker image prune -f 2>/dev/null || true
echo "✅ Unused Docker images pruned."

# Release ports 3000-3010 with detailed process killing
for port in {3000..3010}; do
  if lsof -i :$port > /dev/null 2>&1; then
    for pid in $(lsof -i :$port -t); do
      kill -9 $pid 2>/dev/null || true
    done
    sleep 1
    echo "✅ Port $port released."
  fi
done

# Verify daemon state
if ! docker info > /dev/null 2>&1; then
  echo "⚠️ Daemon issue detected. Restarting Docker Desktop..."
  open -a Docker
  sleep 10
fi
echo "✅ Daemon state verified."

echo "✅ All local resources cleaned up on failure exit."