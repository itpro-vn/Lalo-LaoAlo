# Plan Tasks V1 — Adaptive Voice/Video Call System

| Field        | Value                                                                 |
| ------------ | --------------------------------------------------------------------- |
| **Spec Ref** | [Technical Design Spec v1](./technical-design-spec-v1.md)             |
| **Created**  | 2026-02-25                                                            |
| **Authors**  | ITPRO                                                                 |
| **Phases**   | A (MVP) → B (Group & Quality) → C (Scale & Resilience) → D (Advanced) |

---

## Table of Contents

1. [Phase A — MVP (8–12 weeks)](#phase-a--mvp-812-weeks)
2. [Phase B — Group & Quality (6–8 weeks)](#phase-b--group--quality-68-weeks)
3. [Phase C — Scale & Resilience (6–8 weeks)](#phase-c--scale--resilience-68-weeks)
4. [Phase D — Advanced (Ongoing)](#phase-d--advanced-ongoing)

---

## Quy ước

- **Task ID**: `PA-XX` (Phase A), `PB-XX` (Phase B), `PC-XX` (Phase C), `PD-XX` (Phase D)
- **Priority**: P0 (blocker), P1 (critical path), P2 (important), P3 (nice-to-have)
- **Deps**: Task ID phụ thuộc — phải hoàn thành trước khi bắt đầu task này
- **Estimate**: T-shirt sizing — S (1-2d), M (3-5d), L (1-2w), XL (2-4w)

---

## Phase A — MVP (8–12 weeks)

**Goal**: 1:1 voice/video call hoạt động ổn định, setup < 2s, audio tốt trên 4G.

**Exit Criteria**: 1:1 calls work reliably with < 2s setup, audio quality good on 4G.

---

### PA-01: Project Setup & Monorepo Structure

| Field        | Value          |
| ------------ | -------------- |
| **Priority** | P0             |
| **Estimate** | M (3-5 days)   |
| **Deps**     | None           |
| **Owner**    | Backend Lead   |
| **Type**     | Infrastructure |

**Mô tả**: Khởi tạo project Go monorepo, cấu trúc thư mục, CI/CD pipeline cơ bản.

**Yêu cầu chi tiết**:

1. Khởi tạo Go module (Go 1.22+) với cấu trúc:
   ```
   /
   ├── cmd/
   │   ├── signaling/        # Signaling server entry point
   │   ├── orchestrator/     # Session orchestrator entry point
   │   └── policy/           # Policy engine entry point
   ├── internal/
   │   ├── signaling/        # Signaling logic
   │   ├── session/          # Session management
   │   ├── policy/           # ABR policy
   │   ├── auth/             # JWT, TURN creds
   │   ├── models/           # Shared data models
   │   └── events/           # NATS event definitions
   ├── pkg/                  # Exportable packages
   ├── configs/              # Configuration files
   ├── deployments/          # K8s manifests, Helm charts
   ├── scripts/              # Build & utility scripts
   ├── docs/                 # Documentation
   └── tests/                # Integration & E2E tests
   ```
2. Setup `Makefile` với targets: `build`, `test`, `lint`, `docker-build`, `run-local`
3. Setup `golangci-lint` config (`.golangci.yml`)
4. Docker Compose cho local dev: Postgres, Redis, NATS, ClickHouse
5. GitHub Actions CI: lint, test, build trên mỗi PR
6. Config management: dùng `viper` hoặc env vars, load từ `call-config.yaml` (Spec Appendix C)

**Acceptance Criteria**:

- [ ] `make build` thành công cho cả 3 binaries
- [ ] `make test` chạy được (dù chưa có test nào)
- [ ] `docker compose up` start được tất cả dependencies
- [ ] CI pipeline chạy tự động trên PR
- [ ] Config struct parse được từ `call-config.yaml`

---

### PA-02: Database Schema Design & Migrations

| Field        | Value        |
| ------------ | ------------ |
| **Priority** | P0           |
| **Estimate** | M (3-5 days) |
| **Deps**     | PA-01        |
| **Owner**    | Backend      |
| **Type**     | Database     |

**Mô tả**: Thiết kế schema Postgres cho metadata, ClickHouse cho QoS/CDR, Redis key structure cho session state.

**Yêu cầu chi tiết**:

1. **Postgres schema** (migration tool: `golang-migrate`):

   ```sql
   -- users (tham chiếu từ main app, có thể là view/foreign table)
   CREATE TABLE users (
     id UUID PRIMARY KEY,
     display_name TEXT NOT NULL,
     avatar_url TEXT,
     created_at TIMESTAMPTZ DEFAULT now()
   );

   -- call_configs (per-user/global settings)
   CREATE TABLE call_configs (
     id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
     scope TEXT NOT NULL,        -- 'global' | 'user'
     scope_id UUID,              -- NULL for global, user_id for user
     config JSONB NOT NULL,
     updated_at TIMESTAMPTZ DEFAULT now()
   );

   -- call_history
   CREATE TABLE call_history (
     id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
     call_id UUID NOT NULL UNIQUE,
     call_type TEXT NOT NULL,    -- '1:1' | 'group'
     initiator_id UUID NOT NULL REFERENCES users(id),
     started_at TIMESTAMPTZ,
     ended_at TIMESTAMPTZ,
     duration_seconds INT,
     topology TEXT,              -- 'p2p' | 'turn' | 'sfu'
     end_reason TEXT,
     region TEXT,
     created_at TIMESTAMPTZ DEFAULT now()
   );

   -- call_participants
   CREATE TABLE call_participants (
     id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
     call_id UUID NOT NULL REFERENCES call_history(call_id),
     user_id UUID NOT NULL REFERENCES users(id),
     role TEXT NOT NULL,         -- 'caller' | 'callee' | 'participant'
     joined_at TIMESTAMPTZ,
     left_at TIMESTAMPTZ,
     end_reason TEXT
   );
   ```

2. **ClickHouse schema** (CDR + QoS):

   ```sql
   CREATE TABLE cdr (
     call_id UUID,
     call_type LowCardinality(String),
     initiator_id UUID,
     participants Array(UUID),
     started_at DateTime64(3),
     ended_at DateTime64(3),
     duration_seconds UInt32,
     setup_latency_ms UInt32,
     topology LowCardinality(String),
     region LowCardinality(String),
     avg_mos Float32,
     avg_packet_loss Float32,
     avg_rtt_ms UInt32,
     avg_bitrate_kbps UInt32,
     tier_good_pct Float32,
     tier_fair_pct Float32,
     tier_poor_pct Float32,
     video_off_seconds UInt32,
     reconnect_count UInt8,
     end_reason LowCardinality(String)
   ) ENGINE = MergeTree()
   ORDER BY (region, started_at, call_id);

   -- QoS metrics (high-frequency, per-second samples)
   CREATE TABLE qos_metrics (
     call_id UUID,
     participant_id UUID,
     ts DateTime64(3),
     direction LowCardinality(String),  -- 'send' | 'recv'
     rtt_ms UInt32,
     packet_loss_pct Float32,
     jitter_ms Float32,
     bitrate_kbps UInt32,
     framerate UInt8,
     resolution LowCardinality(String),
     network_tier LowCardinality(String)
   ) ENGINE = MergeTree()
   ORDER BY (call_id, participant_id, ts)
   TTL ts + INTERVAL 30 DAY;
   ```

3. **Redis key structure**:
   ```
   session:{call_id}          → Hash: {state, type, topology, created_at, ...}
   session:{call_id}:participants → Set: {user_id_1, user_id_2, ...}
   user:{user_id}:active_call → String: call_id (hoặc NULL)
   presence:{user_id}         → Hash: {status, last_seen, device_id}
   turn:creds:{session_id}    → Hash: {username, password, ttl}
   ```
   TTL: session keys = 24h (cleanup fallback), presence = 5 min auto-refresh.

**Acceptance Criteria**:

- [ ] Postgres migrations chạy up/down thành công
- [ ] ClickHouse tables được tạo, insert test data thành công
- [ ] Redis key operations (GET/SET/EXPIRE) hoạt động đúng
- [ ] Có seed script cho local development
- [ ] Schema documented trong `docs/schema.md`

---

### PA-03: NATS Event Bus Setup

| Field        | Value          |
| ------------ | -------------- |
| **Priority** | P1             |
| **Estimate** | S (1-2 days)   |
| **Deps**     | PA-01          |
| **Owner**    | Backend        |
| **Type**     | Infrastructure |

**Mô tả**: Setup NATS JetStream cho internal event fanout giữa các service.

**Yêu cầu chi tiết**:

1. Define event subjects (NATS subjects):
   ```
   call.initiated        → Khi call mới được tạo
   call.accepted         → Khi callee accept
   call.rejected         → Khi callee reject
   call.ended            → Khi call kết thúc
   call.state_changed    → Khi call state machine chuyển trạng thái
   quality.tier_changed  → Khi network tier thay đổi
   quality.metrics       → QoS metrics update (batched)
   presence.updated      → User online/offline
   ```
2. Define Go structs cho mỗi event type (protobuf hoặc JSON)
3. NATS client wrapper: connect, publish, subscribe, error handling, reconnect
4. JetStream config: retention policy, max age, replicas

**Acceptance Criteria**:

- [ ] Publish/subscribe hoạt động giữa 2 services (integration test)
- [ ] JetStream durability: message survive NATS restart
- [ ] Event struct serialization/deserialization roundtrip test
- [ ] Reconnect tự động khi NATS restart

---

### PA-04: Authentication & Token Service

| Field        | Value        |
| ------------ | ------------ |
| **Priority** | P0           |
| **Estimate** | M (3-5 days) |
| **Deps**     | PA-01        |
| **Owner**    | Backend      |
| **Type**     | Security     |

**Mô tả**: Implement JWT authentication, TURN credential generation, và SFU room token.

**Yêu cầu chi tiết**:

1. **JWT Service**:
   - Issue JWT cho API + signaling (15-min expiry)
   - Refresh token mechanism (7-day expiry, rotation on use)
   - JWT claims: `{user_id, device_id, permissions, exp, iat}`
   - Middleware: validate JWT trên mọi API/WSS request

2. **TURN Credential Service**:
   - HMAC-based time-limited credentials cho coturn
   - Credential format: username = `{timestamp}:{user_id}`, password = `HMAC-SHA1(secret, username)`
   - TTL: 86400 seconds (configurable)
   - Endpoint: `GET /api/v1/turn-credentials`

3. **SFU Room Token**:
   - Generate LiveKit room token với permissions
   - Permissions: `{canPublish, canSubscribe, canPublishData, room, identity}`
   - Token expiry: match call duration + buffer

4. **Rate Limiting**:
   - Implement per-user rate limits theo Spec §10.4
   - Call initiate: 10/min per user, 500 CPS global
   - API requests: 60/min per user
   - Store counters trong Redis (sliding window algorithm)

**Acceptance Criteria**:

- [ ] JWT issue/validate/refresh flow hoạt động end-to-end
- [ ] TURN credentials được coturn accept
- [ ] LiveKit room token cho phép join room thành công
- [ ] Rate limiter block requests vượt threshold
- [ ] Token rotation tự động khi gần hết hạn
- [ ] Unit tests cho tất cả token operations

---

### PA-05: Signaling Server — Core

| Field        | Value                      |
| ------------ | -------------------------- |
| **Priority** | P0                         |
| **Estimate** | XL (2-4 weeks)             |
| **Deps**     | PA-01, PA-02, PA-03, PA-04 |
| **Owner**    | Backend Lead               |
| **Type**     | Core Service               |

**Mô tả**: Implement WebSocket-based signaling server xử lý SDP/ICE exchange và call state machine.

**Yêu cầu chi tiết**:

1. **WebSocket Server** (`gorilla/websocket`):
   - WSS endpoint: `wss://signal.example.com/ws`
   - JWT authentication trên connection handshake
   - Heartbeat/ping-pong: 30s interval, 10s timeout
   - Per-connection rate limit: 100 messages/min (Spec §10.4)
   - Graceful shutdown: drain connections trước khi stop

2. **Signaling Protocol** (JSON messages):

   ```json
   // Client → Server
   {"type": "call_initiate", "callee_id": "uuid", "sdp_offer": "...", "call_type": "video"}
   {"type": "call_accept", "call_id": "uuid", "sdp_answer": "..."}
   {"type": "call_reject", "call_id": "uuid", "reason": "busy"}
   {"type": "call_end", "call_id": "uuid"}
   {"type": "ice_candidate", "call_id": "uuid", "candidate": "..."}

   // Server → Client
   {"type": "incoming_call", "call_id": "uuid", "caller_id": "uuid", "sdp_offer": "...", "call_type": "video"}
   {"type": "call_accepted", "call_id": "uuid", "sdp_answer": "..."}
   {"type": "call_rejected", "call_id": "uuid", "reason": "busy"}
   {"type": "call_ended", "call_id": "uuid", "reason": "user_hangup"}
   {"type": "ice_candidate", "call_id": "uuid", "candidate": "..."}
   {"type": "error", "code": "...", "message": "..."}
   ```

3. **Call State Machine** (Spec §6.4):
   - States: `IDLE → RINGING → CONNECTING → ACTIVE → ENDED → CLEANUP`
   - Transitions:
     - `IDLE → RINGING`: on `call_initiate` (validate callee exists, not busy)
     - `RINGING → CONNECTING`: on `call_accept`
     - `RINGING → ENDED`: on `call_reject`, timeout (45s), or `call_cancel`
     - `CONNECTING → ACTIVE`: on media flowing (ICE connected)
     - `CONNECTING → ENDED`: ICE timeout (15s)
     - `ACTIVE → ENDED`: on `call_end` from either party
     - `ENDED → CLEANUP`: automatic, release resources
     - `CLEANUP → IDLE`: after 5s max
   - State stored in Redis: `session:{call_id}` hash
   - Concurrent state changes handled via Redis WATCH/MULTI

4. **SDP/ICE Exchange**:
   - Forward SDP offer/answer between peers via WebSocket
   - Trickle ICE: forward candidates as they arrive
   - ICE timeout: 15 seconds from CONNECTING state

5. **Push Notification Integration**:
   - Khi callee offline/background → gửi VoIP push (APNS) / high-priority FCM
   - Push payload chứa: `{call_id, caller_name, caller_avatar, call_type}`
   - Retry: 1 attempt, timeout 5s

**Acceptance Criteria**:

- [ ] WebSocket connection establish + authenticate thành công
- [ ] Full 1:1 call flow: initiate → ring → accept → ICE exchange → active → end
- [ ] State machine transitions đúng cho mọi path (happy + error)
- [ ] Timeout handling: ring timeout (45s), ICE timeout (15s), cleanup (5s)
- [ ] Push notification gửi được khi callee offline
- [ ] Concurrent calls trên cùng user bị reject ("busy")
- [ ] Graceful shutdown không drop active calls
- [ ] Unit tests cho state machine, integration test cho full flow
- [ ] Load test: 1000 concurrent WebSocket connections stable

---

### PA-06: Session Orchestrator — Core

| Field        | Value               |
| ------------ | ------------------- |
| **Priority** | P0                  |
| **Estimate** | L (1-2 weeks)       |
| **Deps**     | PA-02, PA-03, PA-04 |
| **Owner**    | Backend             |
| **Type**     | Core Service        |

**Mô tả**: Implement session orchestrator quản lý call lifecycle, participant management, và routing decisions.

**Yêu cầu chi tiết**:

1. **Call Lifecycle Management**:
   - Create session: validate participants, check busy state, allocate call_id
   - Join session: add participant to active session
   - Leave session: remove participant, cleanup if last person
   - End session: notify all participants, trigger CDR write

2. **Topology Decision** (Spec §3.3):
   - `participants == 2` → P2P (attempt ICE direct first)
   - `participants > 2` → SFU (LiveKit room)
   - Topology stored in session state

3. **Participant Management**:
   - Track participant state: `{user_id, role, media_state, joined_at}`
   - Media state: `{audio_enabled, video_enabled, screen_sharing}`
   - Permission enforcement theo Spec §10.3 (Call Permissions Matrix)

4. **CDR Generation**:
   - Khi call kết thúc: collect metrics, build CDR record
   - Write CDR to ClickHouse (async via NATS event)
   - Write call history to Postgres (sync)

5. **TURN Credential Provisioning**:
   - Request TURN credentials cho participants khi call bắt đầu
   - Include TURN server list trong call setup response

**Acceptance Criteria**:

- [ ] Create/join/leave/end session flow hoạt động đúng
- [ ] Topology decision: P2P cho 2 người, SFU cho > 2 người
- [ ] Permission matrix enforced (Spec §10.3)
- [ ] CDR written to ClickHouse sau mỗi call
- [ ] Call history saved to Postgres
- [ ] TURN credentials provisioned thành công
- [ ] Unit tests cho mọi business logic

---

### PA-07: coturn Deployment & Configuration

| Field        | Value            |
| ------------ | ---------------- |
| **Priority** | P1               |
| **Estimate** | M (3-5 days)     |
| **Deps**     | PA-04            |
| **Owner**    | DevOps / Backend |
| **Type**     | Infrastructure   |

**Mô tả**: Deploy và configure coturn cluster cho TURN/STUN relay.

**Yêu cầu chi tiết**:

1. **coturn Configuration**:

   ```
   listening-port=3478
   tls-listening-port=5349
   relay-ip=<public-ip>
   external-ip=<public-ip>
   min-port=49152
   max-port=65535
   use-auth-secret
   static-auth-secret=<shared-secret-with-backend>
   realm=call.example.com
   total-quota=100
   max-bps=0
   cert=/etc/ssl/turn_cert.pem
   pkey=/etc/ssl/turn_key.pem
   no-cli
   ```

2. **Deployment**:
   - Docker container hoặc bare metal (performance preference)
   - Single region (Phase A): 2-3 nodes behind DNS round-robin
   - Health check endpoint: TCP check port 3478
   - Monitoring: prometheus exporter cho coturn metrics

3. **Integration**:
   - Backend generate HMAC credentials cho coturn (PA-04)
   - Client nhận TURN server list + credentials từ signaling server
   - ICE candidates include TURN relay candidates

4. **Testing**:
   - Verify TURN relay hoạt động khi P2P fail
   - Bandwidth test: verify relay throughput đủ cho video call
   - Multi-client test: nhiều calls qua cùng TURN server

**Acceptance Criteria**:

- [ ] coturn cluster (2-3 nodes) running, health checks pass
- [ ] TURN allocation thành công với HMAC credentials
- [ ] Media relay hoạt động qua TURN (verified bằng test client)
- [ ] Prometheus metrics: active allocations, bandwidth, errors
- [ ] Failover: kill 1 node, calls route to remaining nodes

---

### PA-08: LiveKit SFU — Basic Setup

| Field        | Value            |
| ------------ | ---------------- |
| **Priority** | P1               |
| **Estimate** | M (3-5 days)     |
| **Deps**     | PA-01, PA-04     |
| **Owner**    | Backend / DevOps |
| **Type**     | Infrastructure   |

**Mô tả**: Deploy LiveKit SFU (self-hosted) cho group calls (2-3 person test trong Phase A).

**Yêu cầu chi tiết**:

1. **LiveKit Deployment**:
   - Self-hosted LiveKit server (Go binary hoặc Docker)
   - Configuration:
     ```yaml
     port: 7880
     rtc:
       port_range_start: 50000
       port_range_end: 60000
       use_external_ip: true
     redis:
       address: redis:6379
     keys:
       api_key: <key>
       api_secret: <secret>
     ```
   - Single instance cho Phase A (scale trong Phase C)

2. **Backend Integration**:
   - LiveKit Go SDK: tạo room, generate join token, manage rooms
   - Room lifecycle: create → participants join → last leave → destroy
   - Webhook handler: nhận events từ LiveKit (participant joined/left, track published)

3. **Basic Media Configuration**:
   - Audio: Opus only
   - Video: VP8 + H.264 Baseline
   - Simulcast: enabled (3 layers: high/medium/low)
   - Max participants per room: 8

**Acceptance Criteria**:

- [ ] LiveKit server running, accessible from clients
- [ ] Room creation/deletion via API thành công
- [ ] 2-3 clients join room, publish/subscribe tracks thành công
- [ ] Simulcast layers available cho subscribers
- [ ] Webhook events received by backend
- [ ] Prometheus metrics from LiveKit available

---

### PA-09: iOS Client — WebRTC Core

| Field        | Value          |
| ------------ | -------------- |
| **Priority** | P0             |
| **Estimate** | XL (2-4 weeks) |
| **Deps**     | PA-05          |
| **Owner**    | iOS Lead       |
| **Type**     | Mobile Client  |

**Mô tả**: Implement iOS WebRTC stack: libwebrtc integration, signaling client, media capture/render.

**Yêu cầu chi tiết**:

1. **libwebrtc Integration** (M120+ branch):
   - Build libwebrtc cho iOS (arm64 + simulator)
   - Hoặc dùng prebuilt binary (WebRTC.xcframework từ Google hoặc LiveKit's WebRTC build)
   - Swift wrapper cho core WebRTC APIs

2. **Signaling Client**:
   - WebSocket client connect tới signaling server (WSS)
   - JWT authentication on connect
   - Auto-reconnect với exponential backoff
   - Handle tất cả signaling messages (Spec PA-05 protocol)
   - Heartbeat/ping-pong implementation

3. **PeerConnection Management**:
   - Create `RTCPeerConnection` với ICE servers (STUN + TURN)
   - SDP offer/answer generation
   - ICE candidate handling (trickle ICE)
   - ICE connection state monitoring
   - ICE restart support (cho network handover)
   - ICE timeout: 15 seconds → TURN fallback

4. **Media Capture**:
   - Camera capture: front/back switch, 720p max, 30fps
   - Microphone capture: Opus codec
   - Permission handling: camera + microphone
   - Audio session configuration: `.voiceChat` category
   - Echo cancellation, noise suppression (WebRTC built-in)

5. **Media Rendering**:
   - Local preview: `RTCMTLVideoView` hoặc `RTCEAGLVideoView`
   - Remote video: render incoming track
   - Audio routing: speaker / earpiece / bluetooth
   - Video mirror cho front camera

6. **Call Manager**:
   - High-level API: `startCall(userId:, type:)`, `acceptCall(callId:)`, `endCall(callId:)`
   - Manage call state locally (mirror server state)
   - Media controls: mute/unmute audio, enable/disable video, switch camera
   - Call statistics collection (RTT, packet loss, bitrate, jitter)

**Acceptance Criteria**:

- [ ] 1:1 voice call iOS ↔ iOS hoạt động end-to-end
- [ ] 1:1 video call iOS ↔ iOS hoạt động end-to-end
- [ ] P2P connection established (verify via ICE candidate types)
- [ ] TURN fallback hoạt động khi P2P fail
- [ ] Audio routing: speaker/earpiece switch
- [ ] Camera switch front/back
- [ ] Mute/unmute audio + video
- [ ] Call stats collection hoạt động
- [ ] Network change (WiFi ↔ 4G): ICE restart, < 2s interruption

---

### PA-10: iOS Client — CallKit Integration

| Field        | Value         |
| ------------ | ------------- |
| **Priority** | P0            |
| **Estimate** | L (1-2 weeks) |
| **Deps**     | PA-09         |
| **Owner**    | iOS Lead      |
| **Type**     | Mobile Client |

**Mô tả**: Integrate CallKit cho native incoming/outgoing call UI, VoIP push notification.

**Yêu cầu chi tiết**:

1. **CallKit Provider**:
   - `CXProvider` configuration: supported handle types, max calls per group, video support
   - Report incoming call: `reportNewIncomingCall(with:update:)`
   - Report outgoing call: `reportOutgoingCall(with:startedConnectingAt:connectedAt:)`
   - Report call ended: `reportCall(with:endedAt:reason:)`
   - Handle system events: call on hold, audio interrupted

2. **CXCallController**:
   - Start call action: `CXStartCallAction`
   - Answer call action: `CXAnswerCallAction`
   - End call action: `CXEndCallAction`
   - Set mute action: `CXSetMutedCallAction`
   - Set held action: `CXSetHeldCallAction`

3. **VoIP Push Notification**:
   - `PushKit` framework: register for VoIP pushes
   - `PKPushRegistry` delegate: handle incoming VoIP push
   - **CRITICAL**: Phải report CallKit incoming call ngay trong `didReceiveIncomingPush` callback
   - Push payload → extract call info → report to CallKit → connect signaling

4. **Background Handling**:
   - Audio continues khi app in background (CallKit manages audio session)
   - App wakes up from killed state via VoIP push
   - Handle `beginBackgroundTask` cho signaling reconnect

5. **UI Integration**:
   - Native call UI (system phone screen) cho incoming calls
   - In-app call UI cho active calls (custom)
   - Call log integration (optional, via CallKit)

**Acceptance Criteria**:

- [ ] Incoming call: VoIP push → native call UI → accept → audio connected
- [ ] Incoming call khi app killed → VoIP push wakes app → call UI
- [ ] Outgoing call: in-app initiate → native call UI → connected
- [ ] Call shows in system call log
- [ ] Background → foreground: audio continues seamlessly
- [ ] Mute via CallKit (from native UI) hoạt động
- [ ] Multiple calls: reject second call when busy
- [ ] Audio routing via system UI (speaker/bluetooth)

---

### PA-11: Android Client — WebRTC Core

| Field        | Value          |
| ------------ | -------------- |
| **Priority** | P0             |
| **Estimate** | XL (2-4 weeks) |
| **Deps**     | PA-05          |
| **Owner**    | Android Lead   |
| **Type**     | Mobile Client  |

**Mô tả**: Implement Android WebRTC stack: libwebrtc integration, signaling client, media capture/render.

**Yêu cầu chi tiết**:

1. **libwebrtc Integration** (M120+ branch):
   - Gradle dependency: prebuilt Google WebRTC AAR hoặc LiveKit's WebRTC build
   - Kotlin wrapper cho core WebRTC APIs
   - ProGuard rules cho WebRTC classes

2. **Signaling Client**:
   - OkHttp WebSocket client connect tới signaling server (WSS)
   - JWT authentication on connect
   - Auto-reconnect với exponential backoff
   - Handle tất cả signaling messages
   - Heartbeat/ping-pong implementation

3. **PeerConnection Management**:
   - Tương tự iOS (PA-09, item 3)
   - `PeerConnectionFactory` initialization
   - Hardware encoder/decoder detection (MediaCodec)

4. **Media Capture**:
   - Camera capture: `Camera2Capturer` (API 26+), front/back switch
   - Microphone capture: Opus codec
   - Runtime permission handling: `CAMERA`, `RECORD_AUDIO`
   - Audio mode: `MODE_IN_COMMUNICATION`
   - Echo cancellation, noise suppression (WebRTC built-in)

5. **Media Rendering**:
   - Local preview: `SurfaceViewRenderer` hoặc `TextureViewRenderer`
   - Remote video: render incoming track
   - Audio routing: speaker / earpiece / bluetooth / wired headset
   - Video mirror cho front camera

6. **Call Manager**:
   - Tương tự iOS (PA-09, item 6)
   - Foreground Service: `TYPE_PHONE_CALL` (Android 12+)
   - Notification channel cho ongoing call

**Acceptance Criteria**:

- [ ] 1:1 voice call Android ↔ Android hoạt động end-to-end
- [ ] 1:1 video call Android ↔ Android hoạt động end-to-end
- [ ] Cross-platform: iOS ↔ Android call hoạt động
- [ ] P2P + TURN fallback hoạt động
- [ ] Audio routing: speaker/earpiece/bluetooth
- [ ] Camera switch front/back
- [ ] Mute/unmute audio + video
- [ ] Call stats collection
- [ ] Network change handling: ICE restart

---

### PA-12: Android Client — ConnectionService Integration

| Field        | Value         |
| ------------ | ------------- |
| **Priority** | P0            |
| **Estimate** | L (1-2 weeks) |
| **Deps**     | PA-11         |
| **Owner**    | Android Lead  |
| **Type**     | Mobile Client |

**Mô tả**: Integrate Android `ConnectionService` cho call management, FCM high-priority push.

**Yêu cầu chi tiết**:

1. **ConnectionService**:
   - Extend `ConnectionService`, register `PhoneAccount`
   - `onCreateIncomingConnection()`: handle incoming call
   - `onCreateOutgoingConnection()`: handle outgoing call
   - Connection states: `STATE_INITIALIZING → STATE_RINGING → STATE_ACTIVE → STATE_DISCONNECTED`
   - Support: `CAPABILITY_MUTE`, `CAPABILITY_SUPPORT_HOLD`

2. **FCM Push Notification**:
   - High-priority FCM message cho incoming calls
   - FCM data message (not notification): app handles display
   - Payload: `{call_id, caller_name, caller_avatar, call_type}`
   - Handle khi app in background/killed: start foreground service → show incoming call UI

3. **Foreground Service**:
   - `TYPE_PHONE_CALL` foreground service (Android 12+)
   - Ongoing notification: caller info, duration, controls (mute/end)
   - `MANAGE_OWN_CALLS` permission

4. **Incoming Call UI**:
   - Full-screen notification (khi app locked/background)
   - Heads-up notification (khi app in foreground of other apps)
   - In-app UI (khi app in foreground)
   - Accept/Reject buttons

5. **Background Handling**:
   - Audio continues via foreground service
   - Wake lock management
   - Battery optimization exemption request

**Acceptance Criteria**:

- [ ] Incoming call via FCM → full-screen notification → accept → connected
- [ ] Incoming call khi app killed → FCM wakes → show call UI
- [ ] Outgoing call → ConnectionService → connected
- [ ] Foreground service với ongoing notification
- [ ] Mute/end from notification
- [ ] Audio continues in background
- [ ] Works on Android 8+ (API 26+)

---

### PA-13: Basic Quality Metrics Collection

| Field        | Value               |
| ------------ | ------------------- |
| **Priority** | P2                  |
| **Estimate** | M (3-5 days)        |
| **Deps**     | PA-09, PA-11, PA-06 |
| **Owner**    | Mobile + Backend    |
| **Type**     | Observability       |

**Mô tả**: Thu thập QoS metrics từ client SDK, gửi về backend, store vào ClickHouse.

**Yêu cầu chi tiết**:

1. **Client-side Collection** (iOS + Android):
   - Thu thập từ `RTCPeerConnection.getStats()` mỗi 5 giây:
     - RTT (ms)
     - Packet loss (%)
     - Jitter (ms)
     - Bitrate send/recv (kbps)
     - Framerate send/recv
     - Resolution send/recv
     - ICE candidate type (host/srflx/relay)
   - Batch metrics: gom 5-10 samples, gửi qua signaling WSS hoặc HTTP

2. **Backend Ingestion**:
   - Receive metrics via signaling channel hoặc dedicated HTTP endpoint
   - Validate + enrich: add call_id, region, timestamp
   - Write to ClickHouse `qos_metrics` table (async, batched)
   - Write CDR summary to ClickHouse khi call kết thúc

3. **Network Tier Classification** (client-side):
   - Classify current network vào Good/Fair/Poor tier (Spec §5.1)
   - Include tier trong metrics report
   - Tier dùng cho basic ABR trong Phase A (chỉ fast loop)

**Acceptance Criteria**:

- [ ] Client gửi metrics mỗi 5 giây trong suốt cuộc gọi
- [ ] Metrics appear trong ClickHouse `qos_metrics` table
- [ ] CDR written khi call kết thúc
- [ ] Network tier classification hoạt động đúng
- [ ] Grafana dashboard cơ bản hiển thị được metrics (placeholder)

---

### PA-14: Basic ABR — Fast Loop Only

| Field        | Value               |
| ------------ | ------------------- |
| **Priority** | P2                  |
| **Estimate** | L (1-2 weeks)       |
| **Deps**     | PA-09, PA-11, PA-13 |
| **Owner**    | Mobile              |
| **Type**     | Quality             |

**Mô tả**: Implement fast loop ABR trên client (bitrate adjustment, framerate/resolution reduction).

**Yêu cầu chi tiết**:

1. **Fast Loop** (500ms – 1s cycle) trên client:
   - Input: RTCP feedback, TWCC bandwidth estimation
   - Actions:
     - Bitrate adjustment (tăng/giảm theo available bandwidth)
     - Framerate reduction khi RTT spike > 300ms
     - Resolution downscale khi bandwidth thấp
   - Thresholds (Spec §5.5):
     - Loss > 4% sustained 1s → reduce bitrate 30%
     - RTT spike > 300ms → drop framerate first
     - Available BW < 500kbps → suggest video off

2. **Audio Priority Rule** (Spec §5.6):
   - Bandwidth < 100 kbps → VIDEO OFF, audio-only mode
   - UI indicator: "Poor connection, video paused"
   - Auto-recover: bandwidth > 200 kbps stable 10s → re-enable video

3. **Video Encoder Control**:
   - Điều chỉnh `maxBitrate`, `maxFramerate` trên `RTCRtpSender` parameters
   - Resolution downscale via `scaleResolutionDownBy`
   - Không đổi codec trong Phase A (slow loop deferred to Phase B)

**Acceptance Criteria**:

- [ ] Bitrate tự động giảm khi network degrade (test bằng `tc` throttle)
- [ ] Framerate giảm trước resolution khi RTT spike
- [ ] Video tự động tắt khi BW < 100kbps
- [ ] Video tự động bật lại khi BW > 200kbps stable 10s
- [ ] Audio không bị ảnh hưởng khi video bị cut
- [ ] UI hiển thị "Poor connection" indicator

---

### PA-15: API Gateway & Load Balancer Setup

| Field        | Value          |
| ------------ | -------------- |
| **Priority** | P1             |
| **Estimate** | M (3-5 days)   |
| **Deps**     | PA-05, PA-06   |
| **Owner**    | DevOps         |
| **Type**     | Infrastructure |

**Mô tả**: Setup API Gateway/LB cho routing requests tới signaling + orchestrator.

**Yêu cầu chi tiết**:

1. **Load Balancer**:
   - L7 LB (Nginx / Envoy / cloud LB)
   - WSS routing: sticky sessions (hoặc broadcast via NATS)
   - HTTPS termination: TLS 1.3
   - Health check endpoints cho mỗi service

2. **Routing Rules**:

   ```
   /ws              → Signaling Server (WebSocket upgrade)
   /api/v1/*        → Session Orchestrator (REST)
   /api/v1/metrics  → Metrics ingestion endpoint
   ```

3. **Security Headers**:
   - HSTS enabled
   - Certificate pinning config cho mobile clients
   - CORS: reject all (mobile-only, no web)

4. **Rate Limiting** (at LB level):
   - Global CPS limit: 500 calls/second
   - Per-IP connection limit
   - WebSocket connection limit per user

**Acceptance Criteria**:

- [ ] WSS connections route correctly tới signaling servers
- [ ] REST API calls route tới orchestrator
- [ ] TLS 1.3 enforced
- [ ] Health checks detect unhealthy backends
- [ ] Rate limiting blocks excessive requests

---

### PA-16: End-to-End Integration Testing (Phase A)

| Field        | Value                                    |
| ------------ | ---------------------------------------- |
| **Priority** | P1                                       |
| **Estimate** | L (1-2 weeks)                            |
| **Deps**     | PA-05 through PA-14, PA-17, PA-18, PA-19 |
| **Owner**    | QA + All teams                           |
| **Type**     | Testing                                  |

**Mô tả**: E2E testing cho toàn bộ 1:1 call flow, đảm bảo exit criteria Phase A.

**Yêu cầu chi tiết**:

1. **Happy Path Tests**:
   - 1:1 voice call: initiate → ring → accept → talk → end
   - 1:1 video call: initiate → ring → accept → video flowing → end
   - Cross-platform: iOS ↔ Android call
   - P2P path verification
   - TURN fallback verification

2. **Error Path Tests**:
   - Callee busy → reject
   - Ring timeout (45s) → call ended
   - ICE timeout (15s) → TURN fallback
   - Caller cancel during ringing
   - Network disconnect during call → reconnect attempt

3. **Network Condition Tests** (Spec §12.1):
   - Perfect (20ms/0%/2ms): verify 720p/30fps
   - Good (80ms/1%/10ms): verify quality maintained
   - Fair (150ms/3%/30ms): verify ABR downgrades
   - Poor (300ms/8%/60ms): verify audio priority
   - Extreme (500ms/15%/100ms): verify audio-only mode

4. **Mobile-Specific Tests** (Spec §12.2):
   - WiFi → 4G handover: < 2s interruption
   - Background → foreground: audio continues
   - VoIP push wakeup: app killed → incoming call works

5. **Performance Benchmarks**:
   - Call setup time: P95 < 2 seconds
   - Audio latency: P95 < 150ms one-way
   - ICE negotiation time (P2P): < 800ms
   - ICE negotiation time (TURN): < 1200ms

**Acceptance Criteria**:

- [ ] Tất cả happy path tests pass
- [ ] Error path tests: tất cả edge cases handled gracefully
- [ ] Network condition tests: ABR hoạt động đúng theo spec
- [ ] Mobile tests: handover + background + push notification hoạt động
- [ ] Performance: P95 setup < 2s, audio latency < 150ms
- [ ] Test report documented, bugs filed và tracked

---

### PA-17: Push/Incoming Call Plane — Push Gateway & Token Management

| Field        | Value               |
| ------------ | ------------------- |
| **Priority** | P0                  |
| **Estimate** | L (1-2 weeks)       |
| **Deps**     | PA-02, PA-04, PA-05 |
| **Owner**    | Backend + Mobile    |
| **Type**     | Infrastructure      |

**Mô tả**: Xây dựng Push Gateway Service xử lý push notification cho incoming calls. Đảm bảo app bị killed/background vẫn nhận được cuộc gọi đến. Bao gồm token management, push routing, delivery tracking, và client-side state machine (Spec §6.6).

**Yêu cầu chi tiết**:

1. **Push Gateway Service** (Go):
   - Nhận request từ Signaling Server khi callee offline/background
   - Lookup active push tokens từ DB (multi-device support)
   - Route push tới APNs (VoIP push via PushKit) hoặc FCM (data message) dựa trên platform
   - Track delivery status: sent/delivered/failed per device
   - Nếu tất cả devices fail → notify caller "Không thể liên lạc"

2. **Push Token Registry**:

   ```sql
   CREATE TABLE push_tokens (
       id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
       user_id     UUID NOT NULL REFERENCES users(id),
       device_id   TEXT NOT NULL,
       platform    TEXT NOT NULL CHECK (platform IN ('ios', 'android')),
       push_token  TEXT NOT NULL,
       voip_token  TEXT,              -- iOS PushKit VoIP token only
       app_version TEXT,
       bundle_id   TEXT,
       is_active   BOOLEAN DEFAULT true,
       created_at  TIMESTAMPTZ DEFAULT now(),
       updated_at  TIMESTAMPTZ DEFAULT now(),
       UNIQUE(user_id, device_id)
   );
   ```

   - API endpoints: `POST /v1/push/register`, `DELETE /v1/push/unregister`
   - Token refresh: client gửi token mới khi APNs/FCM rotate
   - Token invalidation: APNs `410 Gone` hoặc FCM `UNREGISTERED` → mark inactive
   - Scheduled cleanup: tokens > 30 ngày không update → soft delete

3. **APNs VoIP Push (iOS)**:
   - Push type: `voip` (PushKit) — topic: `{bundle_id}.voip`
   - Priority: `10` (immediate), Expiration: `0` (don't store)
   - Collapse ID: `call_{call_id}` (dedup retry)
   - Payload:
     ```json
     {
       "call_id": "uuid",
       "caller_id": "uuid",
       "caller_name": "Nguyễn Văn A",
       "caller_avatar_url": "https://...",
       "call_type": "audio|video",
       "timestamp": 1708876543,
       "ttl": 45
     }
     ```
   - **CRITICAL**: Không retry APNs VoIP push — iOS quản lý delivery

4. **FCM Data Message (Android)**:
   - **BẮT BUỘC dùng `data` message** — KHÔNG dùng `notification` message
   - `notification` message bị hệ thống handle → không gọi `onMessageReceived()` khi app killed
   - Priority: `high`, TTL: `45s`
   - Payload:
     ```json
     {
       "to": "<fcm_token>",
       "priority": "high",
       "ttl": "45s",
       "data": {
         "type": "incoming_call",
         "call_id": "uuid",
         "caller_id": "uuid",
         "caller_name": "Nguyễn Văn A",
         "call_type": "audio|video",
         "timestamp": "1708876543"
       }
     }
     ```
   - Retry: 1 retry sau 2s nếu failed, max 2 attempts

5. **Retry & Fallback Policy**:
   - Push TTL = ring timeout (45s) — không store push quá thời gian ring
   - Multi-device: gửi tới TẤT CẢ devices active của user
   - First device accept → server broadcast `call_accepted` → other devices dismiss
   - All devices fail → caller nhận `callee_unreachable` event trong 5s

**Acceptance Criteria**:

- [ ] Push token registration/refresh/unregister API hoạt động
- [ ] APNs VoIP push delivered thành công (test với real device)
- [ ] FCM data message delivered khi app foreground/background/killed
- [ ] Multi-device: push gửi tới tất cả devices, first accept wins
- [ ] Token invalidation tự động khi APNs/FCM báo token invalid
- [ ] Delivery tracking: mỗi push có status sent/delivered/failed
- [ ] Caller nhận callee_unreachable nếu tất cả devices fail
- [ ] Load test: 100 concurrent push/second
- [ ] Unit tests cho push routing logic

---

### PA-18: iOS — PushKit VoIP Integration & Call State Machine

| Field        | Value        |
| ------------ | ------------ |
| **Priority** | P0           |
| **Estimate** | M (3-5 days) |
| **Deps**     | PA-10, PA-17 |
| **Owner**    | iOS          |
| **Type**     | Feature      |

**Mô tả**: Integrate PushKit VoIP push với CallKit, đảm bảo incoming call hoạt động khi app killed/background. Implement client-side call state machine (Spec §6.6.3, §6.6.5).

**Yêu cầu chi tiết**:

1. **PushKit Registration**:
   - `PKPushRegistry` với type `.voIP`
   - Gửi VoIP token tới Push Gateway (`POST /v1/push/register`)
   - Handle token refresh trong `pushRegistry(_:didUpdatePushCredentials:)`

2. **PushKit → CallKit Bridge** (CRITICAL TIMING):
   - Trong `pushRegistry(_:didReceiveIncomingPushWith:)`:
     - Parse push payload
     - **GỌI NGAY** `provider.reportNewIncomingCall()` — TRƯỚC bất kỳ async work nào
     - Nếu không gọi → iOS **kill app** và **revoke PushKit token**
   - Sau khi report:
     - Start WebSocket connection (background)
     - Begin SDP exchange
   - Dùng placeholder data nếu chưa có đầy đủ caller info, update via `CXCallUpdate` sau

3. **Client-Side Call State Machine**:

   ```
   IDLE → INCOMING (push received) → CONNECTING (user accept)
        → CALLING (user initiate)     → ACTIVE (media flowing)
                                      → ENDED (hangup/timeout/error)
   ```

   - States: `IDLE`, `INCOMING`, `CALLING`, `CONNECTING`, `ACTIVE`, `ENDED`
   - Timeout: INCOMING → ENDED after 45s, CONNECTING → ENDED after 15s (ICE timeout)
   - Thread-safe state transitions (actor hoặc serial queue)

4. **Race Condition Handling**:
   - Push + WSS `incoming_call` cùng lúc → dedup bằng `call_id`
   - Push arrives sau khi caller cancel → check call validity via WSS
   - Multiple devices: nhận `call_accepted` từ device khác → dismiss CallKit UI

5. **Background Audio**:
   - `AVAudioSession` category `.playAndRecord` với mode `.voiceChat`
   - Background mode: `voip`, `audio`
   - Audio continues khi app vào background

**Acceptance Criteria**:

- [ ] App killed → VoIP push → CallKit UI shown trong < 3s
- [ ] App background → VoIP push → CallKit UI shown
- [ ] `reportNewIncomingCall` gọi ngay trong didReceiveIncomingPush (verified via logs)
- [ ] State machine transitions đúng cho tất cả flows
- [ ] Dedup: push + WSS cùng call → chỉ show 1 UI
- [ ] Multi-device dismiss khi device khác accept
- [ ] Token refresh gửi tới Push Gateway thành công
- [ ] Audio continues khi user switch app during call

---

### PA-19: Android — FCM + Full-Screen Intent & Call State Machine

| Field        | Value        |
| ------------ | ------------ |
| **Priority** | P0           |
| **Estimate** | M (3-5 days) |
| **Deps**     | PA-12, PA-17 |
| **Owner**    | Android      |
| **Type**     | Feature      |

**Mô tả**: Integrate FCM data message với ConnectionService + Full-Screen Intent, đảm bảo incoming call hoạt động khi app killed/background trên Android 10-15. Implement client-side call state machine (Spec §6.6.4, §6.6.5).

**Yêu cầu chi tiết**:

1. **FCM Data Message Handler**:
   - Extend `FirebaseMessagingService`
   - `onMessageReceived()`: parse data payload, start foreground service
   - `onNewToken()`: gửi token mới tới Push Gateway
   - **KHÔNG dùng notification message** — chỉ data message để đảm bảo `onMessageReceived()` luôn được gọi

2. **Foreground Service**:
   - `ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL` (Android 12+)
   - `ServiceInfo.FOREGROUND_SERVICE_TYPE_DEFAULT` (Android < 12)
   - Ongoing notification với caller info
   - Wake lock management cho audio processing

3. **Full-Screen Intent**:
   - `USE_FULL_SCREEN_INTENT` permission (Android 10+)
   - `fullScreenIntent` trên notification → `IncomingCallActivity`
   - Hoạt động khi:
     - Device locked (keyguard)
     - App background/killed
     - Device idle (Doze mode — FCM high-priority bypass)
   - `IncomingCallActivity`: show caller info + Accept/Decline buttons
   - `turnScreenOn`, `showWhenLocked`, `dismissKeyguard` flags

4. **ConnectionService Integration**:
   - `addNewIncomingCall()` sau khi start foreground service
   - Connection states: `STATE_INITIALIZING → STATE_RINGING → STATE_ACTIVE → STATE_DISCONNECTED`
   - `PhoneAccount` registration with `CAPABILITY_SELF_MANAGED`
   - Handle `onAnswer()`, `onReject()`, `onDisconnect()`

5. **Client-Side Call State Machine** (same as iOS):
   - States: `IDLE`, `INCOMING`, `CALLING`, `CONNECTING`, `ACTIVE`, `ENDED`
   - Thread-safe: Kotlin coroutine + StateFlow
   - Dedup push + WSS events by `call_id`

6. **Android Permissions**:
   ```xml
   <uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT" />
   <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
   <uses-permission android:name="android.permission.FOREGROUND_SERVICE_PHONE_CALL" />
   <uses-permission android:name="android.permission.MANAGE_OWN_CALLS" />
   <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
   ```

**Acceptance Criteria**:

- [ ] App killed → FCM data message → full-screen UI shown trong < 4s
- [ ] App background → FCM → full-screen notification
- [ ] Device locked → full-screen intent shows over keyguard
- [ ] Foreground service running khi có active call
- [ ] ConnectionService states transition đúng
- [ ] Doze mode: FCM high-priority bypasses Doze
- [ ] State machine dedup push + WSS events
- [ ] Multi-device dismiss khi device khác accept
- [ ] Android 10, 12, 13, 14: tested trên mỗi version
- [ ] POST_NOTIFICATIONS permission request (Android 13+)

---

## Phase B — Group & Quality (6–8 weeks)

**Goal**: Group calls stable với 8 participants, ABR two-loop adapts correctly.

**Exit Criteria**: Group calls stable with 8 participants, ABR adapts correctly across tiers.

**Deps**: Phase A hoàn thành.

---

### PB-01: Group Call — Room Management

| Field        | Value         |
| ------------ | ------------- |
| **Priority** | P0            |
| **Estimate** | L (1-2 weeks) |
| **Deps**     | PA-06, PA-08  |
| **Owner**    | Backend       |
| **Type**     | Core Feature  |

**Mô tả**: Implement full room management cho group calls via LiveKit SFU.

**Yêu cầu chi tiết**:

1. **Room Lifecycle**:
   - Create room: initiator tạo room, nhận room_id + join token
   - Invite participants: gửi invitation (push notification + signaling)
   - Join room: participant join via LiveKit SDK + token
   - Leave room: participant rời room, update participant list
   - Close room: khi host leave hoặc tất cả participants leave
   - Max 8 participants per room (Spec §2)

2. **Participant Management**:
   - Track participant state: `{user_id, role, audio, video, speaking}`
   - Roles: `host` (initiator), `participant`
   - Host permissions: add member, end call for all
   - Participant permissions: mute self, leave, pin video

3. **Signaling Protocol Extensions**:

   ```json
   {"type": "room_create", "participants": ["uuid1", "uuid2", ...], "call_type": "video"}
   {"type": "room_invite", "room_id": "uuid", "invitees": ["uuid3"]}
   {"type": "room_join", "room_id": "uuid"}
   {"type": "room_leave", "room_id": "uuid"}
   {"type": "participant_joined", "room_id": "uuid", "user_id": "uuid", "role": "participant"}
   {"type": "participant_left", "room_id": "uuid", "user_id": "uuid"}
   {"type": "participant_media_changed", "room_id": "uuid", "user_id": "uuid", "audio": true, "video": false}
   ```

4. **Admission Control**:
   - Reject join khi room full (8 participants)
   - Reject join khi user already in another call
   - Rate limit room creation

**Acceptance Criteria**:

- [ ] Create room → invite → join → talk → leave → close flow hoạt động
- [ ] Max 8 participants enforced
- [ ] Host can add members mid-call
- [ ] Participant list sync across all clients
- [ ] Room auto-close khi tất cả participants leave
- [ ] CDR generated cho group calls

---

### PB-02: Simulcast & SVC — Multi-Layer Publishing

| Field        | Value            |
| ------------ | ---------------- |
| **Priority** | P0               |
| **Estimate** | L (1-2 weeks)    |
| **Deps**     | PB-01            |
| **Owner**    | Mobile + Backend |
| **Type**     | Media Quality    |

**Mô tả**: Implement simulcast publishing trên client, per-subscriber layer selection trên SFU.

**Yêu cầu chi tiết**:

1. **Client Simulcast Publishing** (iOS + Android):
   - Publish 3 simulcast layers:
     - High: 720p/30fps (~1.5 Mbps)
     - Medium: 360p/20fps (~500 kbps)
     - Low: 180p/10fps (~150 kbps)
   - Configure via `RTCRtpEncodingParameters`:
     ```
     rid: "h", maxBitrate: 1500000, scaleResolutionDownBy: 1
     rid: "m", maxBitrate: 500000, scaleResolutionDownBy: 2
     rid: "l", maxBitrate: 150000, scaleResolutionDownBy: 4
     ```

2. **SFU Layer Selection**:
   - LiveKit automatic layer selection dựa trên subscriber bandwidth
   - Backend/client có thể request specific layer (cho video slot management)
   - API: `setSubscribedQualities()` per track

3. **Adaptive Layer Switching**:
   - Subscriber bandwidth giảm → SFU tự động forward layer thấp hơn
   - Speaker change → switch layer cho active speaker

**Acceptance Criteria**:

- [ ] Client publish 3 simulcast layers (verify via SFU stats)
- [ ] Subscribers nhận đúng layer dựa trên bandwidth
- [ ] Manual layer request hoạt động
- [ ] Layer switch smooth (không freeze/artifact)
- [ ] Bandwidth savings verified: subscriber chỉ nhận 1 layer per track

---

### PB-03: Video Slot Management

| Field        | Value         |
| ------------ | ------------- |
| **Priority** | P0            |
| **Estimate** | L (1-2 weeks) |
| **Deps**     | PB-01, PB-02  |
| **Owner**    | Mobile        |
| **Type**     | UX / Media    |

**Mô tả**: Implement 4-slot video display với speaker-based assignment (Spec §5.4).

**Yêu cầu chi tiết**:

1. **Video Slot Layout**:
   - 4 active video slots displayed đồng thời
   - Slot 1-2: HQ (720p/30fps, 1.2-2.0 Mbps)
   - Slot 3-4: MQ (360p/20fps, 400-600 kbps)
   - Slot 5-8: LQ thumbnail (180p/10fps, 50-150 kbps) hoặc avatar-only

2. **Slot Assignment Logic**:
   - Active speaker → HQ slot (via Voice Activity Detection / LiveKit speaker events)
   - Last 2 recent speakers → MQ slots
   - Pinned participant → HQ slot (user override, sticky until unpin)
   - Remaining → LQ thumbnails hoặc paused (avatar)
   - Speaker detection threshold: -40 dB
   - Speaker hold: giữ slot 3 seconds sau khi ngừng nói (tránh flicker)

3. **UI Implementation** (iOS + Android):
   - Grid layout: 2×2 cho 4 active slots
   - Bottom strip: thumbnails cho remaining participants
   - Smooth animation khi slot assignment thay đổi
   - Pin/unpin gesture (tap to pin)
   - Speaking indicator (border highlight / animation)
   - Name overlay trên mỗi video

4. **Subscribe Management**:
   - HQ slots: subscribe high simulcast layer
   - MQ slots: subscribe medium layer
   - LQ slots: subscribe low layer hoặc pause
   - Unsubscribe video cho participants không hiển thị (bandwidth saving)

**Acceptance Criteria**:

- [ ] 4 video slots render đúng layout
- [ ] Active speaker tự động promote lên HQ slot
- [ ] Pin participant hoạt động, override speaker logic
- [ ] Speaker hold 3s tránh flicker
- [ ] Thumbnails hiển thị cho participants > 4
- [ ] Bandwidth optimized: chỉ subscribe cần thiết
- [ ] Smooth transitions khi slot assignment thay đổi

---

### PB-04: Two-Loop ABR — Full Implementation

| Field        | Value                            |
| ------------ | -------------------------------- |
| **Priority** | P0                               |
| **Estimate** | XL (2-4 weeks)                   |
| **Deps**     | PA-14, PB-02                     |
| **Owner**    | Mobile + Backend (Policy Engine) |
| **Type**     | Quality                          |

**Mô tả**: Implement full two-loop ABR: fast loop (client) + slow loop (client + policy engine).

**Yêu cầu chi tiết**:

1. **Fast Loop Enhancement** (500ms – 1s, client-side):
   - Nâng cấp từ PA-14 basic fast loop
   - Add simulcast layer switch trigger (gửi request tới SFU)
   - Coordinate với video slot management (PB-03)

2. **Slow Loop** (5–10s cycle, client-side + server-side):
   - Inputs: aggregated network tier, battery state, thermal state, sustained quality
   - Actions:
     - Codec profile change (Opus complexity adjustment)
     - Video codec switch (VP8 ↔ H.264) — max 1 change per 30s
     - Tier reclassification
     - Audio parameter adjustment theo tier (Spec §5.2):
       - Good: 24-32 kbps, FEC OFF, packet time 20ms
       - Fair: 16-24 kbps, FEC ON, packet time 20ms
       - Poor: 12-16 kbps, FEC ON, packet time 40ms
     - Video parameter adjustment theo tier (Spec §5.3):
       - Good: 720p/30fps, 1.2-2.0 Mbps
       - Fair: 360-480p/15-20fps, 400-900 kbps
       - Poor: 180-360p/12-15fps, 150-350 kbps

3. **Hysteresis Implementation** (Spec §5.1):
   - Upgrade: tier mới phải stable 10 giây liên tục
   - Downgrade to Fair: sau 2 giây sustained
   - Downgrade to Poor: sau 1 giây sustained
   - Max 1 codec change per 30 seconds

4. **Policy Engine** (server-side, Go service):
   - Receive quality metrics từ clients
   - Evaluate ABR rules (có thể override client decisions)
   - Push policy updates tới clients via signaling
   - Configuration: rules loadable từ config (hot-reload)

5. **Battery & Thermal Awareness**:
   - iOS: `ProcessInfo.thermalState`, `UIDevice.batteryLevel`
   - Android: `BatteryManager`, thermal API
   - Low battery (< 20%): reduce video quality 1 tier
   - Thermal throttle: reduce video quality, limit framerate

**Acceptance Criteria**:

- [ ] Two-loop hoạt động: fast loop adjusts bitrate/framerate, slow loop adjusts codec/tier
- [ ] Hysteresis: upgrade chỉ sau 10s stable, downgrade 2s/1s
- [ ] Audio policy matches spec per tier (bitrate, FEC, packet time)
- [ ] Video policy matches spec per tier (resolution, framerate, bitrate)
- [ ] Codec switch max 1 per 30s
- [ ] Battery/thermal awareness giảm quality khi cần
- [ ] Policy engine can override client decisions
- [ ] Network chaos test: ABR adapts correctly across all tiers

---

### PB-05: Reconnection & ICE Restart

| Field        | Value         |
| ------------ | ------------- |
| **Priority** | P0            |
| **Estimate** | L (1-2 weeks) |
| **Deps**     | PA-09, PA-11  |
| **Owner**    | Mobile        |
| **Type**     | Reliability   |

**Mô tả**: Implement automatic ICE restart khi network change, reconnection logic.

**Yêu cầu chi tiết**:

1. **Network Change Detection**:
   - iOS: `NWPathMonitor` detect network interface change
   - Android: `ConnectivityManager.NetworkCallback` detect network change
   - Detect: WiFi → Cellular, Cellular → WiFi, Cellular → Cellular (handover)

2. **ICE Restart Flow** (Spec §6.5):
   - Network change detected → trigger ICE restart
   - Send new ICE candidates via signaling
   - Target: < 2 seconds media interruption
   - During restart: audio continues on old path if possible

3. **Retry Policy**:
   - Max 3 restart attempts before call termination
   - Backoff: 0s → 1s → 3s between attempts
   - After 3 failures: show user "Connection lost" → end call

4. **Signaling Reconnect**:
   - WebSocket disconnect → auto-reconnect
   - Re-authenticate với JWT
   - Resume session state
   - Pending ICE candidates buffered during reconnect

5. **SFU Reconnect** (group calls):
   - LiveKit client SDK handles reconnect internally
   - Verify track re-publish/re-subscribe after reconnect
   - Room state sync after reconnect

**Acceptance Criteria**:

- [ ] WiFi → 4G: call continues, < 2s audio interruption
- [ ] 4G → WiFi: seamless switch, quality upgrade
- [ ] Airplane mode toggle (< 5s): reconnect succeeds
- [ ] 3 failed attempts → call terminated gracefully
- [ ] Signaling WSS reconnect tự động
- [ ] Group call SFU reconnect hoạt động
- [ ] Backoff timing đúng: 0s → 1s → 3s

---

### PB-06: Full Signaling Protocol — Edge Cases

| Field        | Value         |
| ------------ | ------------- |
| **Priority** | P1            |
| **Estimate** | L (1-2 weeks) |
| **Deps**     | PA-05, PB-01  |
| **Owner**    | Backend       |
| **Type**     | Robustness    |

**Mô tả**: Handle tất cả signaling edge cases, concurrent operations, và error scenarios.

**Yêu cầu chi tiết**:

1. **Concurrent Operation Handling**:
   - Glare: cả 2 user call nhau cùng lúc → pick one (lower user_id wins)
   - Race condition: accept + cancel arrive simultaneously → cancel wins
   - Multiple devices: user có nhiều devices → ring tất cả, first accept wins

2. **Error Scenarios**:
   - User offline → push timeout → call_failed
   - Server restart during active call → reconnect + state recovery
   - Invalid SDP → error response, call not created
   - Malformed signaling message → error, connection kept alive

3. **State Recovery**:
   - Server crash → restart → reload active sessions from Redis
   - Client reconnect → resync call state from server
   - Partial state: call exists in Redis but participant disconnected → cleanup

4. **Message Ordering**:
   - Sequence numbers trên signaling messages
   - Out-of-order detection và handling
   - Duplicate message detection (idempotency)

**Acceptance Criteria**:

- [ ] Glare handling: simultaneous calls resolved correctly
- [ ] Race condition: concurrent accept+cancel handled
- [ ] Multi-device ringing: all devices ring, first accept wins
- [ ] State recovery after server restart
- [ ] Message sequence validation
- [ ] All error scenarios return proper error codes
- [ ] No orphaned sessions after edge case scenarios

---

### PB-07: E2E Integration Testing (Phase B)

| Field        | Value               |
| ------------ | ------------------- |
| **Priority** | P1                  |
| **Estimate** | L (1-2 weeks)       |
| **Deps**     | PB-01 through PB-06 |
| **Owner**    | QA + All teams      |
| **Type**     | Testing             |

**Mô tả**: E2E testing cho group calls, two-loop ABR, reconnection.

**Yêu cầu chi tiết**:

1. **Group Call Tests**:
   - 3 participants: create → invite → join → talk → leave
   - 8 participants: max capacity test
   - 9th participant: rejection test
   - Mid-call join: participant joins ongoing call
   - Mid-call leave: participant leaves, others continue
   - Host leave: room behavior (transfer host or close)

2. **Video Slot Tests**:
   - Speaker detection → HQ slot assignment
   - Pin participant → override speaker logic
   - Rapid speaker changes → no flicker (3s hold)
   - 4+ participants → thumbnail strip

3. **ABR Two-Loop Tests** (Spec §12.1 full matrix):
   - Verify tier transitions match spec thresholds
   - Verify hysteresis: upgrade needs 10s stable
   - Verify audio/video parameters per tier
   - Verify audio priority: video off < 100kbps, recover > 200kbps

4. **Reconnection Tests** (Spec §12.2):
   - WiFi → 4G handover (1:1 + group)
   - 4G → WiFi handover
   - Airplane mode toggle
   - Multi-reconnect (stress test reconnection logic)

5. **Performance Validation**:
   - Group call with 8 participants: CPU/memory on device
   - ABR response time: < 1s for fast loop action
   - Slot switch latency: < 500ms

**Acceptance Criteria**:

- [ ] All group call flows tested and pass
- [ ] Video slots behave per spec
- [ ] ABR matches spec parameters across all tiers
- [ ] Reconnection works for all scenarios
- [ ] Performance acceptable on mid-range devices
- [ ] Test report + bug tracking

---

## Phase C — Scale & Resilience (6–8 weeks)

**Goal**: System handles 5k CCU, tất cả SLOs met, automatic recovery from single-node failures.

**Exit Criteria**: 5k CCU, all SLOs met, single-node failure auto-recovery.

**Deps**: Phase B hoàn thành.

---

### PC-01: Multi-Region Deployment

| Field        | Value            |
| ------------ | ---------------- |
| **Priority** | P0               |
| **Estimate** | XL (2-4 weeks)   |
| **Deps**     | Phase B complete |
| **Owner**    | DevOps + Backend |
| **Type**     | Infrastructure   |

**Mô tả**: Deploy system ra 2 regions với GeoDNS routing.

**Yêu cầu chi tiết**:

1. **Region Setup**:
   - Primary: Vietnam (ap-southeast-1 hoặc equivalent)
   - Secondary: Singapore / another SEA region
   - GeoDNS: route users tới nearest region (latency-based)

2. **Per-Region Deployment**:
   - Kubernetes cluster per region (multi-AZ within region)
   - Full stack per region: signaling, orchestrator, policy, coturn, LiveKit
   - Shared: Postgres (primary in region 1, read replica in region 2)
   - Per-region: Redis cluster, NATS cluster

3. **Cross-Region Considerations**:
   - Call between 2 regions: both participants use their local coturn/SFU
   - Signaling can cross regions (via NATS cross-cluster or shared LB)
   - Data replication: Postgres streaming replication, ClickHouse distributed tables

4. **DNS Configuration**:
   - `signal.example.com` → GeoDNS → nearest signaling cluster
   - `turn.example.com` → GeoDNS → nearest coturn cluster
   - Health check integration: remove unhealthy region from DNS

**Acceptance Criteria**:

- [ ] 2 regions operational
- [ ] GeoDNS routes users to nearest region
- [ ] Calls within same region: low latency path
- [ ] Cross-region calls: functional (higher latency acceptable)
- [ ] Region failover: traffic routes to remaining region
- [ ] Data replication working

---

### PC-02: Kubernetes HPA & Auto-Scaling

| Field        | Value          |
| ------------ | -------------- |
| **Priority** | P0             |
| **Estimate** | L (1-2 weeks)  |
| **Deps**     | PC-01          |
| **Owner**    | DevOps         |
| **Type**     | Infrastructure |

**Mô tả**: Configure HPA cho auto-scaling signaling, SFU, và TURN nodes.

**Yêu cầu chi tiết**:

1. **HPA Configuration**:
   | Component | Metric | Scale Up | Scale Down | Min | Max |
   | -------------- | ----------------------------- | -------------- | -------------- | --- | --- |
   | Signaling | CPU > 70% or connections/pod | +1 pod | -1 pod | 3 | 10 |
   | Orchestrator | CPU > 70% | +1 pod | -1 pod | 2 | 6 |
   | Policy Engine | CPU > 60% | +1 pod | -1 pod | 2 | 4 |
   | LiveKit SFU | CPU > 75% or rooms/node > 40 | +1 node | -1 node | 2 | 8 |
   | coturn | Bandwidth > 80% or CPU > 70% | +1 node | -1 node | 4 | 12 |

2. **Custom Metrics**:
   - Export custom metrics via Prometheus adapter
   - WSS connections per pod (signaling)
   - Active rooms per node (SFU)
   - Active allocations per node (coturn)
   - Bandwidth usage per node (coturn)

3. **Scaling Policies**:
   - Scale up: immediate (< 30s)
   - Scale down: cooldown 5 minutes
   - SFU scale down: drain rooms first (no new rooms, wait for existing to close)
   - coturn scale down: drain allocations

**Acceptance Criteria**:

- [ ] HPA scales up khi load increases
- [ ] HPA scales down khi load decreases (with cooldown)
- [ ] Custom metrics drive scaling correctly
- [ ] SFU/coturn drain gracefully before scale down
- [ ] Scale events logged and alerted

---

### PC-03: Load Testing — 5k CCU Target

| Field        | Value                 |
| ------------ | --------------------- |
| **Priority** | P0                    |
| **Estimate** | L (1-2 weeks)         |
| **Deps**     | PC-01, PC-02          |
| **Owner**    | QA + Backend + DevOps |
| **Type**     | Testing               |

**Mô tả**: Load test hệ thống đạt 5,000 CCU target (Spec §12.3).

**Yêu cầu chi tiết**:

1. **Load Test Scenarios** (Spec §12.3):
   | Test | Target | Duration |
   | --------------- | ----------------------------------------- | --------- |
   | Steady state | 5,000 CCU, 98% 1:1 / 2% group | 1 hour |
   | Burst CPS | 200 calls/second spike for 60s | 5 minutes |
   | Soak test | 3,000 CCU sustained | 24 hours |
   | TURN saturation | Fill TURN bandwidth to 90% | 30 min |
   | SFU stress | 50 concurrent group rooms, 8 ppl each | 1 hour |
   | Signaling flood | 10,000 WSS connections, high message rate | 30 min |

2. **Test Tools**:
   - Custom WebRTC bot (headless, publish/subscribe synthetic media)
   - WebSocket load generator (for signaling)
   - Synthetic media generator (for TURN/SFU bandwidth test)

3. **Success Criteria** (Spec §8.1 SLOs):
   - Call setup success (1:1): ≥ 99.7%
   - Call setup success (group): ≥ 99.3%
   - P95 setup latency: < 2 seconds
   - P95 audio latency: < 150ms
   - Control plane availability: 99.95%

4. **Reporting**:
   - Dashboard: real-time metrics during load test
   - Post-test report: SLO compliance, bottlenecks identified, recommendations
   - Capacity planning: actual vs estimated resource usage

**Acceptance Criteria**:

- [ ] 5,000 CCU steady state: all SLOs met
- [ ] Burst 200 CPS: no call failures, latency < 3s
- [ ] 24h soak test: no memory leaks, no degradation
- [ ] TURN/SFU stress: performance acceptable
- [ ] Bottlenecks identified and documented
- [ ] Capacity plan updated with real data

---

### PC-04: Chaos Engineering — Game Day

| Field        | Value              |
| ------------ | ------------------ |
| **Priority** | P1                 |
| **Estimate** | L (1-2 weeks)      |
| **Deps**     | PC-01, PC-02       |
| **Owner**    | Backend + DevOps   |
| **Type**     | Resilience Testing |

**Mô tả**: Execute game day scenarios (Spec §12.4) để verify failure recovery.

**Yêu cầu chi tiết**:

1. **Game Day Scenarios** (Spec §12.4):
   | Scenario | Action | Expected |
   | ---------------------- | ---------------------------------- | ------------------------------------- |
   | Kill SFU pod | `kubectl delete pod livekit-0` | Rooms rebalance, < 5s recovery |
   | TURN node outage | Stop coturn on 1 node | Active calls ICE restart, new routes |
   | Redis master fail | Kill Redis master | Sentinel promotes replica, < 3s |
   | Signaling full restart | Rolling restart all signaling pods | Active WSS reconnect, no call drop |
   | DNS failover | Remove region from GeoDNS | Traffic routes to next region |
   | Network partition | Isolate control from media plane | Active calls continue, new calls fail |

2. **Execution Protocol**:
   - Pre-game: baseline metrics, active call count
   - During: inject failure, monitor recovery
   - Post-game: analyze impact, recovery time, data loss
   - Document: findings, improvements needed

3. **Automated Chaos** (optional):
   - Chaos Mesh hoặc LitmusChaos cho K8s
   - Scheduled random failures
   - Automated recovery verification

**Acceptance Criteria**:

- [ ] All 6 scenarios executed successfully
- [ ] Recovery times within spec limits
- [ ] No data loss during any scenario
- [ ] Active calls survive single-node failures
- [ ] Game day report with findings + improvements
- [ ] Follow-up issues tracked

---

### PC-05: Full Observability Stack

| Field        | Value            |
| ------------ | ---------------- |
| **Priority** | P1               |
| **Estimate** | L (1-2 weeks)    |
| **Deps**     | PC-01            |
| **Owner**    | DevOps + Backend |
| **Type**     | Observability    |

**Mô tả**: Deploy full observability stack: OTel + Prometheus + Grafana + Loki + Tempo.

**Yêu cầu chi tiết**:

1. **OpenTelemetry Integration**:
   - OTel SDK trong mọi Go services
   - OTel Collector deployment (agent + gateway mode)
   - Auto-instrumentation: HTTP, gRPC, database, Redis

2. **Metrics (Prometheus)**:
   - Tất cả SLI metrics (Spec §8.2)
   - Custom metrics: call success rate, setup latency, tier distribution
   - Service-level: CPU, memory, goroutines, GC

3. **Logs (Loki)**:
   - Structured JSON logging cho tất cả services
   - Log levels: error, warn, info, debug
   - Call ID correlation: mọi log entry include call_id
   - Retention: 30 days

4. **Traces (Tempo)**:
   - Distributed tracing per call (Spec §11.3)
   - Trace spans: signaling → routing → notification → ICE → media → quality → end
   - Sampling: 100% cho errors, 10% cho success

5. **Dashboards (Grafana)** (Spec §11.2):
   - Call Health: setup rate, success rate, duration distribution
   - Quality (QoE): MOS score, bitrate, packet loss by region
   - Infrastructure: CPU, memory, network per component
   - TURN: active allocations, bandwidth, success rate
   - SFU: rooms, participants, CPU per node
   - Network Tiers: Good/Fair/Poor distribution per region
   - Error Budget: SLO burn rate, remaining budget

6. **Alerting** (Spec §8.3):
   - Setup success < 99% (5-min window) → P1 page
   - P95 latency > 3s (5-min window) → P2 notification
   - TURN node unhealthy × 3 → P1 auto-remove + page
   - SFU CPU > 85% (2-min sustained) → P2 HPA + notification
   - Redis cluster degraded → P1 auto-failover + page
   - Packet loss > 10% avg (1-min, per-region) → P2 investigate

**Acceptance Criteria**:

- [ ] All services emit OTel metrics, logs, traces
- [ ] Prometheus collects all SLI metrics
- [ ] Loki stores structured logs, searchable by call_id
- [ ] Tempo shows distributed traces per call
- [ ] 7 Grafana dashboards operational
- [ ] 6 alert rules configured and tested
- [ ] On-call runbook documented for each alert

---

### PC-06: Cost Optimization — P2P Ratio Tuning

| Field        | Value        |
| ------------ | ------------ |
| **Priority** | P2           |
| **Estimate** | M (3-5 days) |
| **Deps**     | PC-03, PC-05 |
| **Owner**    | Backend      |
| **Type**     | Optimization |

**Mô tả**: Optimize P2P success rate để giảm TURN bandwidth cost.

**Yêu cầu chi tiết**:

1. **P2P Success Analysis**:
   - Dashboard: P2P vs TURN ratio by region, ISP, time of day
   - Identify patterns: which networks consistently fail P2P
   - ICE timing analysis: optimize ICE timeout (currently 800-1200ms)

2. **ICE Optimization**:
   - Aggressive nomination mode
   - ICE Lite cho TURN servers
   - Candidate ordering: host → srflx → relay
   - STUN server proximity: nearest STUN server first

3. **TURN Bandwidth Management**:
   - Per-user TURN bandwidth quotas
   - Admission control khi TURN bandwidth > 80%
   - Prefer P2P reconnection after initial TURN relay

4. **Cost Dashboard**:
   - Real-time cost estimation based on active TURN sessions
   - Projected monthly cost vs actual
   - P2P ratio trend over time

**Acceptance Criteria**:

- [ ] P2P success rate measured and baselined
- [ ] ICE optimizations increase P2P ratio by > 5%
- [ ] TURN bandwidth cost reduced vs baseline
- [ ] Cost dashboard operational

---

## Phase D — Advanced (Ongoing)

**Goal**: Advanced features, codec upgrades, ML-based optimization.

**Deps**: Phase C hoàn thành.

---

### PD-01: VP9 / AV1 Codec Rollout

| Field        | Value            |
| ------------ | ---------------- |
| **Priority** | P2               |
| **Estimate** | L (1-2 weeks)    |
| **Deps**     | Phase C complete |
| **Owner**    | Mobile + Backend |
| **Type**     | Quality          |

**Mô tả**: Flag-gated rollout VP9 và AV1 codec, per-device capability detection.

**Yêu cầu chi tiết**:

1. **Device Capability Detection**:
   - Check hardware encoder/decoder support cho VP9, AV1
   - iOS: check `VTIsHardwareDecodeSupported()` per codec
   - Android: check `MediaCodecInfo` capabilities
   - Report capability to server during registration

2. **Codec Negotiation**:
   - SDP offer includes VP9/AV1 nếu supported
   - Server-side feature flag: enable/disable per codec
   - Gradual rollout: 1% → 10% → 50% → 100%

3. **Quality Comparison**:
   - A/B test: VP8/H264 vs VP9 vs AV1
   - Metrics: MOS, bitrate efficiency, CPU usage
   - Dashboard: codec usage distribution, quality comparison

**Acceptance Criteria**:

- [ ] VP9 works on supported devices
- [ ] AV1 works on supported devices
- [ ] Feature flag controls codec availability
- [ ] Quality improvement measured vs VP8/H264
- [ ] No regression on unsupported devices

---

### PD-02: ML-Based QoE Prediction

| Field        | Value          |
| ------------ | -------------- |
| **Priority** | P3             |
| **Estimate** | XL (2-4 weeks) |
| **Deps**     | PC-05          |
| **Owner**    | ML + Backend   |
| **Type**     | Advanced       |

**Mô tả**: ML model predict quality degradation trước khi xảy ra, proactive adjustment.

**Yêu cầu chi tiết**:

1. **Data Collection**: historical QoS metrics từ ClickHouse
2. **Model**: time-series prediction (LSTM / Transformer) cho network quality
3. **Integration**: model inference tại Policy Engine, push preemptive quality adjustment
4. **Validation**: A/B test ML-based vs rule-based ABR

**Acceptance Criteria**:

- [ ] Model predicts degradation > 5s trước khi xảy ra
- [ ] Proactive adjustment improves MOS by measurable margin
- [ ] Model latency < 100ms inference time

---

### PD-03: AI Noise Suppression

| Field        | Value            |
| ------------ | ---------------- |
| **Priority** | P3               |
| **Estimate** | L (1-2 weeks)    |
| **Deps**     | Phase C complete |
| **Owner**    | Mobile           |
| **Type**     | Quality          |

**Mô tả**: Client-side noise suppression (RNNoise hoặc tương đương).

**Yêu cầu chi tiết**:

1. **Integration**: RNNoise library compile cho iOS (C → Swift bridge) và Android (JNI)
2. **Audio Pipeline**: insert noise suppression trước Opus encoder
3. **Toggle**: user setting on/off, default on
4. **Performance**: CPU overhead < 5% trên mid-range devices

**Acceptance Criteria**:

- [ ] Noise suppression hoạt động trên cả iOS + Android
- [ ] Measurable noise reduction (A/B test)
- [ ] CPU overhead acceptable
- [ ] No audio artifacts introduced

---

### PD-04: Screen Sharing

| Field        | Value          |
| ------------ | -------------- |
| **Priority** | P3             |
| **Estimate** | XL (2-4 weeks) |
| **Deps**     | PB-01, PB-02   |
| **Owner**    | Mobile         |
| **Type**     | Feature        |

**Mô tả**: Screen sharing cho group calls, content-type optimization.

**Yêu cầu chi tiết**:

1. **iOS**: `RPScreenRecorder` → `RTCVideoSource` (Broadcast Extension cho background sharing)
2. **Android**: MediaProjection API → `RTCVideoSource`
3. **Content-Type Optimization**: detect screen content → adjust encoder (higher resolution, lower framerate cho text, higher framerate cho video)
4. **SFU**: dedicated screen share track, auto-promote to HQ slot

**Acceptance Criteria**:

- [ ] Screen sharing works trong group calls
- [ ] Correct resolution/framerate cho khác loại content
- [ ] Screen share auto-promoted to main view
- [ ] Works khi app in background (iOS Broadcast Extension)

---

### PD-05: End-to-End Encryption (E2EE)

| Field        | Value            |
| ------------ | ---------------- |
| **Priority** | P3               |
| **Estimate** | XL (2-4 weeks)   |
| **Deps**     | Phase C complete |
| **Owner**    | Mobile + Backend |
| **Type**     | Security         |

**Mô tả**: Optional E2EE sử dụng Insertable Streams API.

**Yêu cầu chi tiết**:

1. **Key Exchange**: Double Ratchet hoặc MLS (Messaging Layer Security)
2. **Media Encryption**: encrypt/decrypt media frames via Insertable Streams
3. **SFU Compatibility**: SFU forwards encrypted frames without decryption
4. **Key Verification**: safety number display cho users
5. **Toggle**: opt-in per call

**Acceptance Criteria**:

- [ ] E2EE 1:1 calls: encrypted end-to-end
- [ ] E2EE group calls: encrypted end-to-end
- [ ] SFU cannot read media content
- [ ] Key verification UI hoạt động
- [ ] Performance impact < 5% CPU overhead

---

## Dependency Graph (Summary)

```
Phase A (MVP):
  PA-01 → PA-02, PA-03, PA-04
  PA-04 → PA-07, PA-08
  PA-01 + PA-02 + PA-03 + PA-04 → PA-05, PA-06
  PA-05 → PA-09, PA-11
  PA-09 → PA-10
  PA-11 → PA-12
  PA-09 + PA-11 + PA-06 → PA-13
  PA-13 → PA-14
  PA-05 + PA-06 → PA-15
  All PA → PA-16

Phase B (Group & Quality):
  PA-06 + PA-08 → PB-01
  PB-01 → PB-02
  PB-01 + PB-02 → PB-03
  PA-14 + PB-02 → PB-04
  PA-09 + PA-11 → PB-05
  PA-05 + PB-01 → PB-06
  All PB → PB-07

Phase C (Scale & Resilience):
  Phase B → PC-01
  PC-01 → PC-02
  PC-01 + PC-02 → PC-03, PC-04
  PC-01 → PC-05
  PC-03 + PC-05 → PC-06

Phase D (Advanced):
  Phase C → PD-01, PD-02, PD-03, PD-05
  PB-01 + PB-02 → PD-04
```

---

## Timeline Estimate (Summary)

| Phase     | Duration        | Tasks  | Key Milestones                      |
| --------- | --------------- | ------ | ----------------------------------- |
| Phase A   | 8–12 weeks      | 16     | 1:1 calls working, setup < 2s       |
| Phase B   | 6–8 weeks       | 7      | Group calls (8 ppl), two-loop ABR   |
| Phase C   | 6–8 weeks       | 6      | 5k CCU, multi-region, auto-recovery |
| Phase D   | Ongoing         | 5      | VP9/AV1, ML QoE, screen share, E2EE |
| **Total** | **20–28 weeks** | **34** | Full system operational at scale    |

---

## Risk Register

| Risk                                      | Impact | Likelihood | Mitigation                                      |
| ----------------------------------------- | ------ | ---------- | ----------------------------------------------- |
| libwebrtc build complexity                | High   | Medium     | Use prebuilt binaries (LiveKit's WebRTC build)  |
| P2P success rate too low → high TURN cost | Medium | Medium     | ICE optimization, monitor early, adjust pricing |
| CallKit/ConnectionService API changes     | Medium | Low        | Abstract call management layer, version check   |
| LiveKit performance at scale              | High   | Low        | Load test early (Phase A), have fallback plan   |
| Cross-region latency unacceptable         | Medium | Medium     | Choose nearby regions, CDN for signaling        |
| ClickHouse operational complexity         | Low    | Medium     | Start with managed service, migrate later       |

---

_Document version: 1.0 | Based on: Technical Design Spec v1 | Last updated: 2026-02-25_
