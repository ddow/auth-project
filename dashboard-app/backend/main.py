from fastapi import FastAPI, HTTPException, Form
from mangum import Mangum
import boto3
from passlib.context import CryptContext
import pyotp
import jwt
from datetime import datetime, timedelta
import json
import time
import os
import logging
from typing import Optional

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

if not logger.handlers:
    logger.addHandler(logging.StreamHandler())
logger.info("1. Lambda function starting...")

logger.info("2. Environment variables loaded: %s", {k: v for k, v in os.environ.items()})
is_local = os.getenv("IS_LOCAL", os.getenv("AWS_SAM_LOCAL", "false")).lower() == "true"
logger.info("3. IS_LOCAL set to: %s", is_local)

logger.info("4. Initializing CryptContext with bcrypt rounds: 12...")
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto", bcrypt__default_rounds=12)
logger.info("5. CryptContext initialized")

logger.info("6. Initializing FastAPI app...")
api_gateway_base_path = "" if is_local else "/Prod"
app = FastAPI(root_path=api_gateway_base_path)
logger.info("7. FastAPI app initialized")

logger.info("8. Initializing Secrets Manager client...")
secrets_endpoint = "http://host.docker.internal:4566" if is_local else None
max_retries = 5
retry_delay = 2
for attempt in range(max_retries):
    try:
        secrets_client = boto3.client("secretsmanager", endpoint_url=secrets_endpoint, region_name="us-east-1")
        secrets_client.get_secret_value(SecretId="UserCredentials")
        logger.info("9. Secrets Manager client initialized, endpoint: %s", secrets_endpoint or "AWS")
        break
    except Exception as e:
        logger.warning("10. Attempt %d/%d failed to connect to Secrets Manager: %s", attempt + 1, max_retries, str(e))
        if attempt < max_retries - 1:
            time.sleep(retry_delay)
        else:
            logger.error("10. Failed to initialize Secrets Manager after %d attempts: %s", max_retries, str(e))
            raise
else:
    raise Exception("Secrets Manager initialization failed after retries")

logger.info("11. Setting JWT credentials...")
JWT_SECRET = os.getenv("JWT_SECRET", "your-secret-key")
logger.info("12. Credentials set: JWT_SECRET=%s", JWT_SECRET[:5])

@app.get("/health")
async def health():
    logger.info("13. Health check executed")
    return {"status": "ok"}

def get_user(username: str) -> Optional[dict]:
    logger.info("14. Fetching user secret for: %s", username)
    try:
        response = secrets_client.get_secret_value(SecretId="UserCredentials")
        users = json.loads(response["SecretString"])
        logger.info("15. Secret retrieved: %s", {k: v for k, v in users.items() if k == username})
        return users.get(username)
    except Exception as e:
        logger.error("16. Error fetching user secret: %s", str(e))
        return None

def verify_password(plain_password: str, hashed_password: str) -> bool:
    logger.info("17. Verifying password: plain='%s...', hashed='%s...'", plain_password[:5], hashed_password[:5])
    try:
        logger.info("18. Verifying hash format: %s", hashed_password)
        result = pwd_context.verify(plain_password, hashed_password)
        logger.info("19. Password verification result: %s", result)
        return result
    except ValueError as e:
        logger.error("20. Verification error: %s", str(e))
        raise HTTPException(status_code=401, detail="Invalid password format")

def create_jwt_token(username: str) -> str:
    logger.info("21. Creating JWT token for: %s", username)
    payload = {
        "sub": username,
        "exp": datetime.utcnow() + timedelta(hours=24)
    }
    token = jwt.encode(payload, JWT_SECRET, algorithm="HS256")
    logger.info("22. JWT token created: %s...", token[:10])
    return token

