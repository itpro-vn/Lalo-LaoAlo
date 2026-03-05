# Lalo - Adaptive Voice/Video Call System

## Tổng quan

Lalo là hệ thống cuộc gọi thoại/video thích ứng (adaptive voice/video call) được thiết kế cho quy mô 500k MAU. Hệ thống hỗ trợ cuộc gọi 1:1 (P2P/TURN) và cuộc gọi nhóm (SFU qua LiveKit), với khả năng tự động điều chỉnh chất lượng dựa trên điều kiện mạng.

## Kiến trúc tổng quan

```
┌─────────────┐     ┌──────────────┐     ┌───────────────┐
│  Mobile App │────▶│   Nginx GW   │────▶│  Signaling    │ :8080
│  (Flutter)  │     │  :80/:443    │     │  (WebSocket)  │
└─────────────┘     └──────────────┘     └───────┬───────┘
                           │                     │
                           ▼                     ▼
                    ┌──────────────┐     ┌───────────────┐
                    │ Orchestrator │     │     NATS      │
                    │  (REST API)  │     │  (Event Bus)  │
                    │    :8081     │     │    :4222      │
                    └──────┬───────┘     └───────┬───────┘
                           │                     │
              ┌────────────┼────────────┐        │
              ▼            ▼            ▼        ▼
       ┌───────────┐ ┌──────────┐ ┌──────────────────┐
       │ PostgreSQL │ │  Redis   │ │   Push Gateway   │ :8082
       │   :5432   │ │  :6379   │ │  (APNs / FCM)    │
       └───────────┘ └──────────┘ └──────────────────┘
              │
              ▼
       ┌───────────┐ ┌──────────┐ ┌──────────────────┐
       │ClickHouse │ │  coturn  │ │     LiveKit      │
       │   :9000   │ │  :3478   │ │  (SFU) :7880     │
       └───────────┘ └──────────┘ └──────────────────┘
```

## 4 Microservices

| Service           | Port  | Mô tả                                                     |
| ----------------- | ----- | --------------------------------------------------------- |
| **Signaling**     | :8080 | WebSocket server cho SDP/ICE exchange, call state machine |
| **Orchestrator**  | :8081 | REST API quản lý vòng đời session (create/join/leave/end) |
| **Push Gateway**  | :8082 | Gateway push notification (APNs cho iOS, FCM cho Android) |
| **Policy Engine** | -     | Đánh giá chính sách ABR (Adaptive Bitrate)                |

## Call Topology

| Loại         | Topology            | Use Case                 |
| ------------ | ------------------- | ------------------------ |
| 1:1          | P2P (ICE direct)    | Mặc định, tối ưu chi phí |
| 1:1 fallback | TURN relay (coturn) | NAT strict / firewall    |
| Group (3-8)  | SFU (LiveKit)       | Cuộc gọi nhiều người     |

## Tech Stack

- **Backend:** Go 1.24.4
- **Mobile:** Flutter/Dart
- **Realtime:** WebSocket, LiveKit (SFU), coturn (TURN)
- **Message Bus:** NATS JetStream
- **Database:** PostgreSQL 16, ClickHouse 24, Redis 7
- **Gateway:** Nginx 1.27
- **Containerization:** Docker Compose

## Cấu trúc thư mục

```
Lalo/
├── cmd/                    # Entry points cho 4 services
│   ├── signaling/          # WebSocket signaling server
│   ├── orchestrator/       # REST API server
│   ├── push/               # Push notification gateway
│   └── policy/             # ABR policy engine
├── internal/               # Application packages (private)
│   ├── auth/               # JWT, TURN credentials, LiveKit tokens
│   ├── config/             # YAML config + env overrides
│   ├── session/            # Call session lifecycle, CDR
│   ├── signaling/          # WebSocket hub, message routing
│   ├── push/               # Push gateway (APNs/FCM)
│   ├── events/             # NATS JetStream event bus
│   ├── livekit/            # LiveKit room management
│   ├── metrics/            # QoS metrics (ClickHouse)
│   ├── models/             # Shared types, Redis keys
│   ├── abr/                # Adaptive bitrate policy
│   ├── turn/               # TURN health checks
│   └── db/                 # PostgreSQL connection
├── configs/                # Configuration files
├── migrations/             # Database migrations (Postgres + ClickHouse)
├── deployments/            # Docker & infra configs
├── scripts/                # Build/utility scripts
├── tests/                  # Test fixtures
└── docs/                   # Tài liệu dự án
```

## Tài liệu

| Tài liệu                          | Mô tả                         |
| --------------------------------- | ----------------------------- |
| [Architecture](architecture.md)   | Kiến trúc hệ thống chi tiết   |
| [API Reference](api-reference.md) | REST API & WebSocket protocol |
| [Database](database.md)           | Database schema & migrations  |
| [Configuration](configuration.md) | Cấu hình hệ thống             |
| [Deployment](deployment.md)       | Hướng dẫn triển khai          |
| [Development](development.md)     | Hướng dẫn phát triển          |
| [Testing](testing.md)             | Hướng dẫn testing             |

## Quick Start

```bash
# 1. Khởi động infrastructure
make run-local

# 2. Chạy migrations
make migrate-up

# 3. Build tất cả services
make build

# 4. Chạy từng service
./bin/signaling
./bin/orchestrator
./bin/push
```

## Yêu cầu

- Go 1.24.4+
- Docker & Docker Compose
- Make
