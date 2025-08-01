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

# Module-level mock users dictionary for persistence
mock_users = {}

# Log environment variables for debugging
print("Environment variables:", {k: v for k, v in os.environ.items()})
is_local = os.getenv("IS_LOCAL", os.getenv("AWS_SAM_LOCAL", "false")).lower() == "true"
print("IS_LOCAL:", is_local)

# Initialize CryptContext with explicit bcrypt configuration
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto", bcrypt__default_rounds=12)

# Initialize FastAPI app
api_gateway_base_path = "" if is_local else "/Prod"
app = FastAPI(root_path=api_gateway_base_path)

# Mock DynamoDB and Cognito for local testing
if is_local:
    print("Using MockDynamoTable and MockCognitoClient")
    # Pre-populate mock_users with a default user if empty
    if not mock_users:
        default_user = {
            "username": "test@example.com",
            "password": pwd_context.hash("InitialPass123!"),
            "requires_change": True,
            "totp_secret": None,
            "biometric_key": None
        }
        mock_users[default_user["username"]] = default_user
        print(f"Initialized mock_users with default user: {default_user}")

    class MockDynamoTable:
        def get_item(self, Key):
            username = Key["username"]
            user = mock_users.get(username, {})
            print(f"MockDynamoTable.get_item: username={username}, user={user}, mock_users={mock_users}")  # Enhanced debug
            return {"Item": user}

        def put_item(self, Item):
            mock_users[Item["username"]] = Item
            print(f"MockDynamoTable.put_item: added user={Item}, mock_users={mock_users}")  # Enhanced debug
            return {}

        def update_item(self, Key, UpdateExpression, ExpressionAttributeValues):
            username = Key["username"]
            if username in mock_users:
                # Simple parsing for SET expressions
                sets = UpdateExpression.replace("SET ", "").split(", ")
                for set_part in sets:
                    k, v_key = set_part.split(" = ")
                    mock_users[username][k] = ExpressionAttributeValues[v_key]
                print(f"MockDynamoTable.update_item: updated user={mock_users[username]}, mock_users={mock_users}")  # Enhanced debug
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

JWT_SECRET = os.getenv("JWT_SECRET", "your-secret-key")
COGNITO_USER_POOL_ID = os.getenv("COGNITO_USER_POOL_ID", "local-pool")
COGNITO_CLIENT_ID = os.getenv("COGNITO_CLIENT_ID", "testclientid")


def get_user(username: str) -> Optional[dict]:
    response = table.get_item(Key={"username": username})
    return response.get("Item")


def verify_password(plain_password: str, hashed_password: str) -> bool:
    print(f"Verifying password: plain='{plain_password}', hashed='{hashed_password}'")  # Debug
    try:
        return pwd_context.verify(plain_password, hashed_password)
    except ValueError as e:
        print(f"Verification error: {e}")  # Debug
        return False


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
            initial_hash = pwd_context.hash(password)  # Hash the initial password correctly
            table.put_item(Item={
                "username": username,
                "password": initial_hash,
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
    print(f"change_password: retrieved user={user}")  # Debug
    if not user or not verify_password(old_password, user["password"]):
        raise HTTPException(status_code=401, detail="Invalid credentials")

    secret = pyotp.random_base32()
    print(f"change_password: setting totp_secret={secret}")  # Debug

    table.update_item(
        Key={"username": username},
        UpdateExpression="SET password = :p, requires_change = :r, totp_secret = :s",
        ExpressionAttributeValues={
            ":p": pwd_context.hash(new_password),
            ":r": False,
            ":s": secret
        }
    )
    print(f"change_password: updated user={get_user(username)}")  # Debug
    return {"message": "Password changed. Proceed to TOTP setup.", "totp_secret": secret}


@app.post("/setup-totp")
async def setup_totp(username: str = Form(...), totp_code: str = Form(...), token: str = Form(...)):
    if not is_local:
        try:
            jwt.decode(token, JWT_SECRET, algorithms=["HS256"])
        except jwt.InvalidTokenError:
            raise HTTPException(status_code=401, detail="Invalid token")

    user = get_user(username)
    if not user:
        raise HTTPException(status_code=401, detail="User not found")

    secret = user["totp_secret"]
    if not secret:
        raise HTTPException(status_code=400, detail="TOTP secret not found")

    totp = pyotp.TOTP(secret)
    if not totp.verify(totp_code):
        raise HTTPException(status_code=401, detail="Invalid TOTP code")

    # Optionally update to mark as verified, but for now, just confirm
    return {"message": "TOTP setup complete. Proceed to biometric setup."}


@app.post("/setup-biometric")
async def setup_biometric(username: str = Form(...), token: str = Form(...)):
    if not is_local:
        try:
            jwt.decode(token, JWT_SECRET, algorithms=["HS256"])
        except jwt.InvalidTokenError:
            raise HTTPException(status_code=401, detail="Invalid token")

    user = get_user(username)
    if not user:
        raise HTTPException(status_code=401, detail="User not found")

    table.update_item(
        Key={"username": username},
        UpdateExpression="SET biometric_key = :b",
        ExpressionAttributeValues={":b": "mock-biometric-key"}
    )
    return {"message": "Biometric setup complete. Login with biometrics next time."}


handler = Mangum(app)