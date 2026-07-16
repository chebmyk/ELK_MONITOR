FROM python:3.11-slim

# Build-time arguments — override with --build-arg if needed
ARG FILEBEAT_VERSION=9.4.1
ARG PYTHON_VERSION=3.11
ARG FILEBEAT_ARCH=

# Promote ARGs to ENV so they are reliably available in every RUN layer.
# ARG alone can have scope/expansion issues in complex shell expressions.
ENV FILEBEAT_VERSION=${FILEBEAT_VERSION} \
    FILEBEAT_ARCH=${FILEBEAT_ARCH}

WORKDIR /app

# app_server.py is baked into the image; config files are mounted at /app at runtime

# Create log directory
RUN mkdir -p /var/log/app_mock && chmod 777 /var/log/app_mock

# Download and install Filebeat.
# Elastic tarballs use x86_64/aarch64; dpkg returns amd64/arm64 — map accordingly.
# FILEBEAT_ARCH accepts either naming convention and normalises to Elastic's format.
# curl -f makes HTTP errors fatal instead of silently saving an HTML error page.
RUN apt-get update && apt-get install -y curl && \
    _RAW="${FILEBEAT_ARCH:-$(dpkg --print-architecture 2>/dev/null || echo amd64)}" && \
    case "$_RAW" in \
      amd64|x86_64)        FB_ARCH=x86_64 ;; \
      arm64|aarch64)       FB_ARCH=aarch64 ;; \
      *) echo "Unsupported arch: $_RAW" && exit 1 ;; \
    esac && \
    curl -fL -O "https://artifacts.elastic.co/downloads/beats/filebeat/filebeat-${FILEBEAT_VERSION}-linux-${FB_ARCH}.tar.gz" && \
    tar xzf "filebeat-${FILEBEAT_VERSION}-linux-${FB_ARCH}.tar.gz" && \
    rm "filebeat-${FILEBEAT_VERSION}-linux-${FB_ARCH}.tar.gz" && \
    mv "filebeat-${FILEBEAT_VERSION}-linux-${FB_ARCH}" /filebeat && \
    chmod +x /filebeat/filebeat

# Copy Filebeat configuration
COPY filebeat.yml /filebeat/filebeat.yml

# Copy application entrypoint
COPY app_server.py /app_server.py

# Start both app and filebeat
CMD ["sh", "-c", "python3 /app_server.py & /filebeat/filebeat -e -c /filebeat/filebeat.yml"]
