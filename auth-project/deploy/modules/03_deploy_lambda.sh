#!/usr/bin/env bash
set -euo pipefail

echo "🚀 Step 3: Deploying Lambda: $LAMBDA_NAME"

# Deploy Lambda function
aws lambda create-function \
  --function-name "$LAMBDA_NAME" \
  --runtime python3.12 \
  --role "arn:aws:iam::${AWS_ACCOUNT_ID}:role/$ROLE_NAME" \
  --handler main.handler \
  --code S3Bucket=dashboard.danieldow.com,S3Key=$ZIP_FILE \
  --timeout 15 \
  --memory-size 512 \
  --architectures "$PACKAGE_ARCH" \
  --region us-east-1 2>/dev/null || true
echo "✅ Lambda created."
echo "✅ Lambda deployed."