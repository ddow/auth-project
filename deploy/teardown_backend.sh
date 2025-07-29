#!/bin/bash
set -euo pipefail

echo "🚀 Starting full backend teardown..."

LAMBDA_NAME="auth-function"
ROLE_NAME="AuthLambdaRole"
API_NAME="auth-api"
DOCKER_CONTAINER="auth-local"
BUILD_DIR="dashboard-app/backend/build"
ZIP_FILE="auth_backend.zip"
STACK_NAME="auth-stack"
REGION="us-east-1"

# Prompt for DB removal option
REMOVE_DB="no"
read -p "Would you like to remove the DynamoDB table (AuthUsers) as well? (yes/no): " REMOVE_DB
if [[ "$REMOVE_DB" == "yes" ]]; then
  read -p "Are you sure you want to remove the DB? This will delete all users and data for ever and ever. (yes/no): " SURE1
  if [[ "$SURE1" == "yes" ]]; then
    read -p "Are you very, very sure you want to remove the DB? This will delete all users and data for ever and ever and you might be very sad! (yes/no): " SURE2
    if [[ "$SURE2" == "yes" ]]; then
      read -p "This is the last time I'm going to ask. Are you very, very, very sure you want to remove the DB? This will delete all users and data for ever and ever and you might be very sad and you could destroy your own future and the future for your children that you may or may not have!! (yes/no): " SURE3
      if [[ "$SURE3" == "yes" ]]; then
        echo "🔥 Proceeding to remove DynamoDB table AuthUsers..."
        aws dynamodb delete-table --table-name AuthUsers --region "$REGION" || echo "⚠️ Failed to delete DynamoDB table, may not exist."
      else
        echo "ℹ️ DB removal aborted."
      fi
    else
      echo "ℹ️ DB removal aborted."
    fi
  else
    echo "ℹ️ DB removal aborted."
  fi
else
  echo "ℹ️ Keeping DynamoDB table AuthUsers intact."
fi

# Teardown AWS resources
echo "🔥 Removing individual AWS resources..."

# 🧨 Lambda
aws lambda delete-function --function-name "$LAMBDA_NAME" --region "$REGION" 2>/dev/null || true
echo "✅ Deleted Lambda function"

# 🔐 IAM Role
POLICIES=$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query 'AttachedPolicies[*].PolicyArn' --output text --region "$REGION" 2>/dev/null || true)
for POLICY in $POLICIES; do
  aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY" --region "$REGION" 2>/dev/null || true
done
aws iam delete-role --role-name "$ROLE_NAME" --region "$REGION" 2>/dev/null || true
echo "✅ Deleted IAM role"

# 🌐 API Gateway
REST_API_IDS=$(aws apigateway get-rest-apis --query "items[?name=='$API_NAME'].id" --output text --region "$REGION" 2>/dev/null || true)
for REST_API_ID in $REST_API_IDS; do
  RESOURCES=$(aws apigateway get-resources --rest-api-id "$REST_API_ID" --query "items[?path!='/'].id" --output text --region "$REGION" 2>/dev/null || true)
  for RESOURCE in $RESOURCES; do
    aws apigateway delete-resource --rest-api-id "$REST_API_ID" --resource-id "$RESOURCE" --region "$REGION" 2>/dev/null || true
  done
  aws apigateway delete-rest-api --rest-api-id "$REST_API_ID" --region "$REGION" 2>/dev/null || true
done
echo "✅ Deleted API Gateway(s)"

# 🐳 Docker cleanup
docker rm -f "$DOCKER_CONTAINER" 2>/dev/null || true
echo "✅ Removed Docker container: $DOCKER_CONTAINER"

# 🧼 Local cleanup
rm -rf "$BUILD_DIR" 2>/dev/null || true
rm -f "$ZIP_FILE" 2>/dev/null || true
echo "✅ Removed local build directory and zip"

# 🏭 Delete CloudFormation stack (handles Cognito and other stack resources)
echo "🔥 Deleting CloudFormation stack $STACK_NAME..."
aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION" 2>/dev/null || echo "⚠️ Stack deletion failed, may not exist."
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION" 2>/dev/null || echo "ℹ️ Stack may not have existed or already deleted."
echo "✅ Deleted CloudFormation stack"

echo "✅ Full teardown complete."