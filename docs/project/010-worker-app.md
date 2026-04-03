# Worker App: Data Seeding and Infrastructure Health Checks

The worker app provides HTTP endpoints for data seeding operations and infrastructure health verification. It serves as a background service that validates connectivity to core infrastructure components (MongoDB, RabbitMQ, Valkey) and provides data seeding capabilities for testing and initialization.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [HTTP Endpoints](#http-endpoints)
- [Configuration](#configuration)
- [Deployment](#deployment)
- [Health Checks](#health-checks)
- [Data Seeding](#data-seeding)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)

---

## Overview

The worker app is a Go-based HTTP service that runs as a systemd unit. It provides:

- **Infrastructure Health Checks**: Real-time status verification for MongoDB, RabbitMQ, and Valkey connections
- **Data Seeding**: POST endpoint to populate test data in MongoDB
- **Graceful Shutdown**: Proper connection cleanup and 10-second shutdown timeout
- **Structured Logging**: JSON-formatted logs with configurable log levels

### Use Cases

- **CI/CD Pipelines**: Verify infrastructure connectivity before deploying other services
- **Monitoring**: External health check endpoints for load balancers and monitoring systems
- **Testing**: Seed test data for integration tests
- **Operations**: Quick infrastructure validation during deployments

---

## Architecture

```mermaid
flowchart TB
    subgraph HTTP["HTTP Server (Port 8001)"]
        direction TB
        ROOT["GET /"]
        HEALTH["GET /health"]
        MONGO["GET /status/mongodb"]
        RMQ["GET /status/rabbitmq"]
        VALKEY["GET /status/valkey"]
        SEED["POST /seed"]
    end

    subgraph Managers["Connection Managers"]
        MM[MongoDB Manager]
        RM[RabbitMQ Manager]
        VM[Valkey Manager]
    end

    subgraph Infra["Infrastructure"]
        MDB[(MongoDB)]
        RMQ[(RabbitMQ)]
        VK[(Valkey)]
    end

    HTTP --> Managers
    Managers --> Infra

    ROOT --> |"Hello from worker"| HTTP
    HEALTH --> |"OK"| HTTP
    MONGO --> MM
    RMQ --> RM
    VALKEY --> VM
    SEED --> MM
```

### Connection Managers

Each infrastructure component has a dedicated connection manager with:

- **Connection Pooling**: Efficient resource management
- **Health Verification**: Ping/check operations with timeouts
- **Graceful Cleanup**: Proper connection closure on shutdown
- **Error Handling**: Detailed error reporting

---

## HTTP Endpoints

### GET /

Basic service information endpoint.

**Response:**
```json
{
  "service": "worker",
  "version": "dev",
  "description": "Data seeding and infrastructure verification service"
}
```

### GET /health

Simple health check endpoint for load balancers.

**Response:** `200 OK` with body `"OK"`

### GET /status/mongodb

MongoDB connection status and version information.

**Response:**
```json
{
  "status": "connected|error|disconnected",
  "database": "testboot",
  "version": "7.0.8",
  "collections": ["users"]
}
```

### GET /status/rabbitmq

RabbitMQ connection status and server properties.

**Response:**
```json
{
  "status": "connected|error|disconnected",
  "channels": 1,
  "server_properties": {
    "product": "RabbitMQ",
    "version": "3.12.13"
  }
}
```

### GET /status/valkey

Valkey connection status and ping response.

**Response:**
```json
{
  "status": "connected|error|disconnected",
  "database": 0,
  "ping": "PONG"
}
```

### POST /seed

Seeds test data into MongoDB collections.

**Request Body:**
```json
{
  "count": 100
}
```

**Response:**
```json
{
  "seeded": 100,
  "collection": "users"
}
```

---

## Configuration

Configuration is loaded from environment variables with a 3-tier hierarchy:

### Tier 1: Immutable Defaults (Image-Versioned)

Located at `/usr/share/bootc-testboot/worker/worker.env`:

```bash
# Service configuration
LISTEN_ADDR=127.0.0.1:8001
LOG_LEVEL=INFO

# Infrastructure URIs (defaults for development)
MONGODB_URI=mongodb://localhost:27017
MONGODB_NAME=testboot
RABBITMQ_URI=amqp://guest:guest@localhost:5672/
RABBITMQ_QUEUE=testboot
VALKEY_ADDR=localhost:6379
VALKEY_DB=0
```

### Tier 2: Shared Infrastructure Secrets

Located at `/var/lib/bootc-testboot/shared/env/`:

- `mongodb.env`: MongoDB connection credentials
- `rabbitmq.env`: RabbitMQ connection credentials
- `valkey.env`: Valkey connection credentials

### Tier 3: Per-App Secret Overrides

Located at `/var/lib/bootc-testboot/worker/worker.secrets.overrides`:

Override any configuration from tiers 1-2 for production-specific settings.

---

## Deployment

### Systemd Unit

The worker service is deployed via systemd unit at `/usr/lib/systemd/system/worker.service`:

```systemd
[Unit]
Description=Worker Service - Data Seeding and Infrastructure Verification
After=network-online.target testboot-app-setup.service
Wants=network-online.target testboot-app-setup.service

[Service]
Type=simple
User=worker
Group=worker
StateDirectory=bootc-testboot/worker
LogsDirectory=bootc-testboot/worker
Environment=LOG_FILE=/var/log/bootc-testboot/worker/worker.log

# Configuration tiers
EnvironmentFile=/usr/share/bootc-testboot/worker/worker.env
EnvironmentFile=-/var/lib/bootc-testboot/shared/env/mongodb.env
EnvironmentFile=-/var/lib/bootc-testboot/shared/env/rabbitmq.env
EnvironmentFile=-/var/lib/bootc-testboot/shared/env/valkey.env
EnvironmentFile=-/var/lib/bootc-testboot/worker/worker.secrets.overrides

ExecStart=/usr/bin/worker

# Health check after start
ExecStartPost=/usr/bin/env LOG_FILE=/var/log/bootc-testboot/worker/healthcheck.log \
  /usr/libexec/testboot/healthcheck.sh http://127.0.0.1:8001/health 10
```

### File System Layout

```
/usr/bin/worker                              # Binary
/usr/lib/systemd/system/worker.service        # Systemd unit
/usr/share/bootc-testboot/worker/worker.env   # Default config
/var/lib/bootc-testboot/worker/               # State directory
/var/log/bootc-testboot/worker/               # Logs
```

### User and Permissions

- **User**: `worker` (created via sysusers.d)
- **Group**: `worker`
- **Directories**: Created via tmpfiles.d on first boot

---

## Health Checks

### Infrastructure Health Verification

All status endpoints perform real connectivity checks with 2-second timeouts:

- **MongoDB**: `ping` command + version check
- **RabbitMQ**: Channel creation + server properties
- **Valkey**: `PING` command

### Service Health Check

The `/health` endpoint is used by systemd for service monitoring and load balancer health checks.

### Startup Health Check

After service start, a health check script verifies the service is responding within 10 seconds.

---

## Data Seeding

### POST /seed Endpoint

Seeds mock user data into MongoDB for testing purposes.

**Features:**
- Generates unique user records with realistic data
- Configurable count (default: 100)
- Validates MongoDB connectivity before seeding
- Returns seeding statistics

**Generated Data Structure:**
```json
{
  "id": "uuid",
  "name": "Generated Name",
  "email": "user@example.com",
  "created_at": "2024-01-01T00:00:00Z"
}
```

### Usage in Testing

```bash
# Seed 50 test users
curl -X POST http://localhost:8001/seed \
  -H "Content-Type: application/json" \
  -d '{"count": 50}'
```

---

## Testing

### Unit Tests

Run Go unit tests:

```bash
cd repos/worker
go test -v
```

Tests cover:
- Configuration loading
- Mock data generation
- HTTP handler responses

### Integration Tests

Test with real infrastructure:

```bash
# Test all status endpoints
curl http://localhost:8001/status/mongodb
curl http://localhost:8001/status/rabbitmq
curl http://localhost:8001/status/valkey

# Test data seeding
curl -X POST http://localhost:8001/seed -d '{"count": 10}'
```

### Smoke Tests

Included in project-wide smoke testing:

```bash
make test-smoke EXPECTED_BINS="hello worker" EXPECTED_SVCS="hello worker nginx"
```

---

## Troubleshooting

#### MongoDB Connection Issues

**"unescaped slash in password" error:**
```
time=2026-04-03T11:25:45.925Z level=ERROR msg="mongodb connect failed" err="error parsing uri: unescaped slash in password"
```

**Root cause:** Password contains special characters (like `/`) that aren't URL-encoded in the MongoDB URI.

**Solution:** The worker app automatically URL-encodes passwords in MongoDB URIs. If you still see this error:
- Check `/var/lib/bootc-testboot/shared/env/mongodb.env` for the `MONGODB_URI`
- Ensure the URI is properly formatted: `mongodb://user:pass@host:port/db`
- The app handles URL encoding automatically - no manual intervention needed

**Manual verification:**
```bash
# Test URI parsing (should not show the error)
curl http://127.0.0.1:8001/status/mongodb
```

#### RabbitMQ Connection Issues

**"connection refused" or authentication errors:**
```
Check RabbitMQ service: systemctl status rabbitmq-server
Verify credentials in /var/lib/bootc-testboot/shared/env/rabbitmq.env
Test manual connection: rabbitmqctl status
```

#### Valkey Connection Issues

**"connection refused" error:**
```
Check Valkey service: systemctl status valkey
Verify connection in /var/lib/bootc-testboot/shared/env/valkey.env
Test manual connection: redis-cli ping
```

#### Service Not Starting

**Check systemd status:**
```bash
systemctl status worker
journalctl -u worker -f
```

**Check logs:**
```bash
tail -f /var/log/bootc-testboot/worker/worker.log
```

#### Health Check Failures

**Debug health checks:**
```bash
# Manual health check
curl http://127.0.0.1:8001/health

# Check startup health check logs
tail -f /var/log/bootc-testboot/worker/healthcheck.log
```

### Log Analysis

Logs are structured JSON. Filter by level:

```bash
# Errors only
jq 'select(.level == "ERROR")' /var/log/bootc-testboot/worker/worker.log

# Connection events
jq 'select(.msg | contains("connect"))' /var/log/bootc-testboot/worker/worker.log
```

### Performance Monitoring

Monitor connection pool usage and response times:

```bash
# Response time check
time curl http://localhost:8001/status/mongodb

# Connection pool status (via logs)
grep "connection pool" /var/log/bootc-testboot/worker/worker.log
```