#!/usr/bin/env bash
set -euo pipefail

echo "🚀 Step 7: Deploying API Gateway..."
REST_API_ID=$(aws apigateway get-rest-apis --query "items[?name=='$API_NAME'].id" --output text --region us-east-1)
echo "🔧 Using REST_API_ID from previous step: $REST_API_ID"

# Deploy API to 'prod' stage
aws apigateway create-deployment --rest-api-id "$REST_API_ID" --stage-name prod --region us-east-1 --query 'id' --output text 2>/dev/null || true
echo "{ \"id\": \"$(aws apigateway create-deployment --rest-api-id "$REST_API_ID" --stage-name prod --region us-east-1 --query 'id' --output text)\", \"createdDate\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" }"

# Get the API URL
API_URL=$(aws apigateway get-stages --rest-api-id "$REST_API_ID" --region us-east-1 --query "items[?stageName=='prod'].invokeUrl" --output text 2>/dev/null || true)
echo "🌎 API URL: $API_URL"
echo "✅ API Gateway deployed."