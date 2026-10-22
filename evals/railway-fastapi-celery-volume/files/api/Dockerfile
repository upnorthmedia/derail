FROM python:3.12-slim
WORKDIR /app
RUN --mount=type=cache,id=s/5f1c2d3e-pip,target=/root/.cache/pip pip install -r requirements.txt || true
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
CMD ["uvicorn", "app.main:app", "--host", "::", "--port", "8000"]
