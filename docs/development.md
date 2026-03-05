# Hướng dẫn phát triển

## Yêu cầu

- **Go:** 1.24.4+
- **Docker & Docker Compose:** Cho infrastructure
- **Make:** Build automation
- **golangci-lint:** Linting (tự động cài qua CI)

---

## Setup môi trường

### 1. Clone repository

```bash
git clone https://github.com/itpro-vn/Lalo-LaoAlo.git
cd lalo
```

### 2. Install dependencies

```bash
go mod download
make tidy
```

### 3. Khởi động infrastructure

```bash
make run-local
```

### 4. Chạy migrations

```bash
make migrate-up
```

### 5. Build & chạy

```bash
make build
./bin/signaling    # Terminal 1
./bin/orchestrator # Terminal 2
./bin/push         # Terminal 3
```

---

## Cấu trúc dự án

```
Lalo/
├── cmd/                         # Service entry points
│   ├── signaling/main.go        # :8080 - WebSocket signaling
│   ├── orchestrator/main.go     # :8081 - REST API
│   ├── push/main.go             # :8082 - Push notifications
│   └── policy/main.go           # ABR policy engine
│
├── internal/                    # Private application packages
│   ├── auth/                    # JWT, TURN credentials, LiveKit tokens
│   │   ├── jwt.go               # JWT token generation & validation
│   │   ├── turn.go              # TURN credential generation (HMAC-SHA1)
│   │   ├── livekit_token.go     # LiveKit room token generation
│   │   └── middleware.go        # JWT authentication middleware
│   │
│   ├── config/                  # Configuration loading
│   │   └── config.go            # YAML + env override loading
│   │
│   ├── session/                 # Call session management
│   │   ├── orchestrator.go      # HTTP handlers cho session API
│   │   ├── service.go           # Business logic
│   │   └── cdr.go               # Call Detail Record creation
│   │
│   ├── signaling/               # WebSocket signaling
│   │   ├── hub.go               # Connection hub management
│   │   ├── handler.go           # WebSocket message handler
│   │   ├── messages.go          # Message types & envelopes
│   │   ├── flow.go              # 1:1 call flow logic
│   │   └── room_flow.go         # Group call flow logic
│   │
│   ├── push/                    # Push notification gateway
│   │   ├── gateway.go           # Main push gateway logic
│   │   ├── handler.go           # HTTP handlers
│   │   ├── apns.go              # Apple Push Notification Service
│   │   ├── fcm.go               # Firebase Cloud Messaging
│   │   ├── store.go             # Token storage
│   │   └── types.go             # Types & models
│   │
│   ├── events/                  # NATS JetStream event bus
│   │   ├── bus.go               # Event publisher/subscriber
│   │   └── subjects.go          # Event subject constants
│   │
│   ├── livekit/                 # LiveKit SFU integration
│   │   └── client.go            # Room management
│   │
│   ├── metrics/                 # QoS metrics
│   │   └── writer.go            # ClickHouse writer
│   │
│   ├── models/                  # Shared types
│   │   ├── types.go             # Common types
│   │   └── redis_keys.go        # Redis key conventions
│   │
│   ├── abr/                     # Adaptive Bitrate
│   │   ├── engine.go            # Policy evaluation engine
│   │   ├── rules.go             # Policy rules
│   │   └── types.go             # Types & decisions
│   │
│   ├── turn/                    # TURN server
│   │   └── health.go            # Health check
│   │
│   └── db/                      # Database
│       └── postgres.go          # PostgreSQL connection
│
├── configs/
│   └── call-config.yaml         # Main configuration file
│
├── migrations/
│   ├── postgres/                # PostgreSQL migrations (001-005)
│   └── clickhouse/              # ClickHouse migrations
│
├── deployments/
│   ├── docker-compose.yml       # Production compose
│   ├── nginx/                   # Nginx configuration
│   ├── coturn/                  # TURN server config
│   └── livekit/                 # LiveKit config
│
├── scripts/                     # Utility scripts
├── tests/                       # Test fixtures
├── docs/                        # Tài liệu
│
├── Makefile                     # Build automation
├── go.mod                       # Go module definition
├── go.sum                       # Dependency checksums
├── docker-compose.yml           # Local dev infrastructure
├── .golangci.yml                # Lint configuration
└── .github/workflows/ci.yml    # CI pipeline
```

---

## Coding Conventions

### Go Style

- **Formatter:** `gofmt` + `goimports`
- **Linter:** `golangci-lint` với nhiều linters (xem `.golangci.yml`)
- **Comments:** Vietnamese comments được chấp nhận
- **Error handling:** Luôn xử lý errors, không dùng `_`
- **Naming:** camelCase cho local vars, PascalCase cho exports

### Linting

