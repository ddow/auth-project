import os
import json
import boto3
from fastapi import FastAPI, HTTPException, Depends, Form
from fastapi.security import OAuth2PasswordBearer
from passlib.context import CryptContext
import pyotp
import jwt
import time
from mangum import Mangum

app = FastAPI()
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="token")
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table(os.environ['DYNAMO_TABLE'])
cognito = boto3.client('cognito-idp')
DOMAIN = os.environ.get('DOMAIN', 'default-domain')
COGNITO_USER_POOL_ID = os.environ.get('COGNITO_USER_POOL_ID')
COGNITO_CLIENT_ID = os.environ.get('COGNITO_CLIENT_ID')
JWT_SECRET = os.environ.get('JWT_SECRET', 'your-secret-key')  # Set in env or AWS Secrets Manager
INITIAL_PASSWORD = "InitialPass123!"

def get_user(username: str):
    response = table.get_item(Key={'username': username})
    return response.get('Item')

def update_user(username: str, update_expr, expr_values):
    table.update_item(Key={'username': username}, UpdateExpression=update_expr, ExpressionAttributeValues=expr_values)

def verify_password(plain_password, hashed_password):
    return pwd_context.verify(plain_password, hashed_password)

def get_password_hash(password):
    return pwd_context.hash(password)

def create_jwt_token(username: str):
    payload = {"sub": username, "exp": int(time.time()) + 3600}  # 1-hour expiration
    return jwt.encode(payload, JWT_SECRET, algorithm="HS256")

@app.post("/login")
async def login(username: str = Form(...), password: str = Form(...)):
    user = get_user(username)
    if not user or not verify_password(password, user.get('password_hash', '')):
        raise HTTPException(status_code=401, detail="Invalid credentials")

    if user.get('first_login', True):
        return {"message": "First login detected. Please change your password.", "requires_change": True, "token": None}

    if not user.get('totp_setup', False):
        totp_secret = pyotp.random_base32()
        update_user(username, "SET totp_secret = :s", {":s": totp_secret})
        return {"message": "TOTP setup required. Use secret: " + totp_secret, "requires_totp": True, "token": None}

    if not user.get('biometric_setup', False):
        return {"message": "Biometric setup required. Contact admin.", "requires_biometric": True, "token": None}

    token = create_jwt_token(username)
    return {"access_token": token, "token_type": "bearer"}

@app.post("/change-password")
async def change_password(username: str = Form(...), old_password: str = Form(...), new_password: str = Form(...)):
    user = get_user(username)
    if not user or not verify_password(old_password, user.get('password_hash', '')):
        raise HTTPException(status_code=401, detail="Invalid credentials")

    if not user.get('first_login', True):
        raise HTTPException(status_code=403, detail="Password change only allowed on first login")

    new_hash = get_password_hash(new_password)
    update_user(username, "SET password_hash = :p, first_login = :f", {":p": new_hash, ":f": False})
    return {"message": "Password changed. Proceed to TOTP setup."}

@app.post("/setup-totp")
async def setup_totp(username: str = Form(...), totp_code: str = Form(...), token: str = Depends(oauth2_scheme)):
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=["HS256"])
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=401, detail="Invalid token")

    user = get_user(username)
    if not user or not user.get('totp_secret'):
        raise HTTPException(status_code=400, detail="TOTP not initialized")

    totp = pyotp.TOTP(user['totp_secret'])
    if not totp.verify(totp_code):
        raise HTTPException(status_code=401, detail="Invalid TOTP code")

    update_user(username, "SET totp_setup = :t", {":t": True})
    return {"message": "TOTP setup complete. Proceed to biometric setup."}

@app.post("/setup-biometric")
async def setup_biometric(username: str = Form(...), token: str = Depends(oauth2_scheme)):
    try:
        jwt.decode(token, JWT_SECRET, algorithms=["HS256"])
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=401, detail="Invalid token")

    user = get_user(username)
    if not user or not user.get('totp_setup', False):
        raise HTTPException(status_code=400, detail="Complete TOTP setup first")

    cognito.admin_update_user_attributes(
        UserPoolId=COGNITO_USER_POOL_ID,
        Username=username,
        UserAttributes=[{'Name': 'custom:biometricStatus', 'Value': 'enabled'}]
    )
    update_user(username, "SET biometric_setup = :b", {":b": True})
    return {"message": "Biometric setup complete. Login with biometrics next time."}

handler = Mangum(app)