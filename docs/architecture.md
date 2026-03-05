# Kiến trúc hệ thống

## Tổng quan

Lalo sử dụng kiến trúc microservices với 4 service chính, giao tiếp qua NATS JetStream event bus. Hệ thống thiết kế cho 500k MAU với khả năng mở rộng horizontal.

## Service Architecture

```
                    ┌─────────────────────────────────┐
                    │         Nginx Gateway           │
                    │       :80 / :443 / :8888        │
                    └────────┬──────────┬─────────────┘
                             │          │
                    ┌────────▼──┐  ┌────▼──────────┐
                    │ Signaling │  │  Orchestrator  │
                    │   :8080   │  │    :8081       │
                    │ WebSocket │  │   REST API     │
                    └─────┬─────┘  └───────┬────────┘
                          │                │
              ┌───────────┼────────────────┼───────────┐
              │           ▼                ▼           │
              │    ┌─────────────────────────────┐     │
              │    │      NATS JetStream         │     │
              │    │    Event Bus (:4222)         │     │
              │    └──────────┬──────────────────┘     │
              │               │                        │
              │    ┌──────────▼──────────┐             │
              │    │   Push Gateway      │             │
              │    │      :8082          │             │
              │    │  APNs / FCM         │             │
              │    └─────────────────────┘             │
              │                                        │
              │    ┌─────────────────────┐             │
              │    │   Policy Engine     │             │
              │    │   ABR Evaluation    │             │
              │    └─────────────────────┘             │
              └────────────────────────────────────────┘
```

## Services chi tiết

### 1. Signaling Server (`:8080`)

**Entry point:** `cmd/signaling/main.go`

Chịu trách nhiệm:

- Quản lý WebSocket connections
- Routing SDP offer/answer giữa peers
- Routing ICE candidates
- Call state machine (ringing → connected → ended)
- Xử lý reconnection
- Glare resolution (khi 2 bên gọi đồng thời)
- Multi-device support (accepted elsewhere)
- State sync cho clients

**Internal packages:**

- `internal/signaling/hub.go` — Connection hub, quản lý active connections
- `internal/signaling/handler.go` — WebSocket message handler
- `internal/signaling/messages.go` — Message types & envelopes
- `internal/signaling/flow.go` — Call flow logic (1:1)
- `internal/signaling/room_flow.go` — Group call flow logic

### 2. Orchestrator (`:8081`)

**Entry point:** `cmd/orchestrator/main.go`

Chịu trách nhiệm:

- REST API cho session lifecycle
- Tạo/join/leave/end sessions
- Quản lý group call rooms
- Cấp TURN credentials
- Media state management
- CDR (Call Detail Record) creation

**Internal packages:**

- `internal/session/orchestrator.go` — HTTP handlers
- `internal/session/service.go` — Business logic
- `internal/session/cdr.go` — Call Detail Records

### 3. Push Gateway (`:8082`)

**Entry point:** `cmd/push/main.go`

Chịu trách nhiệm:

- Token registration/unregistration
- Gửi push notifications qua APNs (iOS) và FCM (Android)
- VoIP push qua PushKit (iOS)
- Delivery tracking
- Auto-invalidate expired tokens

**Internal packages:**

- `internal/push/gateway.go` — Gateway logic
- `internal/push/handler.go` — HTTP handlers
- `internal/push/apns.go` — Apple Push Notification Service
- `internal/push/fcm.go` — Firebase Cloud Messaging
- `internal/push/store.go` — Token store

### 4. Policy Engine

**Entry point:** `cmd/policy/main.go`

Chịu trách nhiệm:

- Thu thập QoS metrics
- Đánh giá policy rules
- Ra quyết định điều chỉnh chất lượng (ABR)
- Gửi policy updates cho clients qua LiveKit data channel

**Internal packages:**

- `internal/abr/engine.go` — Policy evaluation engine
- `internal/abr/rules.go` — Policy rules
- `internal/abr/types.go` — Types & decisions

## Infrastructure

### PostgreSQL (`:5432`)

- Lưu trữ user profiles, call history, call participants, push tokens
- 5 tables chính (xem [database.md](database.md))

### Redis (`:6379`)

- Session state (real-time)
- Connection tracking
- Rate limiting
- Temporary data (call IDs, ice candidates)

### NATS JetStream (`:4222`)

- Event bus cho inter-service communication
- Stream `CALLS` với retention 7 ngày
- Subjects: `call.*`, `quality.*`, `presence.*`, `sfu.*`, `push.*`, `room.*`

### ClickHouse (`:9000`)

- CDR (Call Detail Records) — analytics
- QoS metrics — per-second samples, TTL 30 ngày

### coturn (`:3478`, `:5349`)

- TURN relay server cho NAT traversal
- HMAC-SHA1 time-limited credentials
- Health check mỗi 10 giây

### LiveKit (`:7880`, `:7881`)

- SFU (Selective Forwarding Unit) cho group calls
- Room management
- Simulcast support (3 layers)
- Active speaker detection

### Nginx (`:80`, `:443`, `:8888`)

- Reverse proxy
- TLS termination
- WebSocket upgrade handling
- Load balancing

## Call Flow

### 1:1 Call (P2P)

```
Caller                Signaling              Callee
  │                      │                      │
  │── call_initiate ────▶│                      │
  │                      │── incoming_call ────▶│
  │                      │                      │
  │                      │◀── call_accept ──────│
  │◀── call_accepted ───│                      │
  │                      │                      │
  │── ice_candidate ───▶│── ice_candidate ────▶│
  │◀── ice_candidate ───│◀── ice_candidate ────│
  │                      │                      │
  │◀════════ P2P Media Connection ════════════▶│
  │                      │                      │
  │── call_end ─────────▶│── call_ended ───────▶│
```

