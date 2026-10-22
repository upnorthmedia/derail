import os, shutil
from fastapi import FastAPI, UploadFile
from sqlalchemy import create_engine, text
app = FastAPI()
engine = create_engine(os.environ["DATABASE_URL"], pool_size=5)
UPLOAD_DIR = os.environ.get("UPLOAD_DIR", "/data/uploads")

@app.get("/healthz")
def healthz():
    return {"ok": True}

@app.post("/documents")
async def upload(file: UploadFile):
    os.makedirs(UPLOAD_DIR, exist_ok=True)
    dest = os.path.join(UPLOAD_DIR, file.filename)
    with open(dest, "wb") as f:
        shutil.copyfileobj(file.file, f)
    with engine.begin() as conn:
        conn.execute(text("insert into documents(path) values (:p)"), {"p": dest})
    return {"stored": dest}

@app.get("/documents/{name}")
def get_doc(name: str):
    return open(os.path.join(UPLOAD_DIR, name), "rb").read()
