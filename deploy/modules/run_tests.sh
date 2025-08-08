#!/usr/bin/env bash
# deploy/modules/run_tests.sh

set -euo pipefail

# Assume PORT is set by deploy_backend.sh or default to 3000
PORT=${PORT:-3000}

echo "🔍 Running automated tests..."

# Test 1: Initial Login
echo "🧪 Test 1: Initial Login"
LOGIN_RESPONSE=$(curl -s -X POST http://localhost:$PORT/login \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d 'username=test@example.com&password=InitialPass123!')
if [[ "$(echo "$LOGIN_RESPONSE" | jq -r '.message' 2>/dev/null)" == "First login detected. Please change your password." &&
      "$(echo "$LOGIN_RESPONSE" | jq -r '.requires_change' 2>/dev/null)" == "true" &&
      "$(echo "$LOGIN_RESPONSE" | jq -r '.token' 2>/dev/null)" == "null" ]]; then
  echo "✅ Test 1 Passed: Initial login detected."
else
  echo "❌ Test 1 Failed: Expected {\"message\":\"First login detected. Please change your password.\",\"requires_change\":true,\"token\":null}, got: $LOGIN_RESPONSE"
  exit 1
fi

# Test 2: Change Password
echo "🧪 Test 2: Change Password"
CHANGE_RESPONSE=$(curl -s -X POST http://localhost:$PORT/change-password \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d 'username=test@example.com&old_password=InitialPass123!&new_password=NewPass123!')
if [[ "$(echo "$CHANGE_RESPONSE" | jq -r '.message' 2>/dev/null)" == "Password changed. Proceed to TOTP setup." ]]; then
  echo "✅ Test 2 Passed: Password changed."
else
  echo "❌ Test 2 Failed: Expected {\"message\":\"Password changed. Proceed to TOTP setup.\"}, got: $CHANGE_RESPONSE"
  exit 1
fi

# Test 3: Setup TOTP
echo "🧪 Test 3: Setup TOTP"
TOTP_SECRET=$(echo "$CHANGE_RESPONSE" | jq -r '.totp_secret' 2>/dev/null)
if [ -n "$TOTP_SECRET" ]; then
  TOTP_CODE=$(python3 -c "import pyotp; print(pyotp.TOTP('$TOTP_SECRET').now())" 2>/dev/null || echo "123456")
  TOTP_RESPONSE=$(curl -s -X POST http://localhost:$PORT/setup-totp \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=test@example.com&totp_code=$TOTP_CODE&token=dummy-jwt-token")
  if [[ "$(echo "$TOTP_RESPONSE" | jq -r '.message' 2>/dev/null)" == "TOTP setup complete. Proceed to biometric setup." ]]; then
    echo "✅ Test 3 Passed: TOTP setup complete."
  else
    echo "❌ Test 3 Failed: Expected {\"message\":\"TOTP setup complete. Proceed to biometric setup.\"}, got: $TOTP_RESPONSE"
    exit 1
  fi
else
  echo "❌ Test 3 Failed: Could not extract TOTP secret."
  exit 1
fi

# Test 4: Setup Biometric
echo "🧪 Test 4: Setup Biometric"
BIOMETRIC_RESPONSE=$(curl -s -X POST http://localhost:$PORT/setup-biometric \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=test@example.com&token=dummy-jwt-token")
if [[ "$(echo "$BIOMETRIC_RESPONSE" | jq -r '.message' 2>/dev/null)" == "Biometric setup complete. Login with biometrics next time." ]]; then
  echo "✅ Test 4 Passed: Biometric setup complete."
else
  echo "❌ Test 4 Failed: Expected {\"message\":\"Biometric setup complete. Login with biometrics next time.\"}, got: $BIOMETRIC_RESPONSE"
  exit 1
fi

echo ""
echo "✅ All local tests passed successfully."