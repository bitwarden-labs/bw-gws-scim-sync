FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY src/ ./src/
RUN useradd --system --uid 10001 --no-create-home bwsync
USER bwsync
ENTRYPOINT ["python", "-m", "src.main"]
