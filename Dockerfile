# ============================================================================
# Dockerfile for LiteLLM Vertex AI Proxy on Google Cloud Run
# ============================================================================
# Uses a secure, lightweight slim Python image, installs the required proxy
# dependencies, and dynamically binds to Cloud Run's runtime PORT injection.

FROM python:3.11-slim

# Set production configurations
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# Install requirements early to leverage Docker layer caching
RUN pip install --upgrade pip && \
    pip install "litellm[proxy]" "litellm[google]"

# Copy model routing configurations
COPY config.yaml .

# Cloud Run injects the active port in the PORT environment variable dynamically.
# We use sh -c to expand the variable correctly at runtime.
# Default to 4000 if PORT is unset.
EXPOSE 4000
CMD ["sh", "-c", "exec litellm --config config.yaml --port ${PORT:-4000} --host 0.0.0.0"]
