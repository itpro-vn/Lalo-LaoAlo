# Lalo — Adaptive Voice/Video Call System

Hệ thống voice/video call real-time cho mobile app, thiết kế cho 500k MAU. Sử dụng hybrid topology (P2P + SFU), adaptive bitrate, và toàn bộ stack open-source.

## Mục lục

- [Kiến trúc tổng quan](#kiến-trúc-tổng-quan)
- [Tech Stack](#tech-stack)
- [Cấu trúc thư mục](#cấu-trúc-thư-mục)
- [Backend (Go)](#backend-go)
- [Mobile (Flutter/Dart)](#mobile-flutterdart)
- [Database Schema](#database-schema)
- [Infrastructure](#infrastructure)
- [Cấu hình](#cấu-hình)
- [Phát triển local](#phát-triển-local)
- [Testing](#testing)
- [Tài liệu liên quan](#tài-liệu-liên-quan)

---

## Kiến trúc tổng quan

```
┌──────────────────────────────────────────────────────────────┐
│                     Flutter Mobile App                       │
│        (WebRTC, Push/CallKit, Signaling WebSocket)           │
└──────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌──────────────────────────────────────────────────────────────┐
│                    Gateway (Nginx)                            │
│                      :80 / :443                              │
└──────────────────────────────────────────────────────────────┘
                             │
           ┌─────────────────┼──────────────────┐
           ▼                 ▼                  ▼
  ┌──────────────┐  ┌───────────────┐  ┌──────────────┐
  │  Signaling   │  │ Orchestrator  │  │    Push      │
  │  (WebSocket) │  │   (REST)      │  │   Gateway    │
  │    :8080     │  │    :8081      │  │    :8082     │
  └──────┬───────┘  └──────┬────────┘  └──────┬───────┘
         │                 │                  │
         └─────────────────┼──────────────────┘
                           ▼
  ┌──────────┐  ┌────────┐  ┌──────┐  ┌────────────┐
  │ Postgres │  │ Redis  │  │ NATS │  │ ClickHouse │
  │  :5432   │  │ :6379  │  │:4222 │  │   :8123    │
  └──────────┘  └────────┘  └──────┘  └────────────┘
  ┌──────────┐  ┌────────────────┐
  │  coturn  │  │  LiveKit SFU   │
  │  :3478   │  │  :7880/:7881   │
  └──────────┘  └────────────────┘
```

**Topology cuộc gọi:**

| Loại         | Topology            | Khi nào                             |
| ------------ | ------------------- | ----------------------------------- |
| 1:1 call     | P2P (ICE direct)    | Mặc định, tối ưu chi phí            |
| 1:1 fallback | TURN relay (coturn) | Khi P2P fail (NAT strict, firewall) |
| Group call   | SFU (LiveKit)       | 3–8 participants                    |

---

## Tech Stack

| Layer              | Công nghệ              | Ghi chú                                     |
| ------------------ | ---------------------- | ------------------------------------------- |
| **Mobile**         | Flutter (Dart)         | iOS 15+ / Android API 26+                   |
| **WebRTC**         | flutter_webrtc ^0.12.0 | Wrap libwebrtc                              |
| **Native call UI** | callkeep               | CallKit (iOS) / ConnectionService (Android) |
| **Push**           | firebase_messaging     | APNs VoIP + FCM data message                |
| **Backend**        | Go 1.22+               | 4 microservices                             |
| **Signaling**      | gorilla/websocket      | JSON protocol qua WSS                       |
| **SFU**            | LiveKit OSS            | Self-hosted, simulcast support              |
| **TURN/STUN**      | coturn                 | Per-region deployment                       |
| **State**          | Redis 7.x              | Session + presence cache                    |
| **Database**       | PostgreSQL 16          | Users, call history, config                 |
| **Analytics**      | ClickHouse             | QoS metrics, CDR                            |
| **Event bus**      | NATS JetStream         | Internal event fanout                       |
| **Gateway**        | Nginx 1.27             | Reverse proxy, TLS termination              |

---

## Cấu trúc thư mục

```
Lalo/
├── cmd/                      # Go service entry points
│   ├── signaling/main.go     #   WebSocket signaling server (:8080)
│   ├── orchestrator/main.go  #   Session REST API (:8081)
│   ├── push/main.go          #   Push notification gateway (:8082)
│   └── policy/main.go        #   ABR policy evaluation service
│
├── internal/                 # Go application packages (private)
│   ├── auth/                 #   JWT, TURN credentials, LiveKit tokens
│   ├── config/               #   YAML config loading + env overrides
│   ├── session/              #   Call session lifecycle, CDR, topology
│   ├── signaling/            #   WebSocket hub, message routing, call flow
│   ├── push/                 #   Push notification gateway (APNs/FCM)
│   ├── events/               #   NATS JetStream event bus
│   ├── livekit/              #   LiveKit room management
│   ├── metrics/              #   QoS metrics writing (ClickHouse)
│   ├── models/               #   Shared types, Redis key conventions
│   ├── abr/                  #   Adaptive bitrate policy engine
│   ├── turn/                 #   TURN server health checks
│   ├── db/                   #   Postgres connection helper
│   └── policy/               #   Policy service (placeholder)
│
├── pkg/                      # Shared packages (public)
│
├── mobile/                   # Flutter mobile app
│   ├── lib/
│   │   ├── call/
│   │   │   ├── ui/           #   Screens: incoming, outgoing, active, group
│   │   │   ├── services/     #   Call, push, video slot, speaker detection
│   │   │   ├── webrtc/       #   Peer connection, ABR, quality monitoring
│   │   │   └── models/       #   Data models (call state, session, slots)
│   │   ├── core/
│   │   │   ├── auth/         #   Login, token management
│   │   │   ├── network/      #   API client, signaling WS, reconnection
│   │   │   ├── push/         #   Native push handler
│   │   │   ├── config/       #   App configuration
│   │   │   └── providers/    #   Riverpod providers
│   │   └── ui/               #   Home screen
│   └── test/                 #   Unit + integration tests
│
├── migrations/
│   ├── postgres/             # PostgreSQL migrations (001–005)
│   └── clickhouse/           # ClickHouse migrations (001)
│
├── configs/
│   └── call-config.yaml      # Call timing, quality tiers, ABR rules
│
├── deployments/              # Docker/K8s deployment configs
│   ├── docker-compose.yml
│   ├── nginx/                #   Gateway config
│   ├── coturn/               #   TURN server config
│   └── livekit/              #   SFU config
│
├── scripts/                  # Build/utility scripts
├── tests/                    # Test fixtures
├── docs/                     # Documentation
│   ├── technical-design-spec-v1.md
│   ├── schema.md
│   └── plan-pc01-multi-region.md
│
├── Makefile                  # Build automation
├── go.mod                    # Go dependencies
├── go.sum
└── docker-compose.yml        # Local dev infrastructure
```

---

## Backend (Go)

### 4 Microservices

#### 1. Signaling Server (`cmd/signaling` → `:8080`)

WebSocket server xử lý SDP/ICE exchange và call state machine.

**Packages chính:** `internal/signaling/`, `internal/auth/`

```
Client ──WSS──► Hub.Run() ──► handleCallInitiate()
                             ├── handleCallAccept()
                             ├── handleRoomCreate()   (group)
                             ├── handleRoomJoin()     (group)
                             └── startGracePeriod()   (reconnect)
```

- **Hub**: WebSocket routing hub, quản lý tất cả client connections
- **CallSession**: State machine cho mỗi cuộc gọi (IDLE → RINGING → CONNECTING → ACTIVE → ENDED)
- **Glare resolution**: Xử lý khi 2 người gọi nhau đồng thời
- **Grace period**: Cho phép reconnect khi mất kết nối tạm thời

#### 2. Session Orchestrator (`cmd/orchestrator` → `:8081`)

REST API quản lý call session lifecycle.

**Package chính:** `internal/session/`

| Function           | Mô tả                                                                 |
| ------------------ | --------------------------------------------------------------------- |
| `CreateSession()`  | Tạo 1:1 hoặc group call, lưu Redis + Postgres                         |
| `JoinSession()`    | Thêm participant, xử lý SFU escalation (2→3 người = chuyển P2P → SFU) |
| `LeaveSession()`   | Xóa participant, auto-end nếu trống                                   |
| `EndSession()`     | Kết thúc session, ghi CDR vào ClickHouse                              |
| `FallbackToTURN()` | Chuyển từ P2P sang TURN relay                                         |

**Key types:**

```go
type Session struct {
    ID           string
    CallType     string      // "1:1" | "group"
    Topology     Topology    // p2p | turn | sfu
    Participants []Participant
    StartedAt    time.Time
}

type Topology string // "p2p", "turn", "sfu"
type Role     string // "caller", "callee", "participant"
```

#### 3. Push Gateway (`cmd/push` → `:8082`)

Gửi push notification cho incoming calls.

**Package chính:** `internal/push/`

- **Sender interface**: Abstract APNs/FCM
- **APNsSender**: VoIP push qua PushKit (iOS) — trigger CallKit UI ngay lập tức
- **FCMSender**: High-priority data message (Android) — trigger ConnectionService
- **Gateway**: Route đến đúng platform dựa trên device token
- Subscribe NATS events → gửi push khi có cuộc gọi đến

#### 4. Policy Engine (`cmd/policy`)

Đánh giá ABR rules phía server.

**Package chính:** `internal/abr/`

```go
type QualityTier string  // "good", "fair", "poor"

type PolicyRule struct {
    Name       string
    Condition  string   // "avg_loss_above", "rtt_above", etc.
    Threshold  float64
    Action     string   // "cap_tier", "force_audio_only", etc.
}
```

### Shared Packages

| Package            | Mô tả                                                                    |
| ------------------ | ------------------------------------------------------------------------ |
| `internal/auth`    | JWT token pair (access + refresh), TURN credentials, LiveKit room tokens |
| `internal/config`  | Load YAML config, apply defaults, env overrides (`LALO_*`)               |
| `internal/events`  | NATS JetStream wrapper — publish/subscribe call events                   |
| `internal/models`  | Shared types, Redis key conventions (`session:{id}`, `user:{id}:calls`)  |
| `internal/db`      | PostgreSQL connection pool helper                                        |
| `internal/metrics` | Ghi QoS metrics vào ClickHouse                                           |

### Go Dependencies (trực tiếp)

```
github.com/golang-jwt/jwt/v5       # JWT tokens
github.com/google/uuid              # UUID generation
github.com/gorilla/websocket        # WebSocket
github.com/lib/pq                   # PostgreSQL driver
github.com/livekit/protocol         # LiveKit protocol types
github.com/livekit/server-sdk-go/v2 # LiveKit server SDK
github.com/nats-io/nats.go          # NATS client
github.com/redis/go-redis/v9        # Redis client
gopkg.in/yaml.v3                    # YAML parsing
```

---

## Mobile (Flutter/Dart)

### Kiến trúc

State management: **Riverpod** (StateNotifier pattern)

```
lib/
├── call/
│   ├── ui/
│   │   ├── incoming_call_screen.dart    # Màn hình cuộc gọi đến
│   │   ├── outgoing_call_screen.dart    # Màn hình đang gọi
│   │   ├── active_call_screen.dart      # Màn hình trong cuộc gọi
│   │   └── group_call_screen.dart       # Màn hình group call
│   │
│   ├── services/
│   │   ├── call_service.dart            # 1:1 call lifecycle
│   │   ├── group_call_service.dart      # Group call management
│   │   ├── push_service.dart            # Firebase/CallKit integration
│   │   ├── video_slot_controller.dart   # Active speaker → video slot
│   │   └── speaker_detection.dart       # Voice activity detection
│   │
│   ├── webrtc/
│   │   ├── peer_connection_manager.dart # WebRTC peer connection
│   │   ├── abr_controller.dart          # 2-loop adaptive bitrate
│   │   ├── quality_monitor.dart         # Network quality monitoring
│   │   └── audio_abr_policy.dart        # Opus audio ABR decisions
│   │
│   └── models/
│       ├── call_state.dart              # Call state enum + data
│       ├── session.dart                 # Session model
│       └── video_slot.dart              # Video slot model
│
├── core/
│   ├── auth/
│   │   └── auth_service.dart            # Login, JWT token refresh
│   ├── network/
│   │   ├── api_client.dart              # REST API client (Dio)
│   │   ├── signaling_client.dart        # WebSocket signaling
│   │   ├── network_monitor.dart         # Connectivity monitoring
│   │   └── reconnection_manager.dart    # Auto-reconnect logic
│   └── push/
│       └── push_handler.dart            # Native push → callkeep
│
└── ui/
    └── home_screen.dart
```

### Adaptive Bitrate (ABR) — Client-side

Two-loop adaptation system:

| Loop          | Cycle    | Làm gì                                                                 |
| ------------- | -------- | ---------------------------------------------------------------------- |
| **Fast loop** | 500ms–1s | Điều chỉnh bitrate, switch simulcast layer, giảm framerate             |
| **Slow loop** | 5–10s    | Đổi codec profile, điều chỉnh Opus complexity, reclassify network tier |

**Quality tiers:**

| Tier | RTT       | Packet Loss | Jitter  | Video                           |
| ---- | --------- | ----------- | ------- | ------------------------------- |
| Good | < 120ms   | < 2%        | < 20ms  | 720p/30fps, 1.2–2.0 Mbps        |
| Fair | 120–250ms | 2–6%        | 20–50ms | 360–480p/15–20fps, 400–900 kbps |
| Poor | > 250ms   | > 6%        | > 50ms  | 180–360p/12–15fps, 150–350 kbps |

### Group Call Video Slots

Max 8 participants, 4 video slots đồng thời:

| Slot | Quality   | Resolution             | Assignment                 |
| ---- | --------- | ---------------------- | -------------------------- |
| 1–2  | HQ        | 720p/30fps             | Active speaker hoặc pinned |
| 3–4  | MQ        | 360p/20fps             | Recent speakers            |
| 5–8  | LQ/Paused | 180p/10fps hoặc avatar | Remaining                  |

### Flutter Dependencies chính

```yaml
flutter_webrtc: ^0.12.0 # WebRTC
flutter_riverpod: ^2.5.0 # State management
firebase_messaging: ^15.0.0 # Push notifications
callkeep: ^0.4.1 # CallKit / ConnectionService
dio: ^5.4.0 # HTTP client
flutter_secure_storage: ^9.2.0 # Token storage
```

---

## Database Schema

### PostgreSQL

5 migration files (`migrations/postgres/`):

| Table               | Mô tả              | Key columns                                                                                               |
| ------------------- | ------------------ | --------------------------------------------------------------------------------------------------------- |
| `users`             | Người dùng         | `id` (UUID), `display_name`, `avatar_url`                                                                 |
| `call_configs`      | Cấu hình call      | `scope` (global/user), `config` (JSONB)                                                                   |
| `call_history`      | Lịch sử cuộc gọi   | `call_id`, `call_type` (1:1/group), `topology` (p2p/turn/sfu), `duration_seconds`, `end_reason`, `region` |
| `call_participants` | Participants       | `call_id`, `user_id`, `role` (caller/callee/participant), `joined_at`, `left_at`                          |
| `push_tokens`       | Device push tokens | `user_id`, `device_id`, `platform` (ios/android), `push_token`, `voip_token`                              |

### ClickHouse

1 migration file (`migrations/clickhouse/`):

| Table         | Mô tả                            | Key columns                                                                                                                                         |
| ------------- | -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `cdr`         | Call Detail Records (aggregated) | `call_id`, `duration`, `MOS`, `packet_loss`, `rtt`, `bitrate`, `tier_percentages`, `reconnect_count`                                                |
| `qos_metrics` | Per-second QoS samples           | `call_id`, `participant_id`, `ts`, `direction`, `rtt_ms`, `packet_loss_pct`, `jitter_ms`, `bitrate_kbps`, `framerate`, `resolution`, `network_tier` |

---

## Infrastructure

### docker-compose.yml — Local Dev

| Service      | Image                  | Ports                   | Mô tả                 |
| ------------ | ---------------------- | ----------------------- | --------------------- |
| `postgres`   | postgres:16-alpine     | 5432                    | Primary database      |
| `redis`      | redis:7-alpine         | 6379                    | Session cache         |
| `nats`       | nats:2-alpine          | 4222, 8222              | Event bus (JetStream) |
| `clickhouse` | clickhouse:24-alpine   | 8123, 9000              | Analytics/CDR         |
| `coturn`     | coturn:4.6-alpine      | 3478, 5349, 49152–49252 | TURN/STUN server      |
| `livekit`    | livekit/livekit-server | 7880, 7881, 50000–50060 | SFU                   |
| `gateway`    | nginx:1.27-alpine      | 80, 443, 8888           | Reverse proxy         |

### CI/CD

- **GitHub Actions**: Build + test + lint
- Deployment plan: xem `docs/plan-pc01-multi-region.md`

---

## Cấu hình

### configs/call-config.yaml

```yaml
call:
  ring_timeout_seconds: 45 # Thời gian đổ chuông tối đa
  ice_timeout_seconds: 15 # ICE connection timeout
  max_reconnect_attempts: 3 # Số lần reconnect tối đa

quality:
  tiers:
    good: { rtt_max_ms: 120, loss_max_pct: 2, jitter_max_ms: 20 }
    fair: { rtt_max_ms: 250, loss_max_pct: 6, jitter_max_ms: 50 }
    poor: { rtt_above_ms: 250, loss_above_pct: 6, jitter_above_ms: 50 }

group:
  max_participants: 8 # Tối đa 8 người/group
  active_video_slots: 4 # 4 video slots hiển thị
  hq_slots: 2 # 2 slots high quality
  mq_slots: 2 # 2 slots medium quality

turn:
  servers: ["turn:localhost:3478"]

push:
  apns: { bundle_id: "com.lalo.app" }
  fcm: { project_id: "" }

policy_engine:
  enabled: true
  rules:
    - name: high_loss_cap_fair
      condition: avg_loss_above
      threshold: 8.0
      action: cap_tier
      action_value: fair
```

### Environment Overrides

Config values có thể override bằng env vars với prefix `LALO_`:

```bash
LALO_POSTGRES_HOST=db.example.com
LALO_REDIS_HOST=redis.example.com
LALO_NATS_URL=nats://nats.example.com:4222
```

---

## Phát triển local

### Yêu cầu

- Go 1.22+
- Flutter SDK (stable channel)
- Docker + Docker Compose
- Make

### Khởi chạy

```bash
# 1. Start infrastructure
make run-local                  # docker-compose up -d

# 2. Run database migrations
make migrate-up                 # Postgres migrations
make seed                       # Seed data (optional)

# 3. Build Go services
make build                      # Build all → bin/

# 4. Run services (separate terminals)
./bin/signaling
./bin/orchestrator
./bin/push

# 5. Run Flutter app
cd mobile
flutter run
```

### Makefile targets

| Target                 | Mô tả                                                   |
| ---------------------- | ------------------------------------------------------- |
| `make build`           | Build tất cả service binaries                           |
| `make build-<service>` | Build 1 service (signaling, orchestrator, push, policy) |
| `make test`            | Chạy tests với race detector                            |
| `make test-short`      | Quick tests không race detector                         |
| `make lint`            | Chạy golangci-lint                                      |
| `make fmt`             | Format code (gofmt + goimports)                         |
| `make tidy`            | Go mod tidy                                             |
| `make clean`           | Xóa build artifacts                                     |
| `make docker-build`    | Build Docker images                                     |
| `make run-local`       | Start local dev environment                             |
| `make stop-local`      | Stop local environment                                  |
| `make migrate-up`      | Chạy Postgres migrations                                |
| `make migrate-down`    | Rollback migrations                                     |
| `make seed`            | Seed database                                           |
| `make gen-certs`       | Generate TLS certificates                               |
| `make test-turn`       | Test TURN connectivity                                  |

---

## Testing

### Go (Backend)

```bash
make test                       # All tests + race detector
make test-short                 # Quick tests
go test ./internal/session/...  # Test 1 package
go test -run TestCreateSession  # Test 1 function
```

**Test files:** colocated (`*_test.go` cùng package)

Các integration tests chính:

- `internal/signaling/group_integration_test.go` — Group call flow end-to-end

### Flutter (Mobile)

```bash
cd mobile
flutter test                              # All tests
flutter test test/call/webrtc/            # WebRTC tests
flutter test test/integration/            # Integration tests
```

**Test files:**

- `test/call/webrtc/audio_opus_config_test.dart` — Opus audio configuration
- `test/call/webrtc/two_loop_abr_test.dart` — Two-loop ABR controller
- `test/integration/` — End-to-end integration tests

---

## Call Flow tóm tắt

### 1:1 Call (P2P — happy path)

```
Caller                Signaling              Callee
  │── call_initiate ──►│                        │
  │                    │── Push notification ──►│
  │                    │◄── call_accept ────────│
  │◄── sdp_answer ─────│                        │
  │◄══ ICE exchange ══►│◄═════════════════════►│
  │◄═══════════ P2P media (DTLS-SRTP) ════════►│
```

### 1:1 Call (TURN fallback)

Khi ICE P2P fail (timeout 800ms), tự động chuyển sang TURN relay qua coturn.

### Group Call (SFU)

```
Host ── create_room ──► Orchestrator ──► LiveKit SFU
                        │── invite participants (push)
Participants ── join ──► SFU (with token)
                        │── simulcast publish (hi/mid/low)
                        │── selective forwarding per subscriber
```

### Reconnection

Khi mobile switch network (WiFi ↔ 4G):

1. Detect network change
2. ICE restart (new candidates)
3. New media path established
4. Target: < 2s interruption, max 3 attempts

---

## Tài liệu liên quan

| File                                                                   | Nội dung                                                                           |
| ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| [`docs/technical-design-spec-v1.md`](docs/technical-design-spec-v1.md) | Technical Design Spec chi tiết — capacity sizing, SLO/SLI, security, failure modes |
| [`docs/schema.md`](docs/schema.md)                                     | Database schema chi tiết                                                           |
| [`docs/plan-pc01-multi-region.md`](docs/plan-pc01-multi-region.md)     | Plan triển khai multi-region (Kubernetes, Terraform, Helm)                         |
| [`docs/Plan Tasks V1.md`](docs/Plan%20Tasks%20V1.md)                   | Task plan v1                                                                       |
| [`configs/call-config.yaml`](configs/call-config.yaml)                 | Cấu hình call quality, ABR rules                                                   |

---

## Design Decisions

| Quyết định                         | Lý do                                                                |
| ---------------------------------- | -------------------------------------------------------------------- |
| **LiveKit** thay vì mediasoup      | Go-native (cùng stack backend), K8s integration tốt hơn              |
| **coturn** thay vì cloud TURN      | Kiểm soát chi phí — cloud TURN tính per-GB, coturn là fixed infra    |
| **Go** cho backend                 | Low latency, concurrency tốt, cùng ecosystem LiveKit                 |
| **NATS** thay vì RabbitMQ          | Latency thấp hơn, ops đơn giản, JetStream đủ durability              |
| **ClickHouse** thay vì TimescaleDB | Nén tốt hơn cho high-cardinality QoS metrics                         |
| **Flutter** thay vì native         | Single codebase, iterate nhanh, flutter_webrtc wrap libwebrtc đủ tốt |
| **P2P preferred** cho 1:1          | Giảm 60% server bandwidth cost (P2P = 0 server BW)                   |
| **Hybrid topology**                | Cost/quality balanced — P2P khi được, SFU khi cần                    |
