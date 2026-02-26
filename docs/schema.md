# Database Schema

## Overview

Lalo uses three data stores optimized for their respective workloads:

| Store      | Purpose                            | Data Characteristics     |
| ---------- | ---------------------------------- | ------------------------ |
| PostgreSQL | Metadata, config, call history     | Relational, ACID         |
| ClickHouse | QoS metrics, CDR analytics         | Time-series, append-only |
| Redis      | Session state, presence, ephemeral | Key-value, TTL-based     |

---

## PostgreSQL Tables

### `users`

User reference table (synced from main application).

| Column       | Type        | Constraints   |
| ------------ | ----------- | ------------- |
| id           | UUID        | PRIMARY KEY   |
| display_name | TEXT        | NOT NULL      |
| avatar_url   | TEXT        |               |
| created_at   | TIMESTAMPTZ | DEFAULT now() |

### `call_configs`

Per-user or global call configuration overrides.

| Column     | Type        | Constraints                             |
| ---------- | ----------- | --------------------------------------- |
| id         | UUID        | PRIMARY KEY, DEFAULT gen_random_uuid()  |
| scope      | TEXT        | NOT NULL, CHECK ('global', 'user')      |
| scope_id   | UUID        | NULL for global, user_id for user scope |
| config     | JSONB       | NOT NULL                                |
| updated_at | TIMESTAMPTZ | DEFAULT now()                           |

**Indexes:** UNIQUE(scope, scope_id)

### `call_history`

Completed call records.

| Column           | Type        | Constraints                            |
| ---------------- | ----------- | -------------------------------------- |
| id               | UUID        | PRIMARY KEY, DEFAULT gen_random_uuid() |
| call_id          | UUID        | NOT NULL, UNIQUE                       |
| call_type        | TEXT        | NOT NULL, CHECK ('1:1', 'group')       |
| initiator_id     | UUID        | NOT NULL, FK → users(id)               |
| started_at       | TIMESTAMPTZ |                                        |
| ended_at         | TIMESTAMPTZ |                                        |
| duration_seconds | INT         |                                        |
| topology         | TEXT        | CHECK ('p2p', 'turn', 'sfu')           |
| end_reason       | TEXT        |                                        |
| region           | TEXT        |                                        |
| created_at       | TIMESTAMPTZ | DEFAULT now()                          |

**Indexes:** initiator_id, started_at, call_type

### `call_participants`

Per-participant records for each call.

| Column     | Type        | Constraints                                       |
| ---------- | ----------- | ------------------------------------------------- |
| id         | UUID        | PRIMARY KEY, DEFAULT gen_random_uuid()            |
| call_id    | UUID        | NOT NULL, FK → call_history(call_id) CASCADE      |
| user_id    | UUID        | NOT NULL, FK → users(id)                          |
| role       | TEXT        | NOT NULL, CHECK ('caller','callee','participant') |
| joined_at  | TIMESTAMPTZ |                                                   |
| left_at    | TIMESTAMPTZ |                                                   |
| end_reason | TEXT        |                                                   |

**Indexes:** call_id, user_id, UNIQUE(call_id, user_id)

### `push_tokens`

Mobile push notification tokens.

| Column      | Type        | Constraints                            |
| ----------- | ----------- | -------------------------------------- |
| id          | UUID        | PRIMARY KEY, DEFAULT gen_random_uuid() |
| user_id     | UUID        | NOT NULL, FK → users(id)               |
| device_id   | TEXT        | NOT NULL                               |
| platform    | TEXT        | NOT NULL, CHECK ('ios', 'android')     |
| push_token  | TEXT        | NOT NULL                               |
| voip_token  | TEXT        | iOS PushKit only                       |
| app_version | TEXT        |                                        |
| bundle_id   | TEXT        |                                        |
| is_active   | BOOLEAN     | DEFAULT true                           |
| created_at  | TIMESTAMPTZ | DEFAULT now()                          |
| updated_at  | TIMESTAMPTZ | DEFAULT now()                          |

**Indexes:** user_id WHERE is_active, UNIQUE(user_id, device_id)

---

## ClickHouse Tables

### `cdr` (Call Detail Records)

Aggregated per-call analytics. Ordered by region → time → call_id.

| Column            | Type                   | Notes               |
| ----------------- | ---------------------- | ------------------- |
| call_id           | UUID                   |                     |
| call_type         | LowCardinality(String) |                     |
| initiator_id      | UUID                   |                     |
| participants      | Array(UUID)            |                     |
| started_at        | DateTime64(3)          |                     |
| ended_at          | DateTime64(3)          |                     |
| duration_seconds  | UInt32                 |                     |
| setup_latency_ms  | UInt32                 |                     |
| topology          | LowCardinality(String) |                     |
| region            | LowCardinality(String) |                     |
| avg_mos           | Float32                | Mean Opinion Score  |
| avg_packet_loss   | Float32                |                     |
| avg_rtt_ms        | UInt32                 |                     |
| avg_bitrate_kbps  | UInt32                 |                     |
| tier_good_pct     | Float32                | % time in good tier |
| tier_fair_pct     | Float32                |                     |
| tier_poor_pct     | Float32                |                     |
| video_off_seconds | UInt32                 |                     |
| reconnect_count   | UInt8                  |                     |
| end_reason        | LowCardinality(String) |                     |

**Engine:** MergeTree(), ORDER BY (region, started_at, call_id)

### `qos_metrics` (Quality of Service)

Per-second samples per participant. Auto-expired after 30 days.

| Column          | Type                   | Notes       |
| --------------- | ---------------------- | ----------- |
| call_id         | UUID                   |             |
| participant_id  | UUID                   |             |
| ts              | DateTime64(3)          |             |
| direction       | LowCardinality(String) | send / recv |
| rtt_ms          | UInt32                 |             |
| packet_loss_pct | Float32                |             |
| jitter_ms       | Float32                |             |
| bitrate_kbps    | UInt32                 |             |
| framerate       | UInt8                  |             |
| resolution      | LowCardinality(String) |             |
| network_tier    | LowCardinality(String) |             |

**Engine:** MergeTree(), ORDER BY (call_id, participant_id, ts), TTL ts + 30 days

---

## Redis Key Structure

| Key Pattern                      | Type   | Fields / Value                                          | TTL    |
| -------------------------------- | ------ | ------------------------------------------------------- | ------ |
| `session:{call_id}`              | Hash   | state, type, topology, created_at, initiator_id, region | 24h    |
| `session:{call_id}:participants` | Set    | {user_id_1, user_id_2, ...}                             | 24h    |
| `user:{user_id}:active_call`     | String | call_id                                                 | 24h    |
| `presence:{user_id}`             | Hash   | status, last_seen, device_id                            | 5 min  |
| `turn:creds:{session_id}`        | Hash   | username, password, ttl                                 | 10 min |

---

## Migration Tool

PostgreSQL migrations use [golang-migrate](https://github.com/golang-migrate/migrate).

```bash
# Run migrations up
migrate -path migrations/postgres -database "postgres://lalo:lalo_dev@localhost:5432/lalo?sslmode=disable" up

# Rollback last migration
migrate -path migrations/postgres -database "postgres://lalo:lalo_dev@localhost:5432/lalo?sslmode=disable" down 1

# Seed data
psql -U lalo -d lalo -f scripts/seed.sql
```

ClickHouse tables are created via direct SQL execution:

```bash
clickhouse-client --query "$(cat migrations/clickhouse/001_create_tables.sql)"
```
