#!/usr/bin/env bash
set -euo pipefail

echo "📁 Step 6: Wiring /public/{proxy+} route..."
REST_API_ID=$(aws apigateway get-rest-apis --query "items[?name=='$API_NAME'].id" --output text --region us-east-1)
echo "🔧 Using REST_API_ID from previous step: $REST_API_ID"

# Create /public base resource
PUBLIC_RESOURCE_ID=$(aws apigateway create-resource --rest-api-id "$REST_API_ID" --parent-id $(aws apigateway get-resources --rest-api-id "$REST_API_ID" --region us-east-1 --query "items[?path=='/'].id" --output text) --path-part "public" --region us-east-1 --query 'id' --output text 2>/dev/null || true)
echo "🆕 Creating /public base resource..."

# Create /public/{proxy+} resource
PROXY_PUBLIC_ID=$(aws apigateway create-resource --rest-api-id "$REST_API_ID" --parent-id "$PUBLIC_RESOURCE_ID" --path-part "{proxy+}" --region us-east-1 --query 'id' --output text 2>/dev/null || true)
echo "🆕 Creating /public/{proxy+} resource..."

# Configure method
aws apigateway put-method --rest-api-id "$REST_API_ID" --resource-id "$PROXY_PUBLIC_ID" --http-method ANY --authorization-type NONE --api-key-required false --region us-east-1 2>/dev/null || true
echo "{ \"httpMethod\": \"ANY\", \"authorizationType\": \"NONE\", \"apiKeyRequired\": false }"

# Configure integration
aws apigateway put-integration --rest-api-id "$REST_API_ID" --resource-id "$PROXY_PUBLIC_ID" --http-method ANY --type AWS_PROXY --integration-http-method POST --uri "arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:${AWS_ACCOUNT_ID}:function:${LAMBDA_NAME}/invocations" --passthrough-behavior WHEN_NO_MATCH --timeout-in-millis 29000 --region us-east-1 2>/dev/null || true
echo "{ \"type\": \"AWS_PROXY\", \"httpMethod\": \"POST\", \"uri\": \"arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:${AWS_ACCOUNT_ID}:function:${LAMBDA_NAME}/invocations\", \"passthroughBehavior\": \"WHEN_NO_MATCH\", \"timeoutInMillis\": 29000, \"cacheNamespace\": \"$PROXY_PUBLIC_ID\", \"cacheKeyParameters\": [] }"

# Add permission for API Gateway to invoke Lambda
aws lambda add-permission --function-name "$LAMBDA_NAME" --statement-id "publicproxy-$(date +%s)" --action lambda:InvokeFunction --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:us-east-1:${AWS_ACCOUNT_ID}:${REST_API_ID}/*/*/public/*" --region us-east-1 2>/dev/null || true
echo "{ \"Statement\": \"{\\\"Sid\\\":\\\"publicproxy-$(date +%s)\\\",\\\"Effect\\\":\\\"Allow\\\",\\\"Principal\\\":{\\\"Service\\\":\\\"apigateway.amazonaws.com\\\"},\\\"Action\\\":\\\"lambda:InvokeFunction\\\",\\\"Resource\\\":\\\"arn:aws:lambda:us-east-1:${AWS_ACCOUNT_ID}:function:${LAMBDA_NAME}\\\",\\\"Condition\\\":{\\\"ArnLike\\\":{\\\"AWS:SourceArn\\\":\\\"arn:aws:execute-api:us-east-1:${AWS_ACCOUNT_ID}:${REST_API_ID}/*/*/public/*\\\"}}}\" }"
echo "✅ Wired /public/{proxy+} route successfully."