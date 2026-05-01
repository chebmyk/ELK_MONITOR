#!/usr/bin/env python3
import logging
import time
import xml.etree.ElementTree as ET
import os
from datetime import datetime

# Setup logging
log_dir = '/var/log/app_mock'
os.makedirs(log_dir, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(f'{log_dir}/app.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger('app_mock')

# Load config
def load_config():
    config_file = '/app/config/app.xml'
    tree = ET.parse(config_file)
    root = tree.getroot()
    return {
        'name': root.find('name').text,
        'version': root.find('version').text,
        'environment': root.find('environment').text
    }

# Load database config
def load_db_config():
    db_config_file = '/app/config/db/datasource.xml'
    tree = ET.parse(db_config_file)
    root = tree.getroot()
    datasource = root.find('datasource')
    return {
        'name': datasource.find('name').text,
        'driver': datasource.find('driver').text,
        'url': datasource.find('url').text
    }

def main():
    config = load_config()
    db_config = load_db_config()
    
    logger.info(f"Starting {config['name']} v{config['version']} in {config['environment']} environment")
    logger.info(f"Database: {db_config['name']} ({db_config['driver']})")
    
    counter = 0
    try:
        while True:
            counter += 1
            logger.info(f"[{config['name']}] Heartbeat #{counter} - Processing request at {datetime.now().isoformat()}")
            time.sleep(30)
    except KeyboardInterrupt:
        logger.info(f"Shutting down {config['name']}")

if __name__ == '__main__':
    main()
