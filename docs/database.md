# Database Schema

## Tổng quan

Lalo sử dụng 2 hệ thống database:

- **PostgreSQL 16** — Dữ liệu transactional (users, call history, push tokens)
- **ClickHouse 24** — Analytics & metrics (CDR, QoS samples)

Ngoài ra, **Redis 7** được sử dụng cho real-time state.

---

## PostgreSQL

### Migrations

```
migrations/postgres/
├── 001_create_users.up.sql
├── 001_create_users.down.sql
├── 002_create_call_configs.up.sql
├── 002_create_call_configs.down.sql
├── 003_create_call_history.up.sql
├── 003_create_call_history.down.sql
├── 004_create_call_participants.up.sql
├── 004_create_call_participants.down.sql
├── 005_create_push_tokens.up.sql
└── 005_create_push_tokens.down.sql
```

### Table: `users`

Lưu trữ thông tin user.

```sql
CREATE TABLE IF NOT EXISTS users (
    id            UUID PRIMARY KEY,
    display_name  TEXT NOT NULL,
    avatar_url    TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_users_created_at ON users (created_at);
```

| Column         | Type        | Nullable | Mô tả         |
| -------------- | ----------- | -------- | ------------- |
| `id`           | UUID        | NO       | Primary key   |
| `display_name` | TEXT        | NO       | Tên hiển thị  |
| `avatar_url`   | TEXT        | YES      | URL avatar    |
| `created_at`   | TIMESTAMPTZ | NO       | Thời gian tạo |

### Table: `call_configs`

Cấu hình cuộc gọi theo scope (global hoặc per-user).

```sql
CREATE TABLE IF NOT EXISTS call_configs (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    scope      TEXT NOT NULL CHECK (scope IN ('global', 'user')),
    scope_id   UUID,
    config     JSONB NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_call_configs_scope ON call_configs (scope, scope_id);
CREATE INDEX idx_call_configs_scope_id ON call_configs (scope_id) WHERE scope_id IS NOT NULL;
```

| Column       | Type        | Nullable | Mô tả                                   |
| ------------ | ----------- | -------- | --------------------------------------- |
| `id`         | UUID        | NO       | Primary key (auto-generated)            |
| `scope`      | TEXT        | NO       | `'global'` hoặc `'user'`                |
| `scope_id`   | UUID        | YES      | NULL cho global, user_id cho user scope |
| `config`     | JSONB       | NO       | Cấu hình JSON                           |
| `updated_at` | TIMESTAMPTZ | NO       | Thời gian cập nhật                      |

### Table: `call_history`

Lịch sử cuộc gọi.

```sql
CREATE TABLE IF NOT EXISTS call_history (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    call_id          UUID NOT NULL UNIQUE,
    call_type        TEXT NOT NULL CHECK (call_type IN ('1:1', 'group')),
    initiator_id     UUID NOT NULL REFERENCES users(id),
    started_at       TIMESTAMPTZ,
    ended_at         TIMESTAMPTZ,
    duration_seconds INT,
    topology         TEXT CHECK (topology IN ('p2p', 'turn', 'sfu')),
    end_reason       TEXT,
    region           TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_call_history_initiator ON call_history (initiator_id);
CREATE INDEX idx_call_history_started_at ON call_history (started_at);
CREATE INDEX idx_call_history_call_type ON call_history (call_type);
```

| Column             | Type        | Nullable | Mô tả                      |
| ------------------ | ----------- | -------- | -------------------------- |
| `id`               | UUID        | NO       | Primary key                |
| `call_id`          | UUID        | NO       | Call ID (unique)           |
| `call_type`        | TEXT        | NO       | `'1:1'` hoặc `'group'`     |
| `initiator_id`     | UUID        | NO       | FK → users.id              |
| `started_at`       | TIMESTAMPTZ | YES      | Thời gian bắt đầu          |
| `ended_at`         | TIMESTAMPTZ | YES      | Thời gian kết thúc         |
| `duration_seconds` | INT         | YES      | Thời lượng (giây)          |
| `topology`         | TEXT        | YES      | `'p2p'`, `'turn'`, `'sfu'` |
| `end_reason`       | TEXT        | YES      | Lý do kết thúc             |
| `region`           | TEXT        | YES      | Region server              |
| `created_at`       | TIMESTAMPTZ | NO       | Thời gian tạo record       |

