FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir \
    anthropic>=0.40.0 \
    psycopg2-binary>=2.9.9 \
    python-dotenv>=1.0.0 \
    requests>=2.31.0

COPY . .

CMD ["python", "-u", "runner.py", "--help"]
