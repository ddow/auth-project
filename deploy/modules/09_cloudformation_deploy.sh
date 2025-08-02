#!/usr/bin/env bash
# deploy/modules/09_cloudformation_deploy.sh

set -euo pipefail

TEMPLATE_FILE="template.yml"

if [ "$LOCAL_ONLY" != "true" ]; then
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