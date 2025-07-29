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
#   --local-only    only build and run locally (in Docker),
#                   skip all AWS deploy steps
# ---------------------------------------------------------

LOCAL_ONLY=false
# Default architecture for Lambda (fixed to x86_64 for Lambda compatibility)
PACKAGE_ARCH="x86_64"

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
  echo "🚀 Starting full deployment (local-only)..."

  echo ""
  echo "🧩 Running module: 01_package_lambda.sh"
  bash "$(dirname "$0")/modules/01_package_lambda.sh"

  echo ""
  echo "📦 Building local Docker image for Lambda..."
  DOCKER_PLATFORM="--platform linux/amd64"
  docker build \
    $DOCKER_PLATFORM \
    -f dashboard-app/backend/Dockerfile \
    -t auth-lambda \
    dashboard-app/backend

  echo ""
  echo "🚀 Starting local Lambda container..."
  docker rm -f auth-local 2>/dev/null || true
  docker run -d -p 9000:8080 \
    -e DYNAMO_TABLE=AuthUsers \
    -e DOMAIN=localhost \
    -e COGNITO_USER_POOL_ID=local-pool \
    --name auth-local \
    auth-lambda
  echo "✅ auth-lambda is up on http://localhost:9000"

  echo ""
  echo "🔍 Testing POST /login with initial credentials..."
  curl -s -XPOST http://localhost:9000/2015-03-31/functions/function/invocations \
    -H "Content-Type: application/json" \
    -d '{
      "version":"2.0",
      "routeKey":"POST /login",
      "rawPath":"/login",
      "rawQueryString":"",
      "headers":{"content-type":"application/x-www-form-urlencoded"},
      "requestContext":{"http":{"method":"POST","path":"/login","sourceIp":"127.0.0.1"}},
      "body":"username=testuser&password=InitialPass123!",
      "isBase64Encoded":false
    }' | jq .

  echo ""
  echo "✅ Local-only deployment complete. Test manually with:"
  echo "   curl -v -X POST http://localhost:9000/login -H \"Content-Type: application/x-www-form-urlencoded\" -d 'username=testuser&password=InitialPass123!'"
  echo "   Follow prompts for password change and TOTP setup."
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
export PACKAGE_ARCH

# Version management
TEMPLATE_FILE="template.yml"
VERSION_KEY="Description"
VERSION_DEFAULT="0.01"

# Extract current version or set default
if [ -f "$TEMPLATE_FILE" ]; then
  CURRENT_VERSION=$(awk -F': ' "/^${VERSION_KEY}:/ {print \$2}" "$TEMPLATE_FILE" | grep -oE '[0-9]+\.[0-9]+' || echo "$VERSION_DEFAULT")
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
SECRET_KEY=$(~/dev/dashboard-venv/bin/python -c "import secrets; print(secrets.token_hex(32))" 2>/dev/null)
{
  sed -i.bak "s/^${VERSION_KEY}: .*/${VERSION_KEY}: Authentication API Stack - v${NEW_VERSION} (SECRET_KEY updated)/" "$TEMPLATE_FILE" && rm -f "${TEMPLATE_FILE}.bak"
  sed -i.bak "s/SECRET_KEY: .*/SECRET_KEY: $SECRET_KEY/" "$TEMPLATE_FILE" && rm -f "${TEMPLATE_FILE}.bak"
} > /dev/null 2>&1
unset SECRET_KEY
echo "📝 Updated version in $TEMPLATE_FILE to v${NEW_VERSION} with new SECRET_KEY"

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
  . "$MODULES/$step"
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
    ParameterKey=DomainParam,ParameterValue=$(hostname -f) \
    ParameterKey=CognitoUserPool,UsePreviousValue=true || {
      echo "⚠️ Stack update failed, checking if stack exists..."
      if aws cloudformation describe-stacks --stack-name auth-stack --region us-east-1 >/dev/null 2>&1; then
        echo "ℹ️ Stack exists, attempting update again with full capabilities..."
        aws cloudformation update-stack \
          --stack-name auth-stack \
          --template-body file://template.yml \
          --region us-east-1 \
          --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
          --parameters ParameterKey=UpdateTrigger,ParameterValue=$(date +%s) \
          ParameterKey=DomainParam,ParameterValue=$(hostname -f) \
          ParameterKey=CognitoUserPool,UsePreviousValue=true
      else
        echo "⚠️ Stack does not exist, creating new stack..."
        aws cloudformation create-stack \
          --stack-name auth-stack \
          --template-body file://template.yml \
          --region us-east-1 \
          --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
          --parameters ParameterKey=DomainParam,ParameterValue=$(hostname -f)
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