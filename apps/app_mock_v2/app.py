#!/usr/bin/env python3
import logging
import time
import random
import threading
import xml.etree.ElementTree as ET
import os

LOG_DIR = '/var/log/app_mock'
os.makedirs(LOG_DIR, exist_ok=True)

FORMATTER = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')


def make_logger(name, filename):
    logger = logging.getLogger(name)
    logger.setLevel(logging.DEBUG)
    logger.propagate = False
    handler = logging.FileHandler(f'{LOG_DIR}/{filename}')
    handler.setFormatter(FORMATTER)
    logger.addHandler(handler)
    stdout = logging.StreamHandler()
    stdout.setFormatter(FORMATTER)
    logger.addHandler(stdout)
    return logger


# ── Message templates per service ─────────────────────────────────────────────

SERVICE_MESSAGES = {
    'main': {
        logging.INFO: [
            'Handling request GET /api/users [200 OK] {ms}ms',
            'User session created for user_id={uid}',
            'Cache hit for key=config_data TTL=300s',
            'Health check passed',
            'Connected to database successfully',
        ],
        logging.WARNING: [
            'Response time elevated: {ms}ms for GET /api/reports',
            'Memory usage at {pct}%, approaching threshold',
            'Retrying database connection (attempt {n}/3)',
        ],
        logging.ERROR: [
            'Failed to process request POST /api/orders: Connection refused',
            'Database query timeout after 5000ms',
            'Unhandled exception in request handler: NullPointerException',
        ],
    },
    'worker': {
        logging.INFO: [
            'Processing job_id={jid} type=email_notification',
            'Job completed successfully job_id={jid} duration={dur}s',
            'Queue size: {q} jobs pending',
            'Batch processed: {n} records in {dur}s',
        ],
        logging.WARNING: [
            'Job retry attempt {n}/3 for job_id={jid}',
            'Queue size growing: {q} jobs pending',
            'Worker thread response slow: {ms}ms',
        ],
        logging.ERROR: [
            'Job failed job_id={jid}: Max retries exceeded',
            'Worker thread unresponsive, restarting',
            'Failed to connect to message queue: ECONNREFUSED',
        ],
    },
    'scheduler': {
        logging.INFO: [
            'Executing scheduled task: daily_report',
            'Task completed: cleanup_temp_files duration={dur}s',
            'Next run scheduled in {n} minutes',
        ],
        logging.WARNING: [
            'Task daily_summary delayed by {n} minutes',
            'Scheduled task report_generator skipped: previous run still active',
            'Execution took longer than expected: {ms}ms',
        ],
        logging.ERROR: [
            'Task failed: db_backup error=Disk full',
            'Missed scheduled execution window for task: hourly_metrics',
            'Scheduler thread crashed, attempting recovery',
        ],
    },
}

LEVEL_WEIGHTS = {
    logging.INFO:    70,
    logging.WARNING: 20,
    logging.ERROR:   10,
}


def random_message(service, level):
    template = random.choice(SERVICE_MESSAGES[service][level])
    return template.format(
        ms=random.randint(50, 1200),
        uid=random.randint(1000, 9999),
        pct=random.randint(65, 95),
        n=random.randint(1, 3),
        jid=''.join(random.choices('abcdef0123456789', k=8)),
        dur=round(random.uniform(0.1, 5.0), 2),
        q=random.randint(1, 100),
    )


def run_service(name, interval, logger):
    levels = list(LEVEL_WEIGHTS.keys())
    weights = list(LEVEL_WEIGHTS.values())
    while True:
        level = random.choices(levels, weights=weights, k=1)[0]
        logger.log(level, random_message(name, level))
        time.sleep(interval + random.uniform(-2, 2))


def load_config():
    tree = ET.parse('/app/config/app.xml')
    root = tree.getroot()
    return {
        'name': root.find('name').text,
        'version': root.find('version').text,
        'environment': root.find('environment').text,
    }


def load_db_config():
    tree = ET.parse('/app/config/db/datasource.xml')
    root = tree.getroot()
    ds = root.find('datasource')
    return {
        'name': ds.find('name').text,
        'driver': ds.find('driver').text,
        'url': ds.find('url').text,
    }


def main():
    config = load_config()
    db_config = load_db_config()

    app_logger = make_logger(config['name'], 'app.log')
    app_logger.info(f"Starting {config['name']} v{config['version']} in {config['environment']}")
    app_logger.info(f"Database: {db_config['name']} ({db_config['driver']})")

    services = [
        {'name': 'main',      'interval': 10},
        {'name': 'worker',    'interval': 15},
        {'name': 'scheduler', 'interval': 20},
    ]

    for svc in services:
        svc_logger = make_logger(f"{config['name']}.{svc['name']}", f"{svc['name']}.log")
        t = threading.Thread(
            target=run_service,
            args=(svc['name'], svc['interval'], svc_logger),
            daemon=True,
        )
        t.start()
        app_logger.info(f"Service '{svc['name']}' started -> {svc['name']}.log")

    try:
        while True:
            time.sleep(60)
    except KeyboardInterrupt:
        app_logger.info(f"Shutting down {config['name']}")


if __name__ == '__main__':
    main()
