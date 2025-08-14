import os, json, bcrypt, boto3

SECRET_NAME = os.getenv("SECRET_NAME","UserCredentials")
AWS_ENDPOINT_URL = os.getenv("AWS_ENDPOINT_URL")

if AWS_ENDPOINT_URL:
    sm = boto3.client("secretsmanager", endpoint_url=AWS_ENDPOINT_URL)
else:
    sm = boto3.client("secretsmanager")

users = {
  "test@example.com": {
    "password": bcrypt.hashpw(b"ChangeMe123!", bcrypt.gensalt()).decode(),
    "requires_change": True,
    "totp_secret": "",
    "biometric_key": "",
    "roles": ["admin"]
  }
}

try:
    sm.create_secret(Name=SECRET_NAME, SecretString=json.dumps(users))
    print(f"Created secret {SECRET_NAME}")
except sm.exceptions.ResourceExistsException:
    sm.update_secret(SecretId=SECRET_NAME, SecretString=json.dumps(users))
    print(f"Updated secret {SECRET_NAME}")
