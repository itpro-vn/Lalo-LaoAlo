# Cấu hình hệ thống

## Tổng quan

Lalo sử dụng cấu hình dạng YAML với hỗ trợ override qua environment variables.

- **Config file:** `configs/call-config.yaml`
- **Env prefix:** `LALO_` (e.g. `LALO_POSTGRES_HOST=db.prod.lalo.dev`)

---

## Server

```yaml
server:
  port: 8080 # Port cho service
  host: "0.0.0.0" # Bind address
  allowed_origins: [] # CORS origins (rỗng = cho phép tất cả)
```

| Field             | Type     | Default     | Env Override       | Mô tả                |
| ----------------- | -------- | ----------- | ------------------ | -------------------- |
| `port`            | int      | `8080`      | `LALO_SERVER_PORT` | HTTP/WS port         |
| `host`            | string   | `"0.0.0.0"` | `LALO_SERVER_HOST` | Bind address         |
| `allowed_origins` | []string | `[]`        | -                  | CORS allowed origins |

---

## Call

```yaml
call:
  ring_timeout_seconds: 45
  ice_timeout_seconds: 15
  cleanup_timeout_seconds: 5
  max_reconnect_attempts: 3
  reconnect_backoff: [0, 1000, 3000]
```

| Field                     | Type  | Default           | Mô tả                              |
| ------------------------- | ----- | ----------------- | ---------------------------------- |
| `ring_timeout_seconds`    | int   | `45`              | Thời gian chờ nhận cuộc gọi        |
| `ice_timeout_seconds`     | int   | `15`              | Thời gian chờ ICE connection       |
| `cleanup_timeout_seconds` | int   | `5`               | Thời gian cleanup sau khi kết thúc |
| `max_reconnect_attempts`  | int   | `3`               | Số lần reconnect tối đa            |
| `reconnect_backoff`       | []int | `[0, 1000, 3000]` | Backoff intervals (ms)             |

---

## Quality (ABR)

```yaml
quality:
  tiers:
    good:
      rtt_max_ms: 120
      loss_max_pct: 2
      jitter_max_ms: 20
    fair:
      rtt_max_ms: 250
      loss_max_pct: 6
      jitter_max_ms: 50
    poor:
      rtt_above_ms: 250
      loss_above_pct: 6
      jitter_above_ms: 50
  hysteresis:
    upgrade_stable_seconds: 10
    downgrade_fair_seconds: 2
    downgrade_poor_seconds: 1
    max_codec_change_interval_seconds: 30
  audio:
    codec: opus
    dtx: true
    fec_threshold_loss_pct: 2
    bitrate_range_kbps: [12, 32]
  video:
    codecs: [vp8, h264]
    simulcast_layers: 3
    max_resolution: 720p
    max_framerate: 30
    keyframe_interval_seconds: 2
  bandwidth:
    audio_only_threshold_kbps: 100
    video_resume_threshold_kbps: 200
    video_resume_stable_seconds: 10
```

### Quality Tiers

| Tier | RTT Max | Loss Max | Jitter Max |
| ---- | ------- | -------- | ---------- |
| Good | ≤ 120ms | ≤ 2%     | ≤ 20ms     |
| Fair | ≤ 250ms | ≤ 6%     | ≤ 50ms     |
| Poor | > 250ms | > 6%     | > 50ms     |

### Hysteresis

| Parameter                           | Giá trị | Mô tả                                     |
| ----------------------------------- | ------- | ----------------------------------------- |
| `upgrade_stable_seconds`            | 10      | Thời gian ổn định trước khi nâng tier     |
| `downgrade_fair_seconds`            | 2       | Thời gian trước khi hạ xuống Fair         |
| `downgrade_poor_seconds`            | 1       | Thời gian trước khi hạ xuống Poor         |
| `max_codec_change_interval_seconds` | 30      | Interval tối thiểu giữa các lần đổi codec |

### Audio

| Parameter                | Giá trị    | Mô tả                      |
| ------------------------ | ---------- | -------------------------- |
| `codec`                  | `opus`     | Audio codec                |
| `dtx`                    | `true`     | Discontinuous Transmission |
| `fec_threshold_loss_pct` | `2`        | Bật FEC khi loss > 2%      |
| `bitrate_range_kbps`     | `[12, 32]` | Range bitrate audio        |

