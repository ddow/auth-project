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

# Step 1: Package the Lambda Function (run once for both modes)
echo "🧩 Running module: 01_package_lambda.sh"
bash "${SCRIPT_DIR}/deploy/modules/01_package_lambda.sh"

if $LOCAL_ONLY; then
  echo "🚀 Starting full local deployment with automated tests using SAM CLI..."

  # Step 2: Build the SAM Project
  echo "📦 Building SAM project..."
  sam build || {
    echo "❌ SAM build failed."
    exit 1
  }

  # Step 3: Create Configuration File
  echo "🚀 Preparing configuration file for SAM..."
  # Note: IS_LOCAL is set to "true" to ensure local testing behavior
  cat > "${SCRIPT_DIR}/env.json" << EOF
{
  "AuthFunction": {
    "DYNAMO_TABLE": "AuthUsers",
    "DOMAIN": "localhost",
    "COGNITO_USER_POOL_ID": "local-pool",
    "COGNITO_CLIENT_ID": "testclientid",
    "JWT_SECRET": "your-secret-key",
    "IS_LOCAL": "true",
    "AWS_SAM_LOCAL": "true"
  }
}
EOF

  # Verify the file (optional debug)
  if [ ! -f "${SCRIPT_DIR}/env.json" ]; then
    echo "❌ Error: env.json was not created."
    exit 1
  fi
  echo "✅ Configuration file created at ${SCRIPT_DIR}"

  # Validate JSON (optional debug)
  if ! jq -e . "${SCRIPT_DIR}/env.json" > /dev/null 2>&1; then
    echo "❌ Error: env.json contains invalid JSON."
    exit 1
  fi

  # Step 4: Start the Local API
  echo "🚀 Starting local API with SAM..."
  CONTAINER_ENV_PATH="${SCRIPT_DIR}/env.json"  # Use the same file for container env vars
  echo "Using container env path: $CONTAINER_ENV_PATH"
  PORT=3000
  # Check if port is in use and try an alternative if needed
  if lsof -i :$PORT > /dev/null 2>&1; then
    echo "⚠️ Port $PORT is in use. Trying port 3001..."
    PORT=3001
  fi
  sam local start-api --docker-network host --env-vars "${SCRIPT_DIR}/env.json" --port $PORT --debug --container-env-vars "$CONTAINER_ENV_PATH" &
  SAM_PID=$!
  sleep 10  # Wait for API to stabilize

  # Check if SAM is running
  if ! ps -p $SAM_PID > /dev/null; then
    echo "❌ Failed to start SAM local API."
    exit 1
  fi
  echo "✅ auth-lambda is up on http://localhost:$PORT"

  # Step 5: Run Automated Tests
  echo "🔍 Running automated tests..."

  # Test 1: Initial Login
  echo "🧪 Test 1: Initial Login"
  LOGIN_RESPONSE=$(curl -s -X POST http://localhost:$PORT/login \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d 'username=test@example.com&password=InitialPass123!')
  if [[ "$(echo "$LOGIN_RESPONSE" | jq -r '.message' 2>/dev/null)" == "First login detected. Please change your password." &&
        "$(echo "$LOGIN_RESPONSE" | jq -r '.requires_change' 2>/dev/null)" == "true" &&
        "$(echo "$LOGIN_RESPONSE" | jq -r '.token' 2>/dev/null)" == "null" ]]; then
    echo "✅ Test 1 Passed: Initial login detected."
  else
    echo "❌ Test 1 Failed: Expected {\"message\":\"First login detected. Please change your password.\",\"requires_change\":true,\"token\":null}, got: $LOGIN_RESPONSE"
    kill $SAM_PID 2>/dev/null || true
    exit 1
  fi

  # Test 2: Change Password
  echo "🧪 Test 2: Change Password"
  CHANGE_RESPONSE=$(curl -s -X POST http://localhost:$PORT/change-password \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d 'username=test@example.com&old_password=InitialPass123!&new_password=NewPass123!')
  if [[ "$(echo "$CHANGE_RESPONSE" | jq -r '.message' 2>/dev/null)" == "Password changed. Proceed to TOTP setup." ]]; then
    echo "✅ Test 2 Passed: Password changed."
  else
    echo "❌ Test 2 Failed: Expected {\"message\":\"Password changed. Proceed to TOTP setup.\"}, got: $CHANGE_RESPONSE"
    kill $SAM_PID 2>/dev/null || true
    exit 1
  fi

  # Test 3: Setup TOTP
  echo "🧪 Test 3: Setup TOTP"
  TOTP_SECRET=$(echo "$CHANGE_RESPONSE" | jq -r '.totp_secret' 2>/dev/null)
  if [ -n "$TOTP_SECRET" ]; then
    TOTP_CODE=$(python3 -c "import pyotp; print(pyotp.TOTP('$TOTP_SECRET').now())" 2>/dev/null || echo "123456")
    TOTP_RESPONSE=$(curl -s -X POST http://localhost:$PORT/setup-totp \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "username=test@example.com&totp_code=$TOTP_CODE&token=dummy-jwt-token")
    if [[ "$(echo "$TOTP_RESPONSE" | jq -r '.message' 2>/dev/null)" == "TOTP setup complete. Proceed to biometric setup." ]]; then
      echo "✅ Test 3 Passed: TOTP setup complete."
    else
      echo "❌ Test 3 Failed: Expected {\"message\":\"TOTP setup complete. Proceed to biometric setup.\"}, got: $TOTP_RESPONSE"
      kill $SAM_PID 2>/dev/null || true
      exit 1
    fi
  else
    echo "❌ Test 3 Failed: Could not extract TOTP secret."
    kill $SAM_PID 2>/dev/null || true
    exit 1
  fi

  # Test 4: Setup Biometric
  echo "🧪 Test 4: Setup Biometric"
  BIOMETRIC_RESPONSE=$(curl -s -X POST http://localhost:$PORT/setup-biometric \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=test@example.com&token=dummy-jwt-token")
  if [[ "$(echo "$BIOMETRIC_RESPONSE" | jq -r '.message' 2>/dev/null)" == "Biometric setup complete. Login with biometrics next time." ]]; then
    echo "✅ Test 4 Passed: Biometric setup complete."
  else
    echo "❌ Test 4 Failed: Expected {\"message\":\"Biometric setup complete. Login with biometrics next time.\"}, got: $BIOMETRIC_RESPONSE"
    kill $SAM_PID 2>/dev/null || true
    exit 1
  fi

  echo ""
  echo "✅ All local tests passed successfully."
  echo "SAM CLI is still running for manual testing. Press Ctrl+C to stop or run: kill $SAM_PID"
  wait $SAM_PID 2>/dev/null || true
  exit 0
fi

# —————————————————————————————————————————————————————————
# No --local-only: do the full AWS deploy with teardown first
# —————————————————————————————————————————————————————————

echo "🚀 Starting full deployment with teardown…"

# Perform complete teardown before deployment
echo "🔥 Initiating teardown of existing resources…"
"${SCRIPT_DIR}/deploy/teardown_backend.sh"

echo "🚀 Proceeding with deployment…"

export LAMBDA_NAME="auth-function"
export ZIP_FILE="auth_backend.zip"
export ROLE_NAME="AuthLambdaRole"
export POLICY_ARN="arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
export BUILD_DIR="dashboard-app/backend/build"
export API_NAME="auth-api"

# Version management
TEMPLATE_FILE="template.yml"
VERSION_KEY="Description"
VERSION_DEFAULT="0.01"

# Extract current version or set default
if [ -f "$TEMPLATE_FILE" ]; then
  CURRENT_VERSION=$(grep "^${VERSION_KEY}:" "$TEMPLATE_FILE" | sed 's/.*v\([0-9]\+\.[0-9]\+\).*/\1/' || echo "$VERSION_DEFAULT")
  if [ -z "$CURRENT_VERSION" ]; then
    CURRENT_VERSION="$VERSION_DEFAULT"
  fi
else
  CURRENT_VERSION="$VERSION_DEFAULT"
fi

# Increment version
VERSION_NUM=$(echo "$CURRENT_VERSION" | awk -F'.' '{print $1*100 + $2}' | bc)
NEW_VERSION_NUM=$((VERSION_NUM + 1))
NEW_VERSION=$(printf "%.2f" "$(echo "$NEW_VERSION_NUM/100" | bc -l))

# Generate a new SECRET_KEY securely and update template.yml
SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
sed -i.bak "s/^${VERSION_KEY}: .*/${VERSION_KEY}: Authentication API Stack - v${NEW_VERSION} (SECRET_KEY: ${SECRET_KEY})/" "$TEMPLATE_FILE" && rm -f "${TEMPLATE_FILE}.bak"
echo "📝 Updated version in $TEMPLATE_FILE to v${NEW_VERSION} with new SECRET_KEY: ${SECRET_KEY}"

# Run deployment modules
for step in \
  02_create_iam_role.sh \
  03_deploy_lambda.sh \
  04_setup_api_gateway.sh \
  05_wire_proxy_route.sh \
  06_wire_public_proxy.sh \
  07_deploy_api_gateway.sh
do
  echo ""
  echo "🧩 Running module: $step"
  . "${SCRIPT_DIR}/deploy/modules/$step" || {
    echo "❌ Module $step failed. Aborting deployment."
    exit 1
  }
done

# Update CloudFormation stack with the new version
if [ "$DRY_RUN" != "true" ]; then
  echo "🔄 Updating CloudFormation stack with new version..."
  aws cloudformation deploy \
    --stack-name auth-stack \
    --template-file "$TEMPLATE_FILE" \
    --region us-east-1 \
    --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
    --parameter-overrides UpdateTrigger=$(date +%s) JwtSecretParameter="${SECRET_KEY}" \
    --no-fail-on-empty-changeset
  echo "✅ CloudFormation stack updated or created."
fi

echo ""
echo "✅ Full deployment completed."