#!/bin/bash
set -euo pipefail

echo "🔥 Starting full backend teardown..."

LAMBDA_NAME="auth-function"
ROLE_NAME="AuthLambdaRole"
API_NAME="auth-api"
DOCKER_CONTAINER="auth-local"
BUILD_DIR="dashboard-app/backend/build"
ZIP_FILE="auth_backend.zip"

# 🧨 Lambda
aws lambda delete-function --function-name "$LAMBDA_NAME" --region us-east-1 2>/dev/null || true
echo "✅ Deleted Lambda function"

# 🔐 IAM Role
POLICIES=$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query 'AttachedPolicies[*].PolicyArn' --output text --region us-east-1 2>/dev/null || true)
for POLICY in $POLICIES; do
  aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY" --region us-east-1 2>/dev/null || true
done
aws iam delete-role --role-name "$ROLE_NAME" --region us-east-1 2>/dev/null || true
echo "✅ Deleted IAM role"

# 🌐 API Gateway
REST_API_IDS=$(aws apigateway get-rest-apis --query "items[?name=='$API_NAME'].id" --output text --region us-east-1 2>/dev/null || true)
for REST_API_ID in $REST_API_IDS; do
  RESOURCES=$(aws apigateway get-resources --rest-api-id "$REST_API_ID" --query "items[?path!='/'].id" --output text --region us-east-1 2>/dev/null || true)
  for RESOURCE in $RESOURCES; do
    aws apigateway delete-resource --rest-api-id "$REST_API_ID" --resource-id "$RESOURCE" --region us-east-1 2>/dev/null || true
  done
  aws apigateway delete-rest-api --rest-api-id "$REST_API_ID" --region us-east-1 2>/dev/null || true
done
echo "✅ Deleted API Gateway(s)"

# 🐳 Docker cleanup
docker rm -f "$DOCKER_CONTAINER" 2>/dev/null || true
echo "✅ Removed Docker container: $DOCKER_CONTAINER"

# 🧼 Local cleanup
rm -rf "$BUILD_DIR" 2>/dev/null || true
rm -f "$ZIP_FILE" 2>/dev/null || true
echo "✅ Removed local build directory and zip"

echo "✅ Full teardown complete."