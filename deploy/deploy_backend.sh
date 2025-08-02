#!/usr/bin/env bash
# Ensure this script runs in Bash
if [ -z "$BASH_VERSION" ]; then
  echo "Error: This script must be run with Bash. Use: bash $0"
  exit 1
fi

set -euo pipefail

# ---------------------------------------------------------
# deploy/deploy_backend.sh
#
# Usage:
#   ./deploy/deploy_backend.sh [--local-only]
#
# Flags:
#   --local-only    only build and run locally (using SAM CLI) with automated tests,
#                   skip all AWS deploy steps
# ---------------------------------------------------------

# Determine the script's root directory once
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LOCAL_ONLY=false

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local-only)
      LOCAL_ONLY=true
      shift
      ;;
    *)
      echo "❌ Unknown flag: $1"
      exit 1
      ;;
  esac
done

# Export LOCAL_ONLY for subprocesses (optional backup)
export LOCAL_ONLY

# Cleanup function (deferred to the end)
cleanup() {
  echo "Executing final cleanup of all resources..."
  if $LOCAL_ONLY; then
    if [ -f /tmp/dynamo_pid ]; then
      docker stop $(cat /tmp/dynamo_pid) 2>/dev/null || true
      docker rm $(cat /tmp/dynamo_pid) 2>/dev/null || true
      rm -f /tmp/dynamo_pid
      echo "✅ DynamoDB container cleanup completed."
    fi
    kill $(pgrep -f "sam local start-api") 2>/dev/null || true
    echo "✅ SAM API process cleanup attempted."

    echo "Removing all containers..."
    docker stop $(docker ps -a -q) 2>/dev/null || true
    docker rm $(docker ps -a -q) 2>/dev/null || true
    echo "✅ All containers removed."

    echo "Removing all images..."
    docker rmi -f $(docker images -q) 2>/dev/null || true
    echo "✅ All images removed."

    echo "Releasing ports 8000, 3000, 3001..."
    for port in 8000 3000 3001; do
      if lsof -i :$port > /dev/null 2>&1; then
        lsof -i :$port -t | xargs kill -9 2>/dev/null || true
        sleep 1
        echo "✅ Port $port released."
      fi
    done

    echo "Verifying daemon state..."
    if ! docker info > /dev/null 2>&1; then
      echo "⚠️ Daemon issue detected. Restarting Docker Desktop..."
      open -a Docker
      sleep 10
    fi
    echo "✅ Daemon state verified."

    echo "Removing temporary files..."
    ls /tmp/dynamo_pid 2>/dev/null && rm -f /tmp/dynamo_pid
    echo "✅ Temporary files cleaned."
  fi

  echo "✅ All local resources cleaned up on final exit."
}

# Step 1: Build the SAM Project
echo "🧩 Running sam build..."
sam build

# Validate build output
echo "🧩 Validating build output..."
if [ ! -f .aws-sam/build/AuthFunction/main.py ]; then
  echo "❌ Error: main.py not found in .aws-sam/build/AuthFunction. Check CodeUri in template.yaml."
  exit 1
fi
echo "✅ Build output validated: main.py present."

# Common step: Package the Lambda Function
echo "🧩 Running module: 01_package_lambda.sh"
bash "${SCRIPT_DIR}/deploy/modules/01_package_lambda.sh" "$LOCAL_ONLY"

if $LOCAL_ONLY; then
  echo "🚀 Starting full local deployment with automated tests using SAM CLI..."

  # Step 3: Create Configuration File
  echo "🧩 Running module: 03_create_env_json.sh"
  bash "${SCRIPT_DIR}/deploy/modules/03_create_env_json.sh" "$LOCAL_ONLY"

  # Step 4: Setup DynamoDB (local or remote)
  echo "🧩 Running module: 04_setup_dynamodb.sh"
  bash "${SCRIPT_DIR}/deploy/modules/04_setup_dynamodb.sh" "$LOCAL_ONLY" --keep-container  # Keep container running

  # Step 5: Manage API (local startup or remote config)
  echo "🧩 Running module: 05_manage_api.sh"
  bash "${SCRIPT_DIR}/deploy/modules/05_manage_api.sh" "$LOCAL_ONLY" &
  SAM_PID=$!
  echo "✅ SAM API process started with PID: $SAM_PID"

  if $LOCAL_ONLY; then
    # Wait for API readiness with curl check instead of sleep
    echo "Waiting for API to be ready at http://localhost:3000/health..."
    until curl -s -f -o /dev/null "http://localhost:3000/health"; do
      sleep 1
    done
    echo "API is ready."
    echo "✅ auth-lambda is up on http://localhost:3000"
  fi

  # Check if SAM is running for local mode
  if $LOCAL_ONLY && ! ps -p $SAM_PID > /dev/null; then
    echo "❌ Failed to start SAM local API."
    if [ -f /tmp/dynamo_pid ]; then
      echo "Cleaning up DynamoDB container due to API failure..."
      docker stop $(cat /tmp/dynamo_pid) 2>/dev/null || true
      docker rm $(cat /tmp/dynamo_pid) 2>/dev/null || true
      rm -f /tmp/dynamo_pid
      echo "✅ DynamoDB cleanup attempted."
    fi
    exit 1
  fi

  # Step 6: Run Automated Tests (only for local)
  if $LOCAL_ONLY; then
    echo "🧩 Running module: 06_run_tests.sh"
    bash "${SCRIPT_DIR}/deploy/modules/06_run_tests.sh" "$LOCAL_ONLY"
  fi
else
  echo "🚀 Starting full deployment with teardown…"

  # Perform complete teardown (only at the end for remote)
  echo "🔥 Initiating final teardown of existing resources…"
  "${SCRIPT_DIR}/deploy/teardown_backend.sh" "$LOCAL_ONLY"

  # Run deployment modules
  for step in \
    04_setup_dynamodb.sh \
    05_manage_api.sh \
    07_deploy_lambda.sh \
    08_update_version.sh \
    09_cloudformation_deploy.sh
  do
    echo ""
    echo "🧩 Running module: $step"
    bash "${SCRIPT_DIR}/deploy/modules/$step" "$LOCAL_ONLY" || {
      echo "❌ Module $step failed. Aborting deployment."
      exit 1
    }
  done
fi

# Call cleanup only after all steps are complete
cleanup

echo ""
echo "✅ Full deployment completed."