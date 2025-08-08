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
#   --local-only    only run locally (using SAM CLI) with automated tests,
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

# Trap for cleanup on failure
trap 'cleanup_on_failure' ERR

# Cleanup on failure function
cleanup_on_failure() {
  if [ $LOCAL_ONLY = true ]; then
    echo "Deployment failed, initiating cleanup..."
    bash "${SCRIPT_DIR}/deploy/modules/cleanup_local.sh"
  fi
  exit 1
}

# Step 1: Build the SAM Project
echo "🧩 Running module: sam_build.sh"
bash "${SCRIPT_DIR}/deploy/modules/sam_build.sh"

# Validate build output
echo "🧩 Validating build output..."
if [ ! -f dashboard-app/backend/main.py ] && [ ! -f .aws-sam/build/AuthFunction/main.py ]; then
  echo "❌ Error: main.py not found in dashboard-app/backend or .aws-sam/build/AuthFunction. Check source files or Makefile output."
  exit 1
fi
echo "✅ Build output validated: main.py present."

if $LOCAL_ONLY; then
  echo "🚀 Starting full local deployment with automated tests..."

  # Start LocalStack for Secrets Manager
  echo "🧩 Starting LocalStack..."
  localstack start -d
  export LOCALSTACK_HOST=localhost
  export AWS_DEFAULT_REGION=us-east-1
  echo "✅ LocalStack environment configured."

  # Step 2: Create Configuration File
  echo "🧩 Running module: create_env_json.sh"
  bash "${SCRIPT_DIR}/deploy/modules/create_env_json.sh" "$LOCAL_ONLY"

  # Step 3: Setup LocalStack Secret
  echo "🧩 Running module: setup_secretsmanager.sh"
  bash "${SCRIPT_DIR}/deploy/modules/setup_secretsmanager.sh" "$LOCAL_ONLY"

  # Step 4: Manage API (local startup)
  echo "🧩 Running module: manage_api.sh"
  bash "${SCRIPT_DIR}/deploy/modules/manage_api.sh" "$LOCAL_ONLY" &
  SAM_PID=$!
  echo "✅ SAM API process started with PID: $SAM_PID"

  # Wait for API readiness with timeout (90 seconds)
  echo "Waiting for API to be ready at http://localhost:3000/health..."
  TIMEOUT=90
  COUNTER=0
  until curl -s -f -o /dev/null "http://localhost:3000/health"; do
    sleep 1
    COUNTER=$((COUNTER + 1))
    if [ $COUNTER -ge $TIMEOUT ]; then
      echo "❌ API readiness timeout after $TIMEOUT seconds."
      exit 1
    fi
  done
  echo "API is ready."
  echo "✅ auth-lambda is up on http://localhost:3000"

  # Check if SAM is running
  if ! ps -p $SAM_PID > /dev/null; then
    echo "❌ Failed to start SAM local API."
    exit 1
  fi

  # Step 5: Run Automated Tests
  echo "🧩 Running module: run_tests.sh"
  bash "${SCRIPT_DIR}/deploy/modules/run_tests.sh" "$LOCAL_ONLY"
else
  echo "🚀 Starting full production deployment..."

  # Perform complete teardown (only at the end for remote)
  echo "🔥 Initiating final teardown of existing resources..."
  "${SCRIPT_DIR}/deploy/teardown_backend.sh" "$LOCAL_ONLY"

  # Deploy the stack with SAM
  echo "🧩 Deploying with SAM..."
  sam deploy \
    --template-file .aws-sam/build/template.yml \
    --stack-name auth-project-stack \
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
    --parameter-overrides Environment=prod \
    --no-fail-on-empty-changeset || {
      echo "❌ SAM deployment failed."
      exit 1
    }
fi

echo ""
echo "✅ Deployment completed. Local environment remains active for further use."