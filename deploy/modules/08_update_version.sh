#!/usr/bin/env bash
# deploy/modules/08_update_version.sh

set -euo pipefail

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
NEW_VERSION=$(printf "%.2f" "$(echo "$NEW_VERSION_NUM/100" | bc -l))

# Generate a new SECRET_KEY securely and update template.yml
SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
sed -i.bak "s/^${VERSION_KEY}: .*/${VERSION_KEY}: Authentication API Stack - v${NEW_VERSION} (SECRET_KEY: ${SECRET_KEY})/" "$TEMPLATE_FILE" && rm -f "${TEMPLATE_FILE}.bak"
echo "📝 Updated version in $TEMPLATE_FILE to v${NEW_VERSION} with new SECRET_KEY: ${SECRET_KEY}"