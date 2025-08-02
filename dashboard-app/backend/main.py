import os
import logging
from typing import Optional
from fastapi import FastAPI, HTTPException, Form
from mangum import Mangum
import boto3
import boto3.dynamodb.conditions as conditions
from passlib.context import CryptContext
import pyotp
import jwt
from datetime import datetime, timedelta

# Configure logging and ensure a handler exists
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Add a StreamHandler if no handlers are present to ensure output
if not logger.handlers:
    logger.addHandler(logging.StreamHandler())
logger.info("1. Lambda function starting...")  # Immediate log after setup

# Log environment variables for debugging
logger.info("2. Environment variables loaded: %s", {k: v for k, v in os.environ.items()})
is_local = os.getenv("IS_LOCAL", os.getenv("AWS_SAM_LOCAL", "false")).lower() == "true"
logger.info("3. IS_LOCAL set to: %s", is_local)

# Initialize CryptContext with optimized bcrypt configuration
logger.info("4. Initializing CryptContext...")
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto", bcrypt__default_rounds=8)
logger.info("5. CryptContext initialized")

# Initialize FastAPI app
logger.info("6. Initializing FastAPI app...")
api_gateway_base_path = "" if is_local else "/Prod"
app = FastAPI(root_path=api_gateway_base_path)
logger.info("7. FastAPI app initialized")

# DynamoDB and Cognito setup
logger.info("8. Initializing DynamoDB resource...")
dynamodb = boto3.resource("dynamodb", endpoint_url="http://localhost:8000" if is_local else None, region_name="us-east-1")
logger.info("9. DynamoDB resource initialized, endpoint: %s", "http://localhost:8000" if is_local else "AWS")
table = dynamodb.Table(os.getenv("DYNAMO_TABLE", "AuthUsers"))
logger.info("10. DynamoDB table set: %s", os.getenv("DYNAMO_TABLE", "AuthUsers"))

if is_local:
    logger.info("11. Using MockCognitoClient in local mode...")
    class MockCognitoClient:
        def admin_create_user(self, UserPoolId, Username, TemporaryPassword):
            logger.info("MockCognitoClient: admin_create_user called")
            return {}

        def admin_initiate_auth(self, UserPoolId, ClientId, AuthFlow, AuthParameters):
            logger.info("MockCognitoClient: admin_initiate_auth called")
            return {"AuthenticationResult": {"IdToken": "dummy-jwt-token"}}

        def admin_respond_to_auth_challenge(self, UserPoolId, ClientId, ChallengeName, Session, ChallengeResponses):
            logger.info("MockCognitoClient: admin_respond_to_auth_challenge called")
            return {"AuthenticationResult": {"IdToken": "dummy-jwt-token"}}

    cognito_client = MockCognitoClient()
    logger.info("12. MockCognitoClient initialized")
else:
    logger.info("13. Initializing Cognito client...")
    cognito_client = boto3.client("cognito-idp", region_name="us-east-1")
    logger.info("14. Cognito client initialized")

logger.info("15. Setting JWT and Cognito credentials...")
JWT_SECRET = os.getenv("JWT_SECRET", "your-secret-key")
COGNITO_USER_POOL_ID = os.getenv("COGNITO_USER_POOL_ID", "local-pool")
COGNITO_CLIENT_ID = os.getenv("COGNITO_CLIENT_ID", "testclientid")
logger.info("16. Credentials set: JWT_SECRET=%s, COGNITO_USER_POOL_ID=%s, COGNITO_CLIENT_ID=%s", JWT_SECRET[:5], COGNITO_USER_POOL_ID, COGNITO_CLIENT_ID)

# Health endpoint for readiness check
@app.get("/health")
async def health():
    logger.info("17. Health check executed")
    return {"status": "ok"}

def get_user(username: str) -> Optional[dict]:
    logger.info("18. Querying user: %s", username)
    try:
        response = table.get_item(Key={"username": username})
        logger.info("19. Get user response: %s", response)
        return response.get("Item")
    except Exception as e:
        logger.error("20. Get user error: %s", str(e))
        return None

def verify_password(plain_password: str, hashed_password: str) -> bool:
    logger.info("21. Verifying password: plain='%s...', hashed='%s...'", plain_password[:5], hashed_password[:5])
    try:
        result = pwd_context.verify(plain_password, hashed_password)
        logger.info("22. Password verification result: %s", result)
        return result
    except ValueError as e:
        logger.error("23. Verification error: %s", str(e))
        return False

def create_jwt_token(username: str) -> str:
    logger.info("24. Creating JWT token for: %s", username)
    payload = {
        "sub": username,
        "exp": datetime.utcnow() + timedelta(hours=24)
    }
    token = jwt.encode(payload, JWT_SECRET, algorithm="HS256")
    logger.info("25. JWT token created: %s...", token[:10])
    return token

