FROM python:3.12-alpine AS builder

WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --no-compile --prefix=/install -r requirements.txt \
 && find /install -depth \( -name __pycache__ -o -name tests -o -name test \) -type d -exec rm -rf {} +

FROM python:3.12-alpine

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    SQLITE_PATH=/dados/loja.db

RUN adduser -D -H -u 10001 app \
 && mkdir /dados && chown app /dados

COPY --from=builder /install /usr/local

WORKDIR /app
COPY app/ ./app/
COPY static/ ./static/

USER app
EXPOSE 8000

HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=3 \
  CMD ["python", "-c", "import sys, urllib.request; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2).status == 200 else 1)"]

CMD ["uvicorn", "app:api", "--host", "0.0.0.0", "--port", "8000"]
