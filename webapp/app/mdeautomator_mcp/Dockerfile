# Multi-stage Docker build for MDEAutomator MCP Server
# Optimized for security, performance, and minimal attack surface

# Stage 1: Build stage
FROM python:3.11-slim-bullseye AS builder

# Set build arguments
ARG BUILD_DATE
ARG VERSION=1.0.0
ARG VCS_REF

# Install build dependencies including trio requirements
RUN apt-get update && apt-get install -y \
    build-essential \
    gcc \
    g++ \
    libffi-dev \
    libssl-dev \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

# Create virtual environment
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Copy requirements and install Python dependencies including trio
COPY requirements-docker.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --upgrade pip setuptools wheel && \
    pip install --no-cache-dir -r /tmp/requirements.txt && \
    python -c "import trio; import anyio; print(f'✓ trio {trio.__version__} and anyio installed successfully')"

# Stage 2: Runtime stage
FROM python:3.11-slim-bullseye AS runtime

# Set build metadata labels
LABEL maintainer="MDEAutomator Team" \
      org.opencontainers.image.title="MDEAutomator MCP Server" \
      org.opencontainers.image.description="Model Context Protocol server for Microsoft Defender for Endpoint operations" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.source="https://github.com/msdirtbag/MDEAutomator" \
      org.opencontainers.image.documentation="https://github.com/msdirtbag/MDEAutomator/blob/main/README.md" \
      org.opencontainers.image.licenses="MIT"

# Install runtime dependencies including trio runtime libs
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libffi7 \
    libssl1.1 \
    curl \
    dumb-init \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Create non-root user for security
RUN groupadd --gid 1000 mcpuser && \
    useradd --uid 1000 --gid mcpuser --shell /bin/bash --create-home mcpuser

# Copy virtual environment from builder stage
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Create application directory
WORKDIR /app

# Copy application code
COPY --chown=mcpuser:mcpuser . /app/

# Verify trio installation in runtime environment
RUN python -c "import trio; import anyio; print('✓ trio and anyio available in runtime')"

# Set Python path
ENV PYTHONPATH=/app

# Create directories for logs and data with proper permissions
RUN mkdir -p /app/logs /app/data && \
    chown -R mcpuser:mcpuser /app

# Set security-focused environment variables
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONHASHSEED=random \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Health check configuration - use HTTP health endpoint
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Switch to non-root user
USER mcpuser

# Expose port (if needed for HTTP endpoints in future)
EXPOSE 8080

# Set entrypoint and default command - use fixed hybrid server
ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["python", "mdeautomator_mcp.py"]

# Container metadata
ENV CONTAINER_VERSION="${VERSION}"
ENV CONTAINER_BUILD_DATE="${BUILD_DATE}"
