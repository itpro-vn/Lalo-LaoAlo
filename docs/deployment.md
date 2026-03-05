# Hướng dẫn triển khai

## Yêu cầu

- Docker & Docker Compose
- Go 1.24.4+ (cho build từ source)
- Make

---

## Local Development

### 1. Khởi động infrastructure

```bash
make run-local
```

Lệnh này khởi động tất cả dependencies qua Docker Compose:

| Service    | Image                  | Port(s)       |
| ---------- | ---------------------- | ------------- |
| PostgreSQL | postgres:16-alpine     | 5432          |
| Redis      | redis:7-alpine         | 6379          |
| NATS       | nats:2-alpine          | 4222, 8222    |
| ClickHouse | clickhouse:24-alpine   | 8123, 9000    |
| coturn     | coturn:4.6-alpine      | 3478, 5349    |
| LiveKit    | livekit/livekit-server | 7880, 7881    |
| Nginx      | nginx:1.27-alpine      | 80, 443, 8888 |

### 2. Chạy database migrations

```bash
make migrate-up
```

### 3. Build services

```bash
# Build tất cả
make build

# Build từng service
make build-signaling
make build-orchestrator
make build-push
make build-policy
```

Output: `bin/signaling`, `bin/orchestrator`, `bin/push`, `bin/policy`

### 4. Chạy services

```bash
# Terminal 1
./bin/signaling    # :8080

# Terminal 2
./bin/orchestrator # :8081

# Terminal 3
./bin/push         # :8082
```

### 5. Dừng infrastructure

```bash
make stop-local
```

---

## Docker Deployment

### Build Docker images

```bash
make docker-build
```

### Docker Compose (Full Stack)

File: `docker-compose.yml`

```bash
docker-compose up -d
```

### Infrastructure Services

#### PostgreSQL

```yaml
postgres:
  image: postgres:16-alpine
  ports:
    - "5432:5432"
  environment:
    POSTGRES_USER: lalo
    POSTGRES_PASSWORD: lalo_dev
    POSTGRES_DB: lalo
  volumes:
    - postgres_data:/var/lib/postgresql/data
```

#### Redis

```yaml
redis:
  image: redis:7-alpine
  ports:
    - "6379:6379"
  command: redis-server --maxmemory 256mb --maxmemory-policy allkeys-lru
```

#### NATS

```yaml
nats:
  image: nats:2-alpine
  ports:
    - "4222:4222"
    - "8222:8222"
  command: -js -m 8222
```

JetStream được bật qua flag `-js`. Port 8222 là monitoring dashboard.

#### ClickHouse

```yaml
clickhouse:
  image: clickhouse/clickhouse-server:24-alpine
  ports:
    - "8123:8123" # HTTP interface
    - "9000:9000" # Native interface
  volumes:
    - clickhouse_data:/var/lib/clickhouse
```

#### coturn (TURN Server)

```yaml
coturn:
  image: coturn/coturn:4.6-alpine
  ports:
    - "3478:3478/udp"
    - "3478:3478/tcp"
    - "5349:5349/udp"
    - "5349:5349/tcp"
    - "49152-65535:49152-65535/udp"
  environment:
    TURN_SECRET: lalo-turn-dev-secret
  command: >
    turnserver
    --listening-port=3478
    --tls-listening-port=5349
    --static-auth-secret=${TURN_SECRET}
    --realm=call.lalo.dev
    --no-cli
    --no-tls
    --fingerprint
    --lt-cred-mech
    --verbose
```

#### LiveKit

```yaml
livekit:
  image: livekit/livekit-server:latest
  ports:
    - "7880:7880" # HTTP/WS
    - "7881:7881" # RTC (TCP)
    - "7882:7882/udp" # RTC (UDP)
  environment:
    LIVEKIT_KEYS: "devkey: secret"
```

Config: `deployments/livekit/livekit.yaml`

#### Nginx Gateway

```yaml
nginx:
  image: nginx:1.27-alpine
  ports:
    - "80:80"
    - "443:443"
    - "8888:8888"
  volumes:
    - ./deployments/nginx/nginx.conf:/etc/nginx/nginx.conf
    - ./deployments/nginx/certs:/etc/nginx/certs
```

Config: `deployments/nginx/nginx.conf`

---

## Production Deployment

### Environment Variables

Các biến cần thiết cho production:

```bash
# Database
LALO_POSTGRES_HOST=db.prod.lalo.dev
LALO_POSTGRES_PORT=5432
LALO_POSTGRES_USER=lalo
LALO_POSTGRES_PASSWORD=<strong-password>

# Redis
LALO_REDIS_ADDR=redis.prod.lalo.dev:6379

# NATS
LALO_NATS_URL=nats://nats.prod.lalo.dev:4222

# Auth
LALO_JWT_SECRET=<random-256-bit-secret>
LALO_TURN_SECRET=<random-secret>

# LiveKit
LALO_LIVEKIT_API_KEY=<livekit-key>
LALO_LIVEKIT_API_SECRET=<livekit-secret>

# Push Notifications
APNS_TEAM_ID=<apple-team-id>
APNS_KEY_ID=<apns-key-id>
APNS_KEY_PATH=/secrets/apns-key.p8
FCM_SERVER_KEY=<fcm-server-key>
FCM_PROJECT_ID=<firebase-project-id>
```

### Production Checklist

- [ ] **Secrets:** Không commit secrets vào git. Sử dụng vault/secrets manager
- [ ] **TLS:** Bật TLS cho tất cả connections
  - Nginx: TLS termination
  - coturn: TLS listening port 5349
  - PostgreSQL: `sslmode=require`
- [ ] **NATS JetStream:** Tăng replicas lên 3
- [ ] **coturn:** Cấu hình realm và external-ip cho production domain
- [ ] **LiveKit:** Production API keys
- [ ] **APNs:** Bật `production: true` trong push config
- [ ] **Rate limiting:** Review và adjust cho production load
- [ ] **Monitoring:** Setup Prometheus/Grafana cho metrics
- [ ] **Logging:** Structured JSON logging
- [ ] **Backups:** PostgreSQL automated backups
- [ ] **Health checks:** Cấu hình health checks cho load balancer

### TLS Certificates

```bash
# Generate self-signed certs cho development
make gen-certs

# Production: sử dụng Let's Encrypt hoặc cert provider
```

### Scaling

| Service       | Scaling Strategy             | Notes                               |
| ------------- | ---------------------------- | ----------------------------------- |
| Signaling     | Horizontal (sticky sessions) | WebSocket requires session affinity |
| Orchestrator  | Horizontal (stateless)       | Stateless REST API                  |
| Push Gateway  | Horizontal (stateless)       | Stateless                           |
| Policy Engine | Horizontal (stateless)       | Stateless                           |
| PostgreSQL    | Vertical / Read replicas     | Primary-replica setup               |
| Redis         | Cluster / Sentinel           | High availability                   |
| NATS          | Cluster (3+ nodes)           | Built-in clustering                 |
| ClickHouse    | Cluster                      | Sharding by region                  |
| coturn        | Multiple instances           | DNS round-robin                     |
| LiveKit       | Horizontal                   | Built-in room routing               |

---

## CI/CD

### GitHub Actions

File: `.github/workflows/ci.yml`

Pipeline:

1. **Lint:** `golangci-lint run ./...`
2. **Test:** `go test ./... -race -cover -count=1`
3. **Build:** Build tất cả service binaries

### Manual Commands

```bash
# Lint
make lint

# Test
make test

# Test (quick, no race detector)
make test-short

# Format
make fmt

# Tidy dependencies
make tidy

# Test TURN connectivity
make test-turn
```
