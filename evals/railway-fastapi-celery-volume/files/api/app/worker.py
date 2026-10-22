import os
from celery import Celery
celery = Celery("tasks", broker=os.environ["REDIS_URL"], backend=os.environ["REDIS_URL"])

@celery.task
def ocr_document(path: str):
    # heavy CPU job, 30-120 s, reads the file from the shared /data volume
    return {"path": path, "ok": True}
