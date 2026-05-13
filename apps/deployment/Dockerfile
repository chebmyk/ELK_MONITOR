FROM python:3.11-slim

WORKDIR /app

# app_server.py is baked into the image; config files are mounted at /app at runtime

# Create log directory
RUN mkdir -p /var/log/app_mock && chmod 777 /var/log/app_mock

# Download and install Filebeat — auto-detect arch (amd64 or arm64)
RUN set -eux; \
    ARCH="$(uname -m)"; \
    case "$ARCH" in \
      x86_64)  FB_ARCH=amd64 ;; \
      aarch64) FB_ARCH=arm64 ;; \
      *) echo "Unsupported architecture: $ARCH" && exit 1 ;; \
    esac; \
    apt-get update && apt-get install -y curl && \
    curl -L -O "https://artifacts.elastic.co/downloads/beats/filebeat/filebeat-8.12.2-linux-${FB_ARCH}.tar.gz" && \
    tar xzf "filebeat-8.12.2-linux-${FB_ARCH}.tar.gz" && \
    rm "filebeat-8.12.2-linux-${FB_ARCH}.tar.gz" && \
    mv "filebeat-8.12.2-linux-${FB_ARCH}" /filebeat && \
    chmod +x /filebeat/filebeat

# Copy Filebeat configuration
COPY filebeat.yml /filebeat/filebeat.yml

# Copy application entrypoint
COPY app_server.py /app_server.py

# Start both app and filebeat
CMD ["sh", "-c", "python3 /app_server.py & /filebeat/filebeat -e -c /filebeat/filebeat.yml"]
