#!/usr/bin/env bash
set -euo pipefail

echo "📦 Packaging Lambda function…"

# Define paths
BUILD_DIR="dashboard-app/backend/build"
ZIP_FILE="auth_backend.zip"

# 🧹 Cleaning old build directory & ZIP
echo "🧹 Cleaning old build directory & ZIP…"
rm -rf "$BUILD_DIR" 2>/dev/null || true
rm -f "$ZIP_FILE" 2>/dev/null || true
mkdir -p "$BUILD_DIR"

# 🐳 Installing Python dependencies
echo "🐳 Installing Python dependencies…"
docker run --rm -v $(pwd)/dashboard-app/backend:/var/task public.ecr.aws/lambda/python:3.12 \
  sh -c "pip install --upgrade pip && pip install -r requirements.txt -t /var/task && cp -r /var/task/. /var/task/build"

# 📦 Creating deployment package
echo "📦 Creating deployment package…"
cd "$BUILD_DIR" && zip -r "../$ZIP_FILE" . && cd ../..
mv "$ZIP_FILE" ..

echo "✅ Lambda package ready at dashboard-app/backend/$ZIP_FILE"