### Table: `call_participants`

Danh sách người tham gia cuộc gọi.

```sql
CREATE TABLE IF NOT EXISTS call_participants (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    call_id    UUID NOT NULL REFERENCES call_history(call_id) ON DELETE CASCADE,
    user_id    UUID NOT NULL REFERENCES users(id),
    role       TEXT NOT NULL CHECK (role IN ('caller', 'callee', 'participant')),
    joined_at  TIMESTAMPTZ,
    left_at    TIMESTAMPTZ,
    end_reason TEXT
);

CREATE INDEX idx_call_participants_call_id ON call_participants (call_id);
CREATE INDEX idx_call_participants_user_id ON call_participants (user_id);
CREATE UNIQUE INDEX idx_call_participants_call_user ON call_participants (call_id, user_id);
```

| Column       | Type        | Nullable | Mô tả                                   |
| ------------ | ----------- | -------- | --------------------------------------- |
| `id`         | UUID        | NO       | Primary key                             |
| `call_id`    | UUID        | NO       | FK → call_history.call_id (CASCADE)     |
| `user_id`    | UUID        | NO       | FK → users.id                           |
| `role`       | TEXT        | NO       | `'caller'`, `'callee'`, `'participant'` |
| `joined_at`  | TIMESTAMPTZ | YES      | Thời gian tham gia                      |
| `left_at`    | TIMESTAMPTZ | YES      | Thời gian rời                           |
| `end_reason` | TEXT        | YES      | Lý do rời                               |

### Table: `push_tokens`

Push notification tokens.

