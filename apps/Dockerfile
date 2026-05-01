FROM python:3.11-slim

WORKDIR /app

# Copy application files (will be mounted at runtime via volumes)
# Files are mounted from host via docker-compose volumes

# Create log directory
RUN mkdir -p /var/log/app_mock && chmod 777 /var/log/app_mock

# Download and install Filebeat
RUN apt-get update && apt-get install -y curl && \
    curl -L -O https://artifacts.elastic.co/downloads/beats/filebeat/filebeat-8.12.2-linux-arm64.tar.gz && \
    tar xzf filebeat-8.12.2-linux-arm64.tar.gz && \
    rm filebeat-8.12.2-linux-arm64.tar.gz && \
    mv filebeat-8.12.2-linux-arm64 /filebeat && \
    chmod +x /filebeat/filebeat

# Copy Filebeat configuration
COPY apps/filebeat.yml /filebeat/filebeat.yml

# Make app.py executable
#RUN chmod +x /app/app.py

# Start both app and filebeat
CMD ["sh", "-c", "python3 /app/app.py & /filebeat/filebeat -e -c /filebeat/filebeat.yml"]
