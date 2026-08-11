FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY operator.py .

EXPOSE 8000

CMD ["kopf", "run", "--all-namespaces", "operator.py"]