@app.post("/login")
async def login(username: str = Form(...), password: str = Form(...)):
    logger.info("26. Login attempt for username: %s", username)
    try:
        logger.info("27. Starting user retrieval...")
        user = get_user(username)
        logger.info("28. User retrieval completed, user: %s", user)
        if not user:
            logger.info("29. User not found, creating new user")
            if is_local:
                initial_hash = pwd_context.hash(password)
                logger.info("30. Hashing password for new user")
                table.put_item(Item={
                    "username": username,
                    "password": initial_hash,
                    "requires_change": True,
                    "totp_secret": None,
                    "biometric_key": None
                })
                user = get_user(username)
            else:
                logger.info("31. Creating user in Cognito")
                cognito_client.admin_create_user(
                    UserPoolId=COGNITO_USER_POOL_ID,
                    Username=username,
                    TemporaryPassword=password
                )
                user = get_user(username)
            if not user:
                raise HTTPException(status_code=400, detail="User creation failed")

        logger.info("32. Verifying password for user: %s", username)
        if not verify_password(password, user["password"]):
            raise HTTPException(status_code=401, detail="Invalid credentials")

        if user.get("requires_change", False):
            logger.info("33. First login detected, requiring password change")
            return {
                "message": "First login detected. Please change your password.",
                "requires_change": True,
                "token": None
            }

        if user.get("totp_secret"):
            logger.info("34. TOTP required for user: %s", username)
            return {
                "message": "TOTP required",
                "requires_totp": True,
                "token": None
            }

        logger.info("35. Generating JWT token for user: %s", username)
        token = create_jwt_token(username)
        logger.info("36. Login successful for user: %s", username)
        return {"message": "Login successful", "token": token}
    except HTTPException as he:
        logger.error("37. HTTPException in login: %s", str(he.detail))
        raise
    except Exception as e:
        logger.error("38. Unexpected error in login: %s", str(e))
        raise HTTPException(status_code=500, detail="Internal server error")

@app.post("/change-password")
async def change_password(username: str = Form(...), old_password: str = Form(...), new_password: str = Form(...)):
    logger.info("39. Change password attempt for username: %s", username)
    try:
        user = get_user(username)
        if not user or not verify_password(old_password, user["password"]):
            raise HTTPException(status_code=401, detail="Invalid credentials")

        secret = pyotp.random_base32()
        logger.info("40. Setting totp_secret: %s", secret)

        table.update_item(
            Key={"username": username},
            UpdateExpression="SET password = :p, requires_change = :r, totp_secret = :s",
            ExpressionAttributeValues={
                ":p": pwd_context.hash(new_password),
                ":r": False,
                ":s": secret
            }
        )
        logger.info("41. Updated user: %s", get_user(username))
        return {"message": "Password changed. Proceed to TOTP setup.", "totp_secret": secret}
    except Exception as e:
        logger.error("42. Error in change_password: %s", str(e))
        raise HTTPException(status_code=500, detail="Internal server error")

@app.post("/setup-totp")
async def setup_totp(username: str = Form(...), totp_code: str = Form(...), token: str = Form(...)):
    logger.info("43. Setup TOTP attempt for username: %s", username)
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

        logger.info("44. TOTP setup completed for user: %s", username)
        return {"message": "TOTP setup complete. Proceed to biometric setup."}
    except HTTPException as he:
        logger.error("45. HTTPException in setup_totp: %s", str(he.detail))
        raise
    except Exception as e:
        logger.error("46. Error in setup_totp: %s", str(e))
        raise HTTPException(status_code=500, detail="Internal server error")

@app.post("/setup-biometric")
async def setup_biometric(username: str = Form(...), token: str = Form(...)):
    logger.info("47. Setup biometric attempt for username: %s", username)
    try:
        if not is_local:
            jwt.decode(token, JWT_SECRET, algorithms=["HS256"])
        user = get_user(username)
        if not user:
            raise HTTPException(status_code=401, detail="User not found")

        table.update_item(
            Key={"username": username},
            UpdateExpression="SET biometric_key = :b",
            ExpressionAttributeValues={":b": "mock-biometric-key"}
        )
        logger.info("48. Biometric setup completed for user: %s", username)
        return {"message": "Biometric setup complete. Login with biometrics next time."}
    except HTTPException as he:
        logger.error("49. HTTPException in setup_biometric: %s", str(he.detail))
        raise
    except Exception as e:
        logger.error("50. Error in setup_biometric: %s", str(e))
        raise HTTPException(status_code=500, detail="Internal server error")

handler = Mangum(app)