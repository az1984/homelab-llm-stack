FROM python:3.11-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application
COPY autoroute.py .
COPY config.yaml .

# Run as non-root
RUN useradd -m -u 1000 autoroute && \
    chown -R autoroute:autoroute /app
USER autoroute

# Expose port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD python3 -c "import requests; requests.get('http://localhost:8080/health')"

# Run
CMD ["python3", "autoroute.py"]