### Video

| Parameter                   | Giá trị       | Mô tả                |
| --------------------------- | ------------- | -------------------- |
| `codecs`                    | `[vp8, h264]` | Video codecs ưu tiên |
| `simulcast_layers`          | `3`           | Số simulcast layers  |
| `max_resolution`            | `720p`        | Độ phân giải tối đa  |
| `max_framerate`             | `30`          | FPS tối đa           |
| `keyframe_interval_seconds` | `2`           | Interval keyframe    |

### Bandwidth

| Parameter                     | Giá trị | Mô tả                                    |
| ----------------------------- | ------- | ---------------------------------------- |
| `audio_only_threshold_kbps`   | `100`   | Dưới ngưỡng này → audio only             |
| `video_resume_threshold_kbps` | `200`   | Trên ngưỡng này → resume video           |
| `video_resume_stable_seconds` | `10`    | Thời gian ổn định trước khi resume video |

---

## Group Call

```yaml
group:
  max_participants: 8
  active_video_slots: 4
  hq_slots: 2
  mq_slots: 2
  speaker_detection_threshold_db: -40
  speaker_hold_seconds: 3
```

| Field                            | Type | Default | Mô tả                           |
| -------------------------------- | ---- | ------- | ------------------------------- |
| `max_participants`               | int  | `8`     | Số người tham gia tối đa        |
| `active_video_slots`             | int  | `4`     | Số video streams hiển thị       |
| `hq_slots`                       | int  | `2`     | Số slots chất lượng cao         |
| `mq_slots`                       | int  | `2`     | Số slots chất lượng trung bình  |
| `speaker_detection_threshold_db` | int  | `-40`   | Ngưỡng phát hiện người nói (dB) |
| `speaker_hold_seconds`           | int  | `3`     | Giữ active speaker trong N giây |

---

## TURN Server

```yaml
turn:
  allocation_ttl_seconds: 600
  max_allocations_per_user: 5
  credential_ttl_seconds: 86400
  servers:
    - "turn:localhost:3478"
  health_check_interval_seconds: 10
  health_check_timeout_seconds: 5
```

| Field                           | Type     | Default                   | Mô tả                          |
| ------------------------------- | -------- | ------------------------- | ------------------------------ |
| `allocation_ttl_seconds`        | int      | `600`                     | TTL cho TURN allocation        |
| `max_allocations_per_user`      | int      | `5`                       | Max allocations per user       |
| `credential_ttl_seconds`        | int      | `86400`                   | TTL cho TURN credentials (24h) |
| `servers`                       | []string | `["turn:localhost:3478"]` | TURN server URIs               |
| `health_check_interval_seconds` | int      | `10`                      | Interval health check          |
| `health_check_timeout_seconds`  | int      | `5`                       | Timeout health check           |

---

## Push Notifications

```yaml
push:
  port: 8082
  apns:
    team_id: ""
    key_id: ""
    key_path: ""
    bundle_id: "com.lalo.app"
    production: false
  fcm:
    server_key: ""
    project_id: ""
```

### APNs (iOS)

| Field        | Type   | Default          | Env Override    | Mô tả                   |
| ------------ | ------ | ---------------- | --------------- | ----------------------- |
| `team_id`    | string | `""`             | `APNS_TEAM_ID`  | Apple Team ID           |
| `key_id`     | string | `""`             | `APNS_KEY_ID`   | APNs Key ID             |
| `key_path`   | string | `""`             | `APNS_KEY_PATH` | Path tới .p8 key file   |
| `bundle_id`  | string | `"com.lalo.app"` | -               | iOS Bundle ID           |
| `production` | bool   | `false`          | -               | Sử dụng APNs production |

### FCM (Android)

| Field        | Type   | Default | Env Override     | Mô tả               |
| ------------ | ------ | ------- | ---------------- | ------------------- |
| `server_key` | string | `""`    | `FCM_SERVER_KEY` | FCM Server Key      |
| `project_id` | string | `""`    | `FCM_PROJECT_ID` | Firebase Project ID |

---

## Rate Limiting

