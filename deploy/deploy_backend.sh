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

LOCAL_ONLY=false

# parse flags
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

if $LOCAL_ONLY; then
  echo "🚀 Starting full local deployment with automated tests using SAM CLI..."

  echo ""
  echo "🧩 Running module: 01_package_lambda.sh"
  bash "$(dirname "$0")/modules/01_package_lambda.sh"

  echo ""
  echo "📦 Building SAM project..."
  sam build || {
    echo "❌ SAM build failed."
    exit 1
  }

  echo ""
  echo "🚀 Starting local API with SAM..."
  # Create env.json for SAM
  cat > env.json << EOF
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

  # Start SAM local API in the background
  sam local start-api --docker-network host --env-vars env.json --port 3000 --debug --container-env-vars "{\"IS_LOCAL\":\"true\",\"AWS_SAM_LOCAL\":\"true\",\"DYNAMO_TABLE\":\"AuthUsers\",\"DOMAIN\":\"localhost\",\"COGNITO_USER_POOL_ID\":\"local-pool\",\"COGNITO_CLIENT_ID\":\"testclientid\",\"JWT_SECRET\":\"your-secret-key\"}" &
  SAM_PID=$!
  sleep 10  # Increased wait time for API to stabilize

  # Check if SAM is running
  if ! ps -p $SAM_PID > /dev/null; then
    echo "❌ Failed to start SAM local API."
    exit 1
  fi
  echo "✅ auth-lambda is up on http://localhost:3000"

  # Automated Tests
  echo ""
  echo "🔍 Running automated tests..."

  # Test 1: Initial Login
  echo "🧪 Test 1: Initial Login"
  LOGIN_RESPONSE=$(curl -s -X POST http://localhost:3000/login \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d 'username=test@example.com&password=InitialPass123!')
  if [[ "$(echo "$LOGIN_RESPONSE" | jq -r '.message')" == "First login detected. Please change your password." &&
        "$(echo "$LOGIN_RESPONSE" | jq -r '.requires_change')" == "true" &&
        "$(echo "$LOGIN_RESPONSE" | jq -r '.token')" == "null" ]]; then
    echo "✅ Test 1 Passed: Initial login detected."
  else
    echo "❌ Test 1 Failed: Expected {\"message\":\"First login detected. Please change your password.\",\"requires_change\":true,\"token\":null}, got: $LOGIN_RESPONSE"
    kill $SAM_PID 2>/dev/null || true
    exit 1
  fi

  # Test 2: Change Password
  echo "🧪 Test 2: Change Password"
  CHANGE_RESPONSE=$(curl -s -X POST http://localhost:3000/change-password \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d 'username=test@example.com&old_password=InitialPass123!&new_password=NewPass123!')
  if [[ "$(echo "$CHANGE_RESPONSE" | jq -r '.message')" == "Password changed. Proceed to TOTP setup." ]]; then
    echo "✅ Test 2 Passed: Password changed."
  else
    echo "❌ Test 2 Failed: Expected {\"message\":\"Password changed. Proceed to TOTP setup.\"}, got: $CHANGE_RESPONSE"
    kill $SAM_PID 2>/dev/null || true
    exit 1
  fi

  # Test 3: Setup TOTP
  echo "🧪 Test 3: Setup TOTP"
  TOTP_SECRET=$(echo "$LOGIN_RESPONSE" | jq -r '.message' | grep -o 'Use secret: [A-Z0-9]*' | cut -d' ' -f3)
  if [ -n "$TOTP_SECRET" ]; then
    TOTP_CODE=$(python3 -c "import pyotp; print(pyotp.TOTP('$TOTP_SECRET').now())" 2>/dev/null || echo "123456")
    TOTP_RESPONSE=$(curl -s -X POST http://localhost:3000/setup-totp \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "username=test@example.com&totp_code=$TOTP_CODE&token=dummy-jwt-token")
    if [[ "$(echo "$TOTP_RESPONSE" | jq -r '.message')" == "TOTP setup complete. Proceed to biometric setup." ]]; then
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
  BIOMETRIC_RESPONSE=$(curl -s -X POST http://localhost:3000/setup-biometric \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=test@example.com&token=dummy-jwt-token")
  if [[ "$(echo "$BIOMETRIC_RESPONSE" | jq -r '.message')" == "Biometric setup complete. Login with biometrics next time." ]]; then
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
"$(dirname "$0")/teardown_backend.sh"

echo "🚀 Proceeding with deployment…"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES="$SCRIPT_DIR/modules"

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
NEW_VERSION=$(printf "%.2f" "$(echo "$NEW_VERSION_NUM/100" | bc -l)")

# Generate a new SECRET_KEY securely and update template.yml
SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
sed -i.bak "s/^${VERSION_KEY}: .*/${VERSION_KEY}: Authentication API Stack - v${NEW_VERSION} (SECRET_KEY: ${SECRET_KEY})/" "$TEMPLATE_FILE" && rm -f "${TEMPLATE_FILE}.bak"
echo "📝 Updated version in $TEMPLATE_FILE to v${NEW_VERSION} with new SECRET_KEY: ${SECRET_KEY}"

# Run deployment modules
for step in \
  01_package_lambda.sh \
  02_create_iam_role.sh \
  03_deploy_lambda.sh \
  04_setup_api_gateway.sh \
  05_wire_proxy_route.sh \
  06_wire_public_proxy.sh \
  07_deploy_api_gateway.sh
do
  echo ""
  echo "🧩 Running module: $step"
  . "$MODULES/$step" || {
    echo "❌ Module $step failed. Aborting deployment."
    exit 1
  }
done

# Update CloudFormation stack with the new version
if [ "$DRY_RUN" != "true" ]; then
  echo "🔄 Updating CloudFormation stack with new version..."
  aws cloudformation update-stack \
    --stack-name auth-stack \
    --template-body file://template.yml \
    --region us-east-1 \
    --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
    --parameters ParameterKey=UpdateTrigger,ParameterValue=$(date +%s) \
    ParameterKey=JwtSecretParameter,ParameterValue="${SECRET_KEY}" \
    || {
      echo "⚠️ Stack update failed, checking if stack exists..."
      if aws cloudformation describe-stacks --stack-name auth-stack --region us-east-1 >/dev/null 2>&1; then
        echo "ℹ️ Stack exists, attempting update again with full capabilities..."
        aws cloudformation update-stack \
          --stack-name auth-stack \
          --template-body file://template.yml \
          --region us-east-1 \
          --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
          --parameters ParameterKey=UpdateTrigger,ParameterValue=$(date +%s) \
          ParameterKey=JwtSecretParameter,ParameterValue="${SECRET_KEY}"
      else
        echo "⚠️ Stack does not exist, creating new stack..."
        aws cloudformation create-stack \
          --stack-name auth-stack \
          --template-body file://template.yml \
          --region us-east-1 \
          --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
          --parameters ParameterKey=UpdateTrigger,ParameterValue=$(date +%s) \
          ParameterKey=JwtSecretParameter,ParameterValue="${SECRET_KEY}"
      fi
    }
  aws cloudformation wait stack-create-complete --stack-name auth-stack --region us-east-1 || {
    echo "⚠️ Stack creation failed. Check status..."
    aws cloudformation describe-stack-events --stack-name auth-stack --region us-east-1
    exit 1
  }
  echo "✅ CloudFormation stack updated or created."
fi

echo ""
echo "✅ Full deployment completed."