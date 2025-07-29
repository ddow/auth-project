import os
import json
import boto3
from fastapi import FastAPI, HTTPException, Depends, Form
from fastapi.security import OAuth2PasswordBearer
from passlib.context import CryptContext
import pyotp
from mangum import Mangum

app = FastAPI()
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="token")
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table(os.environ['DYNAMO_TABLE'])
cognito = boto3.client('cognito-idp')
DOMAIN = os.environ.get('DOMAIN', 'default-domain')
COGNITO_USER_POOL_ID = os.environ.get('COGNITO_USER_POOL_ID')
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


@app.post("/login")
async def login(username: str = Form(...), password: str = Form(...)):
    user = get_user(username)
    if not user:
        raise HTTPException(status_code=401, detail="Invalid credentials")

    if not verify_password(password, user['password_hash']):
        raise HTTPException(status_code=401, detail="Invalid credentials")

    if user.get('first_login', True):
        return {"message": "First login detected. Please change your password.", "requires_change": True, "token": None}

    if not user.get('totp_setup', False):
        totp_secret = pyotp.random_base32()
        update_user(username, "SET totp_secret = :s, totp_setup = :t", {":s": totp_secret, ":t": False})
        return {"message": "TOTP setup required. Use secret: " + totp_secret, "requires_totp": True, "token": None}

    if not user.get('biometric_setup', False):
        return {"message": "Biometric setup required. Contact admin.", "requires_biometric": True, "token": None}

    # Generate JWT token (simplified placeholder)
    token = "dummy-jwt-token"  # Replace with real JWT implementation
    return {"access_token": token, "token_type": "bearer"}


@app.post("/change-password")
async def change_password(username: str = Form(...), old_password: str = Form(...), new_password: str = Form(...)):
    user = get_user(username)
    if not user or not verify_password(old_password, user['password_hash']):
        raise HTTPException(status_code=401, detail="Invalid credentials")

    if user.get('first_login', True):
        new_hash = get_password_hash(new_password)
        update_user(username, "SET password_hash = :p, first_login = :f", {":p": new_hash, ":f": False})
        return {"message": "Password changed. Proceed to TOTP setup."}
    raise HTTPException(status_code=403, detail="Password change only allowed on first login")


@app.post("/setup-totp")
async def setup_totp(username: str = Form(...), totp_code: str = Form(...), token: str = Depends(oauth2_scheme)):
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
    user = get_user(username)
    if not user or not user.get('totp_setup', False):
        raise HTTPException(status_code=400, detail="Complete TOTP setup first")

    # Placeholder for face/finger biometric setup using AWS Rekognition or Cognito
    cognito.admin_update_user_attributes(
        UserPoolId=COGNITO_USER_POOL_ID,
        Username=username,
        UserAttributes=[{'Name': 'custom:biometricStatus', 'Value': 'enabled'}]
    )
    update_user(username, "SET biometric_setup = :b", {":b": True})
    return {"message": "Biometric setup complete. Login with biometrics next time."}


handler = Mangum(app)