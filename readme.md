# Firefly III Docker Setup

This repository provides a Docker-based setup for [Firefly III](https://www.firefly-iii.org/), a free and open-source personal finance manager. It simplifies the deployment and management of Firefly III and includes scripts for automated backups to AWS S3 and restoration.

## Features

*   **Docker Compose Deployment:** Easily deploy Firefly III and its MariaDB database using Docker Compose.
*   **Automated Dependency Installation:** The `init.sh` script handles the installation of Docker, Docker Compose, Git, and AWS CLI.
*   **Automated Daily Backups:** The `scripts/backup.sh` script, combined with `setup-cron.sh`, sets up a daily cron job to back up Firefly III's database and upload volumes to a specified S3 bucket.
*   **Backup Restoration:** The `scripts/restore.sh` script allows you to download and restore a previous backup from S3.

## Getting Started

### Prerequisites

Ensure you have a Linux environment. The `init.sh` script will attempt to install the necessary tools:
*   Docker
*   Docker Compose
*   Git
*   AWS CLI

### Initial Setup

1.  **Run the Initialization Script:**
    ```bash
    sudo ./init.sh
    ```
    This script will install all required dependencies.

2.  **Configure AWS CLI:**
    After `init.sh` completes, configure your AWS CLI with your credentials:
    ```bash
    aws configure
    ```

3.  **Create Environment Files:**
    Create the following environment files in the root directory of this project:
    *   `.env`: For Firefly III application settings. Refer to the [Firefly III documentation](https://docs.firefly-iii.org/firefly-iii/installation/docker/) for required variables.
    *   `.db.env`: For MariaDB database settings (e.g., `MYSQL_ROOT_PASSWORD`, `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD`).
    *   `.s3.env`: For S3 backup configuration. This file should contain:
        ```
        S3_ACCESS_KEY="YOUR_AWS_ACCESS_KEY_ID"
        S3_SECRET_KEY="YOUR_AWS_SECRET_ACCESS_KEY"
        S3_REGION="your-aws-region"
        S3_BUCKET="your-s3-bucket-name"
        S3_ENDPOINT="https://s3.your-region.amazonaws.com" # Optional, for custom S3 endpoints
        ```

4.  **Create Docker Network:**
    ```bash
    docker network create firefly
    ```

5.  **Start Firefly III Services:**
    ```bash
    docker-compose up -d
    ```

6.  **Set up Cron Backup (Optional but Recommended):**
    ```bash
    sudo ./setup-cron.sh
    ```
    This will configure a daily cron job to run the backup script.

## Usage

### Starting the Application

To start Firefly III and its database:
```bash
docker-compose up -d
```

### Stopping the Application

To stop Firefly III and its database:
```bash
docker-compose down
```

### Manual Backup

To perform a manual backup to S3:
```bash
./scripts/backup.sh
```

### Restoring from Backup

To restore Firefly III from an S3 backup:
```bash
./scripts/restore.sh <backup_filename>
```
Replace `<backup_filename>` with the name of the backup file in your S3 bucket (e.g., `firefly_backup_20250812_030000.tar.gz`).

**WARNING:** Restoring will stop the containers, remove existing volumes, and replace them with data from the backup.
