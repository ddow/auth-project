import os
from typing import Optional
from fastapi import FastAPI, HTTPException, Form
from mangum import Mangum
import boto3
import boto3.dynamodb.conditions as conditions
from passlib.context import CryptContext
import pyotp
import jwt
from datetime import datetime, timedelta

# Log environment variables for debugging
print("Environment variables:", {k: v for k, v in os.environ.items()})
is_local = os.getenv("IS_LOCAL", "false").lower() == "true"
print("IS_LOCAL:", is_local)

# Initialize FastAPI app
api_gateway_base_path = "" if is_local else "/Prod"
app = FastAPI(root_path=api_gateway_base_path)

# Mock DynamoDB and Cognito for local testing
if is_local:
    print("Using MockDynamoTable and MockCognitoClient")


    class MockDynamoTable:
        def get_item(self, Key):
            return {
                "Item": {
                    "username": Key["username"],
                    "password": "$2b$12$KIXp8e8f9z2b3c4d5e6f7u",  # Mock hashed password (InitialPass123!)
                    "requires_change": True,
                    "totp_secret": None,
                    "biometric_key": None
                }
            }

        def put_item(self, Item):
            return {}

        def update_item(self, Key, UpdateExpression, ExpressionAttributeValues):
            return {}


    table = MockDynamoTable()


    class MockCognitoClient:
        def admin_create_user(self, UserPoolId, Username, TemporaryPassword):
            return {}

        def admin_initiate_auth(self, UserPoolId, ClientId, AuthFlow, AuthParameters):
            return {"AuthenticationResult": {"IdToken": "dummy-jwt-token"}}

        def admin_respond_to_auth_challenge(self, UserPoolId, ClientId, ChallengeName, Session, ChallengeResponses):
            return {"AuthenticationResult": {"IdToken": "dummy-jwt-token"}}


    cognito_client = MockCognitoClient()
else:
    print("Using real DynamoDB and Cognito")
    dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
    table = dynamodb.Table(os.getenv("DYNAMO_TABLE", "AuthUsers"))
    cognito_client = boto3.client("cognito-idp", region_name="us-east-1")

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
JWT_SECRET = os.getenv("JWT_SECRET", "your-secret-key")
COGNITO_USER_POOL_ID = os.getenv("COGNITO_USER_POOL_ID", "local-pool")
COGNITO_CLIENT_ID = os.getenv("COGNITO_CLIENT_ID", "testclientid")


def get_user(username: str) -> Optional[dict]:
    response = table.get_item(Key={"username": username})
    return response.get("Item")


def verify_password(plain_password: str, hashed_password: str) -> bool:
    return pwd_context.verify(plain_password, hashed_password)


def create_jwt_token(username: str) -> str:
    payload = {
        "sub": username,
        "exp": datetime.utcnow() + timedelta(hours=24)
    }
    return jwt.encode(payload, JWT_SECRET, algorithm="HS256")


@app.post("/login")
async def login(username: str = Form(...), password: str = Form(...)):
    user = get_user(username)
    if not user:
        if is_local:
            table.put_item(Item={
                "username": username,
                "password": pwd_context.hash(password),
                "requires_change": True,
                "totp_secret": None,
                "biometric_key": None
            })
            user = get_user(username)
        else:
            try:
                cognito_client.admin_create_user(
                    UserPoolId=COGNITO_USER_POOL_ID,
                    Username=username,
                    TemporaryPassword=password
                )
                user = get_user(username)
            except cognito_client.exceptions.ClientError:
                raise HTTPException(status_code=400, detail="User creation failed")

    if not verify_password(password, user["password"]):
        raise HTTPException(status_code=401, detail="Invalid credentials")

    if user.get("requires_change", False):
        return {
            "message": "First login detected. Please change your password.",
            "requires_change": True,
            "token": None
        }

    if user.get("totp_secret"):
        return {
            "message": "TOTP required",
            "requires_totp": True,
            "token": None
        }

    token = create_jwt_token(username)
    return {"message": "Login successful", "token": token}


@app.post("/change-password")
async def change_password(username: str = Form(...), old_password: str = Form(...), new_password: str = Form(...)):
    user = get_user(username)
    if not user or not verify_password(old_password, user["password"]):
        raise HTTPException(status_code=401, detail="Invalid credentials")

    table.update_item(
        Key={"username": username},
        UpdateExpression="SET password = :p, requires_change = :r",
        ExpressionAttributeValues={
            ":p": pwd_context.hash(new_password),
            ":r": False
        }
    )
    return {"message": "Password changed. Proceed to TOTP setup."}


@app.post("/setup-totp")
async def setup_totp(username: str = Form(...), totp_code: str = Form(...), token: str = Form(...)):
    user = get_user(username)
    if not user:
        raise HTTPException(status_code=401, detail="User not found")

    try:
        jwt.decode(token, JWT_SECRET, algorithms=["HS256"])
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=401, detail="Invalid token")

    secret = pyotp.random_base32()
    totp = pyotp.TOTP(secret)
    if not totp.verify(totp_code):
        raise HTTPException(status_code=401, detail="Invalid TOTP code")

    table.update_item(
        Key={"username": username},
        UpdateExpression="SET totp_secret = :s",
        ExpressionAttributeValues={":s": secret}
    )
    return {"message": "TOTP setup complete. Proceed to biometric setup."}


@app.post("/setup-biometric")
async def setup_biometric(username: str = Form(...), token: str = Form(...)):
    user = get_user(username)
    if not user:
        raise HTTPException(status_code=401, detail="User not found")

    try:
        jwt.decode(token, JWT_SECRET, algorithms=["HS256"])
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=401, detail="Invalid token")

    table.update_item(
        Key={"username": username},
        UpdateExpression="SET biometric_key = :b",
        ExpressionAttributeValues={":b": "mock-biometric-key"}
    )
    return {"message": "Biometric setup complete. Login with biometrics next time."}


handler = Mangum(app)