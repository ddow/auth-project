#!/usr/bin/env bash
set -euo pipefail

echo "🔐 Step 2: Ensuring IAM role exists: $ROLE_NAME"

# Create IAM role
aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}' --region us-east-1 2>/dev/null || true
echo "🔐 Creating IAM role: $ROLE_NAME"

# Attach policy
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" --region us-east-1 2>/dev/null || true
echo "🔗 Attaching policy to IAM role..."