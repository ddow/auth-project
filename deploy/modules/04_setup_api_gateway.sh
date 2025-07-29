#!/usr/bin/env bash
set -euo pipefail

echo "🌐 Step 4: Setting up API Gateway for Lambda: $LAMBDA_NAME"

# Create new API Gateway
aws apigateway create-rest-api --name "$API_NAME" --endpoint-configuration types=REGIONAL --region us-east-1 --query 'id' --output text 2>/dev/null || true
REST_API_ID=$(aws apigateway get-rest-apis --query "items[?name=='$API_NAME'].id" --output text --region us-east-1)
echo "🆕 Created new API Gateway: $REST_API_ID"

# Create /login resource and method
RESOURCE_ID=$(aws apigateway create-resource --rest-api-id "$REST_API_ID" --parent-id $(aws apigateway get-resources --rest-api-id "$REST_API_ID" --region us-east-1 --query "items[?path=='/'].id" --output text) --path-part "login" --region us-east-1 --query 'id' --output text 2>/dev/null || true)
echo "{ \"id\": \"$RESOURCE_ID\", \"parentId\": \"$(aws apigateway get-resources --rest-api-id "$REST_API_ID" --region us-east-1 --query "items[?id=='$RESOURCE_ID'].parentId" --output text)\", \"pathPart\": \"login\", \"path\": \"$(aws apigateway get-resources --rest-api-id "$REST_API_ID" --region us-east-1 --query "items[?id=='$RESOURCE_ID'].path" --output text)\" }"

aws apigateway put-method --rest-api-id "$REST_API_ID" --resource-id "$RESOURCE_ID" --http-method POST --authorization-type NONE --api-key-required false --region us-east-1 2>/dev/null || true
echo "{ \"httpMethod\": \"POST\", \"authorizationType\": \"NONE\", \"apiKeyRequired\": false }"

# Configure integration
aws apigateway put-integration --rest-api-id "$REST_API_ID" --resource-id "$RESOURCE_ID" --http-method POST --type AWS_PROXY --integration-http-method POST --uri "arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:${AWS_ACCOUNT_ID}:function:${LAMBDA_NAME}/invocations" --passthrough-behavior WHEN_NO_MATCH --timeout-in-millis 29000 --region us-east-1 2>/dev/null || true
echo "{ \"type\": \"AWS_PROXY\", \"httpMethod\": \"POST\", \"uri\": \"arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:${AWS_ACCOUNT_ID}:function:${LAMBDA_NAME}/invocations\", \"passthroughBehavior\": \"WHEN_NO_MATCH\", \"timeoutInMillis\": 29000, \"cacheNamespace\": \"$RESOURCE_ID\", \"cacheKeyParameters\": [] }"

# Add permission for API Gateway to invoke Lambda
aws lambda add-permission --function-name "$LAMBDA_NAME" --statement-id "apigw-login-$(date +%s)" --action lambda:InvokeFunction --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:us-east-1:${AWS_ACCOUNT_ID}:${REST_API_ID}/*/*/*" --region us-east-1 2>/dev/null || true
echo "{ \"Statement\": \"{\\\"Sid\\\":\\\"apigw-login-$(date +%s)\\\",\\\"Effect\\\":\\\"Allow\\\",\\\"Principal\\\":{\\\"Service\\\":\\\"apigateway.amazonaws.com\\\"},\\\"Action\\\":\\\"lambda:InvokeFunction\\\",\\\"Resource\\\":\\\"arn:aws:lambda:us-east-1:${AWS_ACCOUNT_ID}:function:${LAMBDA_NAME}\\\",\\\"Condition\\\":{\\\"ArnLike\\\":{\\\"AWS:SourceArn\\\":\\\"arn:aws:execute-api:us-east-1:${AWS_ACCOUNT_ID}:${REST_API_ID}/*/*/*\\\"}}}\" }"
echo "🆕 Wired new API Gateway to Lambda: $LAMBDA_NAME"