### Group Call (SFU via LiveKit)

```
Host                 Signaling           LiveKit          Participants
  │                      │                  │                  │
  │── room_create ──────▶│                  │                  │
  │                      │── create room ──▶│                  │
  │◀── room_created ────│                  │                  │
  │   (livekit_token)    │                  │                  │
  │                      │── room_invitation ─────────────────▶│
  │                      │                  │                  │
  │                      │◀── room_join ───────────────────────│
  │                      │── join room ────▶│                  │
  │◀── participant_joined│                  │                  │
  │                      │                  │                  │
  │◀═══════════ SFU Media (LiveKit) ═══════════════════════▶│
```

### Reconnection Flow

```
Client               Signaling              Peer
  │                      │                    │
  │ [connection lost]    │                    │
  │                      │── peer_reconnecting ──▶│
  │                      │                    │
  │── reconnect ────────▶│                    │
  │                      │── peer_reconnected ──▶│
  │◀── session_resumed ─│                    │
  │   (state + sdp)      │                    │
```

## Authentication

### JWT Flow

```
Client ──▶ Login ──▶ Server issues TokenPair (access + refresh)
  │
  ├── WebSocket: ?token=<access_token>
  ├── REST API: Authorization: Bearer <access_token>
  │
  └── Token expired ──▶ POST /refresh ──▶ New TokenPair
```

- **Access token:** 15 phút (configurable)
- **Refresh token:** 7 ngày (configurable)
- Claims: `user_id`, `device_id`, `permissions`, `token_type`

### TURN Credentials

- Format: `username = "{expiry}:{user_id}"`, `password = Base64(HMAC-SHA1(secret, username))`
- TTL: 24 giờ (configurable)
- Tương thích với coturn `--static-auth-secret`

### LiveKit Tokens

- VideoGrant với room join permissions
- Valid 2 giờ + 5 phút buffer
- Identity = user_id

## Event System (NATS)

### JetStream Configuration

```
Stream: CALLS
MaxAge: 7 days
Replicas: 1 (dev) / 3 (production)
```

### Event Subjects

| Subject                   | Publisher    | Consumers          | Mô tả                   |
| ------------------------- | ------------ | ------------------ | ----------------------- |
| `call.initiated`          | Signaling    | Push, CDR          | Cuộc gọi bắt đầu        |
| `call.accepted`           | Signaling    | CDR                | Cuộc gọi được chấp nhận |
| `call.rejected`           | Signaling    | CDR                | Cuộc gọi bị từ chối     |
| `call.ended`              | Signaling    | CDR, Analytics     | Cuộc gọi kết thúc       |
| `call.state_changed`      | Signaling    | Monitor            | Trạng thái thay đổi     |
| `quality.tier_changed`    | Policy       | Signaling          | Chất lượng thay đổi     |
| `quality.metrics`         | Signaling    | Policy, ClickHouse | QoS samples             |
| `presence.updated`        | Signaling    | All                | Trạng thái online       |
| `sfu.participant_joined`  | LiveKit      | Signaling          | Người tham gia vào room |
| `sfu.participant_left`    | LiveKit      | Signaling          | Người tham gia rời room |
| `sfu.room_finished`       | LiveKit      | CDR                | Room đóng               |
| `push.delivery`           | Push         | Monitor            | Kết quả push            |
| `room.created`            | Orchestrator | Push               | Room mới                |
| `room.closed`             | Signaling    | CDR                | Room đóng               |
| `room.participant_joined` | Signaling    | All                | Tham gia room           |
| `room.participant_left`   | Signaling    | All                | Rời room                |

## Adaptive Bitrate (ABR)

### Quality Tiers

| Tier | RTT     | Loss | Jitter |
| ---- | ------- | ---- | ------ |
| Good | ≤ 120ms | ≤ 2% | ≤ 20ms |
| Fair | ≤ 250ms | ≤ 6% | ≤ 50ms |
| Poor | > 250ms | > 6% | > 50ms |

### Policy Rules

| Rule                     | Condition       | Threshold | Action           |
| ------------------------ | --------------- | --------- | ---------------- |
| high_loss_cap_fair       | avg_loss_above  | 8%        | Cap tier → Fair  |
| very_high_loss_cap_poor  | avg_loss_above  | 15%       | Cap tier → Poor  |
| high_rtt_cap_fair        | avg_rtt_above   | 300ms     | Cap tier → Fair  |
| low_bandwidth_audio_only | bandwidth_below | 80 kbps   | Force audio only |

### Hysteresis

- Upgrade: cần ổn định 10 giây
- Downgrade Fair: sau 2 giây
- Downgrade Poor: sau 1 giây
- Codec change interval tối thiểu: 30 giây

## Group Call Constraints

| Parameter                   | Giá trị |
| --------------------------- | ------- |
| Max participants            | 8       |
| Active video slots          | 4       |
| HQ (high quality) slots     | 2       |
| MQ (medium quality) slots   | 2       |
| Speaker detection threshold | -40 dB  |
| Speaker hold duration       | 3 giây  |

## Rate Limiting

| Resource                          | Limit    |
| --------------------------------- | -------- |
| Call initiate per user            | 10/phút  |
| Call initiate global              | 500 CPS  |
| Signaling messages per connection | 100/phút |
| TURN allocations per user         | 5/phút   |
| API requests per user             | 60/phút  |
