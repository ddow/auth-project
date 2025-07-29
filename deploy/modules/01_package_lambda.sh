#!/usr/bin/env bash
set -euo pipefail

echo "📦 Packaging Lambda function…"

# Define paths
BUILD_DIR="dashboard-app/backend/build"
ZIP_FILE="auth_backend.zip"
SOURCE_DIR="dashboard-app/backend"
STAGE_DIR="/tmp/lambda-build"

# 🧹 Cleaning old build directory & ZIP
echo "🧹 Cleaning old build directory & ZIP…"
rm -rf "$BUILD_DIR" 2>/dev/null || true
rm -f "$ZIP_FILE" 2>/dev/null || true
mkdir -p "$BUILD_DIR"

# 🐳 Installing Python dependencies inside Docker with x86_64
echo "🐳 Installing Python dependencies…"
docker run --rm \
  --platform linux/amd64 \
  -v "$(pwd)/$SOURCE_DIR:/app" \
  python:3.12 \
  sh -c "mkdir -p $STAGE_DIR && \
         cp /app/requirements.txt $STAGE_DIR/ && \
         pip install --upgrade pip && \
         pip install -r $STAGE_DIR/requirements.txt -t $STAGE_DIR --platform manylinux2014_x86_64 --only-binary=:all: --no-deps && \
         cp /app/main.py $STAGE_DIR/" || {
  echo "❌ Failed to install dependencies."
  exit 1
}

# 📦 Creating deployment package
echo "📦 Creating deployment package…"
cp "$STAGE_DIR/requirements.txt" "$BUILD_DIR/"
cp "$STAGE_DIR/main.py" "$BUILD_DIR/"
cd "$BUILD_DIR" && zip -r "../../$ZIP_FILE" . && cd -
# ZIP is created in project root

echo "✅ Lambda package ready at $ZIP_FILE"