```bash
# Chạy linter
make lint

# Format code
make fmt
```

Enabled linters:

- `errcheck` — Kiểm tra error handling
- `govet` — Go vet checks
- `staticcheck` — Static analysis
- `gosec` — Security checks
- `gocritic` — Style & performance
- `misspell` — Spelling
- `revive` — General purpose
- `prealloc` — Slice preallocation
- `unconvert` — Unnecessary conversions
- `unparam` — Unused parameters

### Project Conventions

- **Không commit secrets** hoặc `.env` files
- **Không force push** to main
- **Chạy tests** trước khi claim work is done
- **Không sửa `dist/`** trực tiếp — nó được tạo bởi build process

---

## Make Targets

| Target                 | Mô tả                                  |
| ---------------------- | -------------------------------------- |
| `make build`           | Build tất cả service binaries → `bin/` |
| `make build-<service>` | Build một service cụ thể               |
| `make test`            | Chạy tất cả tests với race detector    |
| `make test-short`      | Chạy tests nhanh (không race detector) |
| `make lint`            | Chạy golangci-lint                     |
| `make fmt`             | Format code                            |
| `make tidy`            | Go mod tidy                            |
| `make clean`           | Xóa build artifacts                    |
| `make docker-build`    | Build Docker images                    |
| `make run-local`       | Khởi động local infrastructure         |
| `make stop-local`      | Dừng local infrastructure              |
| `make migrate-up`      | Chạy database migrations               |
| `make migrate-down`    | Rollback migrations                    |
| `make seed`            | Seed database                          |
| `make gen-certs`       | Generate TLS certificates              |
| `make test-turn`       | Test TURN connectivity                 |

---

## Dependencies chính

| Package                               | Version | Mô tả                    |
| ------------------------------------- | ------- | ------------------------ |
| `github.com/gorilla/websocket`        | -       | WebSocket implementation |
| `github.com/livekit/protocol`         | -       | LiveKit protocol types   |
| `github.com/livekit/server-sdk-go/v2` | -       | LiveKit Go SDK           |
| `github.com/nats-io/nats.go`          | -       | NATS client              |
| `github.com/redis/go-redis/v9`        | -       | Redis client             |
| `github.com/lib/pq`                   | -       | PostgreSQL driver        |
| `github.com/golang-jwt/jwt/v5`        | -       | JWT token library        |
| `github.com/google/uuid`              | -       | UUID generation          |
| `gopkg.in/yaml.v3`                    | -       | YAML parsing             |

---

## Thêm service mới

1. Tạo entry point: `cmd/<service>/main.go`
2. Tạo package: `internal/<service>/`
3. Cập nhật `Makefile` — thêm build target
4. Cập nhật `docker-compose.yml` nếu cần
5. Cập nhật `Dockerfile` nếu cần
6. Thêm health check endpoint: `GET /health`

### Template entry point

```go
package main

import (
    "log"
    "net/http"

    "github.com/minhgv/lalo/internal/config"
)

func main() {
    cfg, err := config.Load("configs/call-config.yaml")
    if err != nil {
        log.Fatalf("failed to load config: %v", err)
    }

    // Initialize dependencies
    // ...

    // Setup routes
    mux := http.NewServeMux()
    mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
        w.Write([]byte(`{"status":"ok"}`))
    })

    // Start server
    addr := fmt.Sprintf("%s:%d", cfg.Server.Host, cfg.Server.Port)
    log.Printf("starting server on %s", addr)
    log.Fatal(http.ListenAndServe(addr, mux))
}
```

---

## Debugging

### WebSocket testing

Sử dụng `websocat` hoặc browser console:

```bash
# Install websocat
brew install websocat

# Connect
websocat ws://localhost:8080/ws?token=<jwt>

# Send ping
{"type": "ping"}
```

### NATS monitoring

```bash
# NATS dashboard
open http://localhost:8222

# List streams
nats stream ls

# View stream info
nats stream info CALLS
```

### Redis inspection

```bash
redis-cli -h localhost -p 6379

# List active sessions
KEYS session:*

# View session details
HGETALL session:<session_id>
```

### ClickHouse queries

```bash
clickhouse-client -h localhost

# Recent CDRs
SELECT * FROM cdr ORDER BY started_at DESC LIMIT 10;

# QoS metrics for a call
SELECT * FROM qos_metrics WHERE call_id = '<uuid>' ORDER BY ts;
```

---

## Git Workflow

1. **Branch naming:** `feat/<description>`, `fix/<description>`, `chore/<description>`
2. **Commit messages:** Conventional commits (`feat:`, `fix:`, `test:`, `refactor:`, `chore:`)
3. **Pre-commit:** Chạy `make lint` và `make test`
4. **PR:** Tạo PR vào `main`, yêu cầu CI pass