```yaml
rate_limits:
  call_initiate_per_user: "10/min"
  call_initiate_global_cps: 500
  signaling_messages_per_connection: "100/min"
  turn_allocations_per_user: "5/min"
  api_requests_per_user: "60/min"
```

| Field                               | Default   | Mô tả                             |
| ----------------------------------- | --------- | --------------------------------- |
| `call_initiate_per_user`            | `10/min`  | Số cuộc gọi khởi tạo per user     |
| `call_initiate_global_cps`          | `500`     | Calls per second toàn hệ thống    |
| `signaling_messages_per_connection` | `100/min` | Messages per WebSocket connection |
| `turn_allocations_per_user`         | `5/min`   | TURN allocations per user         |
| `api_requests_per_user`             | `60/min`  | API requests per user             |

---

## Policy Engine

```yaml
policy_engine:
  enabled: true
  eval_interval_seconds: 10
  metric_window_seconds: 30
  rules:
    - name: high_loss_cap_fair
      condition: avg_loss_above
      threshold: 8.0
      action: cap_tier
      action_value: fair
    - name: very_high_loss_cap_poor
      condition: avg_loss_above
      threshold: 15.0
      action: cap_tier
      action_value: poor
    - name: high_rtt_cap_fair
      condition: avg_rtt_above
      threshold: 300.0
      action: cap_tier
      action_value: fair
    - name: low_bandwidth_audio_only
      condition: bandwidth_below
      threshold: 80.0
      action: force_audio_only
      action_value: "true"
```

### Policy Rule Fields

| Field          | Type    | Mô tả                                                           |
| -------------- | ------- | --------------------------------------------------------------- |
| `name`         | string  | Tên rule (unique)                                               |
| `condition`    | string  | Điều kiện: `avg_loss_above`, `avg_rtt_above`, `bandwidth_below` |
| `threshold`    | float64 | Ngưỡng trigger                                                  |
| `action`       | string  | Hành động: `cap_tier`, `force_audio_only`, `cap_bitrate`        |
| `action_value` | string  | Giá trị action: `"fair"`, `"poor"`, `"true"`, kbps value        |

---

## Database Connections

```yaml
postgres:
  host: localhost
  port: 5432
  user: lalo
  password: lalo_dev
  dbname: lalo
  sslmode: disable

redis:
  addr: localhost:6379
  password: ""
  db: 0

nats:
  url: nats://localhost:4222

clickhouse:
  addr: localhost:9000
  database: lalo
  user: default
  password: ""

livekit:
  host: http://localhost:7880
  api_key: ""
  api_secret: ""
```

### Environment Overrides

| Config               | Env Variable              | Mô tả               |
| -------------------- | ------------------------- | ------------------- |
| `postgres.host`      | `LALO_POSTGRES_HOST`      | PostgreSQL host     |
| `postgres.port`      | `LALO_POSTGRES_PORT`      | PostgreSQL port     |
| `postgres.user`      | `LALO_POSTGRES_USER`      | PostgreSQL user     |
| `postgres.password`  | `LALO_POSTGRES_PASSWORD`  | PostgreSQL password |
| `redis.addr`         | `LALO_REDIS_ADDR`         | Redis address       |
| `nats.url`           | `LALO_NATS_URL`           | NATS URL            |
| `livekit.api_key`    | `LALO_LIVEKIT_API_KEY`    | LiveKit API key     |
| `livekit.api_secret` | `LALO_LIVEKIT_API_SECRET` | LiveKit API secret  |

---

## Authentication

```yaml
auth:
  jwt_secret: ""
  access_token_expiry_mins: 15
  refresh_token_expiry_days: 7
  turn_secret: ""
```

| Field                       | Type   | Default | Env Override       | Mô tả                          |
| --------------------------- | ------ | ------- | ------------------ | ------------------------------ |
| `jwt_secret`                | string | `""`    | `LALO_JWT_SECRET`  | JWT signing secret             |
| `access_token_expiry_mins`  | int    | `15`    | -                  | Access token TTL (phút)        |
| `refresh_token_expiry_days` | int    | `7`     | -                  | Refresh token TTL (ngày)       |
| `turn_secret`               | string | `""`    | `LALO_TURN_SECRET` | TURN shared secret (HMAC-SHA1) |