```sql
CREATE TABLE push_tokens (
    id          TEXT PRIMARY KEY,
    user_id     TEXT NOT NULL,
    device_id   TEXT NOT NULL,
    platform    TEXT NOT NULL,
    push_token  TEXT NOT NULL,
    voip_token  TEXT,
    app_version TEXT,
    bundle_id   TEXT,
    is_active   BOOLEAN DEFAULT true,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

| Column        | Type        | Nullable | Mô tả                    |
| ------------- | ----------- | -------- | ------------------------ |
| `id`          | TEXT        | NO       | Primary key              |
| `user_id`     | TEXT        | NO       | User ID                  |
| `device_id`   | TEXT        | NO       | Device ID                |
| `platform`    | TEXT        | NO       | `'ios'` hoặc `'android'` |
| `push_token`  | TEXT        | NO       | APNs/FCM token           |
| `voip_token`  | TEXT        | YES      | iOS PushKit VoIP token   |
| `app_version` | TEXT        | YES      | Phiên bản app            |
| `bundle_id`   | TEXT        | YES      | iOS bundle ID            |
| `is_active`   | BOOLEAN     | NO       | Token còn hoạt động      |
| `created_at`  | TIMESTAMPTZ | NO       | Thời gian tạo            |
| `updated_at`  | TIMESTAMPTZ | NO       | Thời gian cập nhật       |

---

## ClickHouse

### Migration

```
migrations/clickhouse/
└── 001_create_tables.sql
```

### Table: `cdr` (Call Detail Records)

Tổng hợp thông tin cuộc gọi cho analytics.

```sql
CREATE TABLE IF NOT EXISTS cdr (
    call_id            UUID,
    call_type          LowCardinality(String),
    initiator_id       UUID,
    participants       Array(UUID),
    started_at         DateTime64(3),
    ended_at           DateTime64(3),
    duration_seconds   UInt32,
    setup_latency_ms   UInt32,
    topology           LowCardinality(String),
    region             LowCardinality(String),
    avg_mos            Float32,
    avg_packet_loss    Float32,
    avg_rtt_ms         UInt32,
    avg_bitrate_kbps   UInt32,
    tier_good_pct      Float32,
    tier_fair_pct      Float32,
    tier_poor_pct      Float32,
    video_off_seconds  UInt32,
    reconnect_count    UInt8,
    end_reason         LowCardinality(String)
) ENGINE = MergeTree()
ORDER BY (region, started_at, call_id);
```

| Column              | Type          | Mô tả                            |
| ------------------- | ------------- | -------------------------------- |
| `call_id`           | UUID          | Call identifier                  |
| `call_type`         | String        | `'1:1'` hoặc `'group'`           |
| `initiator_id`      | UUID          | Người khởi tạo                   |
| `participants`      | Array(UUID)   | Danh sách participants           |
| `started_at`        | DateTime64(3) | Thời gian bắt đầu (ms precision) |
| `ended_at`          | DateTime64(3) | Thời gian kết thúc               |
| `duration_seconds`  | UInt32        | Thời lượng                       |
| `setup_latency_ms`  | UInt32        | Latency thiết lập cuộc gọi       |
| `topology`          | String        | `'p2p'`, `'turn'`, `'sfu'`       |
| `region`            | String        | Region                           |
| `avg_mos`           | Float32       | Mean Opinion Score trung bình    |
| `avg_packet_loss`   | Float32       | Packet loss trung bình (%)       |
| `avg_rtt_ms`        | UInt32        | RTT trung bình (ms)              |
| `avg_bitrate_kbps`  | UInt32        | Bitrate trung bình (kbps)        |
| `tier_good_pct`     | Float32       | % thời gian ở tier Good          |
| `tier_fair_pct`     | Float32       | % thời gian ở tier Fair          |
| `tier_poor_pct`     | Float32       | % thời gian ở tier Poor          |
| `video_off_seconds` | UInt32        | Thời gian tắt video              |
| `reconnect_count`   | UInt8         | Số lần reconnect                 |
| `end_reason`        | String        | Lý do kết thúc                   |

### Table: `qos_metrics` (Quality of Service Metrics)

Samples QoS per-second cho monitoring và ABR.

```sql
CREATE TABLE IF NOT EXISTS qos_metrics (
    call_id         UUID,
    participant_id  UUID,
    ts              DateTime64(3),
    direction       LowCardinality(String),
    rtt_ms          UInt32,
    packet_loss_pct Float32,
    jitter_ms       Float32,
    bitrate_kbps    UInt32,
    framerate       UInt8,
    resolution      LowCardinality(String),
    network_tier    LowCardinality(String)
) ENGINE = MergeTree()
ORDER BY (call_id, participant_id, ts)
TTL ts + INTERVAL 30 DAY;
```

| Column            | Type          | Mô tả                          |
| ----------------- | ------------- | ------------------------------ |
| `call_id`         | UUID          | Call identifier                |
| `participant_id`  | UUID          | Participant identifier         |
| `ts`              | DateTime64(3) | Timestamp (ms precision)       |
| `direction`       | String        | `'send'` hoặc `'recv'`         |
| `rtt_ms`          | UInt32        | Round-trip time (ms)           |
| `packet_loss_pct` | Float32       | Packet loss (%)                |
| `jitter_ms`       | Float32       | Jitter (ms)                    |
| `bitrate_kbps`    | UInt32        | Bitrate (kbps)                 |
| `framerate`       | UInt8         | FPS                            |
| `resolution`      | String        | Resolution (e.g. `'1280x720'`) |
| `network_tier`    | String        | `'good'`, `'fair'`, `'poor'`   |

**TTL:** Dữ liệu tự động xóa sau 30 ngày.

---

## Redis

Redis được sử dụng cho real-time state, không có schema cố định. Các key patterns chính:

| Pattern                         | Type   | Mô tả                        | TTL                |
| ------------------------------- | ------ | ---------------------------- | ------------------ |
| `session:{session_id}`          | Hash   | Session state                | Theo call duration |
| `user:{user_id}:connections`    | Set    | Active WebSocket connections | -                  |
| `user:{user_id}:active_call`    | String | Current active call ID       | Theo call duration |
| `call:{call_id}:ice_candidates` | List   | Pending ICE candidates       | 5 phút             |
| `rate:{user_id}:{action}`       | String | Rate limit counter           | 1 phút             |

---

## Entity Relationship

```
users
  │
  ├──< call_history (initiator_id)
  │         │
  │         └──< call_participants (call_id)
  │                  │
  │                  └── users (user_id)
  │
  └──< push_tokens (user_id)

ClickHouse (independent):
  cdr ──── qos_metrics (linked by call_id)
```

---

## Migration Commands

```bash
# Chạy tất cả migrations
make migrate-up

# Rollback migration gần nhất
make migrate-down

# Seed database
make seed
```
