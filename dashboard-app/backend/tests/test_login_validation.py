from fastapi.testclient import TestClient
from main import app

def test_login_validation():
  c = TestClient(app)
  r = c.post("/login", data={})
  assert r.status_code in (400, 422)