@app.post("/login")
async def login(username: str = Form(...), password: str = Form(...)):
    logger.info("23. Login attempt for username: %s", username)
    try:
        logger.info("24. Starting user retrieval...")
        user = get_user(username)
        logger.info("25. User retrieval completed, user: %s", user)
        if not user:
            raise HTTPException(status_code=401, detail="Invalid credentials")

        logger.info("28. Verifying password for user: %s, hash: %s", username, user["password"])
        if not verify_password(password, user["password"]):
            raise HTTPException(status_code=401, detail="Invalid credentials")

        if user.get("requires_change", False):
            logger.info("29. First login detected, requiring password change")
            return {
                "message": "First login detected. Please change your password.",
                "requires_change": True,
                "token": None
            }

        if user.get("totp_secret"):
            logger.info("30. TOTP required for user: %s", username)
            return {
                "message": "TOTP required",
                "requires_totp": True,
                "token": None
            }

        logger.info("31. Generating JWT token for user: %s", username)
        token = create_jwt_token(username)
        logger.info("32. Login successful for user: %s", username)
        return {"message": "Login successful", "token": token}
    except HTTPException as he:
        logger.error("33. HTTPException in login: %s", str(he.detail))
        raise
    except Exception as e:
        logger.error("34. Unexpected error in login: %s", str(e))
        raise HTTPException(status_code=500, detail="Internal server error")

@app.post("/change-password")
async def change_password(username: str = Form(...), old_password: str = Form(...), new_password: str = Form(...)):
    logger.info("35. Change password attempt for username: %s", username)
    try:
        user = get_user(username)
        if not user or not verify_password(old_password, user["password"]):
            raise HTTPException(status_code=401, detail="Invalid credentials")

        secret = pyotp.random_base32()
        logger.info("36. Setting totp_secret: %s", secret)

        response = secrets_client.get_secret_value(SecretId="UserCredentials")
        users = json.loads(response["SecretString"])
        users[username] = {"password": pwd_context.hash(new_password), "requires_change": False, "totp_secret": secret, "biometric_key": user.get("biometric_key", "")}
        secrets_client.update_secret(SecretId="UserCredentials", SecretString=json.dumps(users))
        logger.info("37. Updated user secret: %s", get_user(username))
        return {"message": "Password changed. Proceed to TOTP setup.", "totp_secret": secret}
    except Exception as e:
        logger.error("38. Error in change_password: %s", str(e))
        raise HTTPException(status_code=500, detail="Internal server error")

@app.post("/setup-totp")
async def setup_totp(username: str = Form(...), totp_code: str = Form(...), token: str = Form(...)):
    logger.info("39. Setup TOTP attempt for username: %s", username)
    try:
        if not is_local:
            jwt.decode(token, JWT_SECRET, algorithms=["HS256"])
        user = get_user(username)
        if not user:
            raise HTTPException(status_code=401, detail="User not found")

        secret = user["totp_secret"]
        if not secret:
            raise HTTPException(status_code=400, detail="TOTP secret not found")

        totp = pyotp.TOTP(secret)
        if not totp.verify(totp_code):
            raise HTTPException(status_code=401, detail="Invalid TOTP code")

        logger.info("40. TOTP setup completed for user: %s", username)
        return {"message": "TOTP setup complete. Proceed to biometric setup."}
    except HTTPException as he:
        logger.error("41. HTTPException in setup_totp: %s", str(he.detail))
        raise
    except Exception as e:
        logger.error("42. Error in setup_totp: %s", str(e))
        raise HTTPException(status_code=500, detail="Internal server error")

@app.post("/setup-biometric")
async def setup_biometric(username: str = Form(...), token: str = Form(...)):
    logger.info("43. Setup biometric attempt for username: %s", username)
    try:
        if not is_local:
            jwt.decode(token, JWT_SECRET, algorithms=["HS256"])
        user = get_user(username)
        if not user:
            raise HTTPException(status_code=401, detail="User not found")

        response = secrets_client.get_secret_value(SecretId="UserCredentials")
        users = json.loads(response["SecretString"])
        users[username]["biometric_key"] = "mock-biometric-key"
        secrets_client.update_secret(SecretId="UserCredentials", SecretString=json.dumps(users))
        logger.info("44. Biometric setup completed for user: %s", username)
        return {"message": "Biometric setup complete. Login with biometrics next time."}
    except HTTPException as he:
        logger.error("45. HTTPException in setup_biometric: %s", str(he.detail))
        raise
    except Exception as e:
        logger.error("46. Error in setup_biometric: %s", str(e))
        raise HTTPException(status_code=500, detail="Internal server error")

handler = Mangum(app)