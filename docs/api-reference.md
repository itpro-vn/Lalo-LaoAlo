# API Reference

## Authentication

Tất cả API endpoints yêu cầu JWT token:

```
Authorization: Bearer <access_token>
```

WebSocket connections hỗ trợ token qua query param:

```
ws://host:8080/ws?token=<access_token>
```

---

## REST API — Orchestrator (`:8081`)

### Session Management

#### POST `/api/v1/sessions` — Tạo cuộc gọi 1:1

**Request:**

```json
{
  "callee_id": "uuid-string",
  "call_type": "1:1",
  "has_video": true
}
```

**Response:** `201 Created`

```json
{
  "session_id": "uuid-string",
  "call_id": "uuid-string",
  "topology": "p2p",
  "turn_credentials": {
    "username": "1709836800:user-id",
    "password": "base64-hmac-sha1",
    "ttl": 86400,
    "uris": ["turn:localhost:3478"]
  }
}
```

#### GET `/api/v1/sessions/:id` — Lấy thông tin session

**Response:** `200 OK`

```json
{
  "id": "uuid-string",
  "call_id": "uuid-string",
  "call_type": "1:1",
  "topology": "p2p",
  "state": "connected",
  "participants": [...],
  "created_at": "2026-01-01T00:00:00Z"
}
```

#### POST `/api/v1/sessions/:id/join` — Tham gia session

**Request:**

```json
{
  "role": "callee"
}
```

**Response:** `200 OK`

```json
{
  "session_id": "uuid-string",
  "topology": "p2p",
  "turn_credentials": {...}
}
```

#### POST `/api/v1/sessions/:id/leave` — Rời session

**Response:** `200 OK`

```json
{
  "status": "left"
}
```

#### POST `/api/v1/sessions/:id/end` — Kết thúc session

**Request:**

```json
{
  "reason": "normal"
}
```

**Response:** `200 OK`

```json
{
  "status": "ended"
}
```

#### PATCH `/api/v1/sessions/:id/media` — Cập nhật media state

**Request:**

```json
{
  "audio_enabled": true,
  "video_enabled": false,
  "screen_sharing": false
}
```

**Response:** `200 OK`

```json
{
  "status": "updated"
}
```

#### GET `/api/v1/sessions/:id/turn-credentials` — Lấy TURN credentials

**Response:** `200 OK`

```json
{
  "username": "1709836800:user-id",
  "password": "base64-hmac-sha1",
  "ttl": 86400,
  "uris": ["turn:localhost:3478"]
}
```

---

### Room Management (Group Calls)

#### POST `/api/v1/rooms` — Tạo group call

**Request:**

```json
{
  "participants": ["user-id-1", "user-id-2"],
  "call_type": "video"
}
```

**Response:** `201 Created`

```json
{
  "session_id": "uuid-string",
  "room_id": "uuid-string",
  "livekit_token": "jwt-token",
  "livekit_url": "ws://localhost:7880"
}
```

#### POST `/api/v1/rooms/:id/invite` — Mời thêm người

**Request:**

```json
{
  "invitees": ["user-id-3"]
}
```

**Response:** `200 OK`

#### POST `/api/v1/rooms/:id/join` — Tham gia room

**Response:** `200 OK`

```json
{
  "session_id": "uuid-string",
  "livekit_token": "jwt-token",
  "livekit_url": "ws://localhost:7880"
}
```

#### POST `/api/v1/rooms/:id/leave` — Rời room

**Response:** `200 OK`

```json
{
  "status": "left"
}
```

#### POST `/api/v1/rooms/:id/end` — Đóng room (chỉ host)

**Response:** `200 OK`

```json
{
  "status": "closed"
}
```

#### GET `/api/v1/rooms/:id/participants` — Danh sách participants

**Response:** `200 OK`

```json
{
  "participants": [
    {
      "user_id": "uuid-string",
      "role": "host",
      "audio_enabled": true,
      "video_enabled": true
    }
  ]
}
```

---

## REST API — Push Gateway (`:8082`)

#### POST `/v1/push/register` — Đăng ký push token

**Request:**

```json
{
  "device_id": "device-uuid",
  "platform": "ios",
  "push_token": "apns-device-token",
  "voip_token": "pushkit-voip-token",
  "app_version": "1.0.0",
  "bundle_id": "com.lalo.app"
}
```

**Response:** `200 OK`

```json
{
  "status": "registered",
  "token": "token-id"
}
```

#### DELETE `/v1/push/unregister` — Hủy đăng ký push token

**Request:**

```json
{
  "device_id": "device-uuid"
}
```

**Response:** `200 OK`

```json
{
  "status": "unregistered"
}
```

---

## REST API — Policy Engine

#### POST `/v1/policy/metrics` — Gửi QoS metrics

**Request:**

```json
{
  "session_id": "uuid-string",
  "user_id": "uuid-string",
  "samples": [
    {
      "timestamp": "2026-01-01T00:00:00Z",
      "rtt_ms": 50.0,
      "loss_percent": 1.5,
      "jitter_ms": 10.0,
      "bandwidth_kbps": 500.0,
      "tier": "good",
      "audio_level": -30.0,
      "frame_width": 1280,
      "frame_height": 720,
      "fps": 30.0
    }
  ]
}
```

**Response:** `200 OK`

```json
{
  "status": "ingested"
}
```

#### GET `/v1/policy/participant/:sessionID/:userID` — Lấy policy decision

**Response:** `200 OK`

```json
{
  "max_tier": "fair",
  "force_audio_only": false,
  "max_bitrate_kbps": 500,
  "force_codec": null,
  "reason": "high_loss_cap_fair"
}
```

#### GET `/v1/policy/health` — Health check

**Response:** `200 OK`

---

## Health Check

Tất cả services đều có health endpoint:

#### GET `/health`

**Response:** `200 OK`

```json
{
  "status": "ok"
}
```

---

## WebSocket Protocol — Signaling (`:8080`)

### Kết nối

```
GET /ws?token=<jwt_access_token>
Upgrade: websocket
Connection: Upgrade
```

### Message Envelope

Tất cả messages đều wrapped trong envelope:

```json
{
  "type": "message_type",
  "data": { ... },
  "seq": 12345,
  "msg_id": "unique-id"
}
```

| Field    | Type   | Mô tả                                  |
| -------- | ------ | -------------------------------------- |
| `type`   | string | Loại message (bắt buộc)                |
| `data`   | object | Payload tùy theo type                  |
| `seq`    | int64  | Sequence number (server → client)      |
| `msg_id` | string | Message ID (client → server, optional) |

---

### Client → Server Messages

#### `call_initiate` — Bắt đầu cuộc gọi

```json
{
  "type": "call_initiate",
  "data": {
    "callee_id": "uuid-string",
    "sdp_offer": "v=0\r\n...",
    "call_type": "video"
  }
}
```

#### `call_accept` — Chấp nhận cuộc gọi

```json
{
  "type": "call_accept",
  "data": {
    "call_id": "uuid-string",
    "sdp_answer": "v=0\r\n..."
  }
}
```

#### `call_reject` — Từ chối cuộc gọi

```json
{
  "type": "call_reject",
  "data": {
    "call_id": "uuid-string",
    "reason": "busy"
  }
}
```

Reasons: `busy`, `declined`

#### `call_end` — Kết thúc cuộc gọi

```json
{
  "type": "call_end",
  "data": {
    "call_id": "uuid-string"
  }
}
```

#### `call_cancel` — Hủy cuộc gọi (trước khi callee accept)

```json
{
  "type": "call_cancel",
  "data": {
    "call_id": "uuid-string"
  }
}
```

#### `ice_candidate` — Gửi ICE candidate

```json
{
  "type": "ice_candidate",
  "data": {
    "call_id": "uuid-string",
    "candidate": "candidate:1 1 UDP ..."
  }
}
```

#### `quality_metrics` — Gửi QoS metrics

```json
{
  "type": "quality_metrics",
  "data": {
    "call_id": "uuid-string",
    "samples": [
      {
        "ts": 1709836800000,
        "direction": "send",
        "rtt_ms": 50,
        "loss_pct": 1.5,
        "jitter_ms": 10.0,
        "bitrate_kbps": 500,
        "framerate": 30,
        "resolution": "1280x720",
        "network_tier": "good"
      }
    ]
  }
}
```

#### `ping` — Heartbeat

```json
{
  "type": "ping"
}
```

#### `reconnect` — Reconnect sau khi mất kết nối

```json
{
  "type": "reconnect",
  "data": {
    "call_id": "uuid-string"
  }
}
```

#### `room_create` — Tạo group call

```json
{
  "type": "room_create",
  "data": {
    "participants": ["user-id-1", "user-id-2"],
    "call_type": "video"
  }
}
```

#### `room_invite` — Mời thêm người

```json
{
  "type": "room_invite",
  "data": {
    "room_id": "uuid-string",
    "invitees": ["user-id-3"]
  }
}
```

#### `room_join` — Tham gia room

```json
{
  "type": "room_join",
  "data": {
    "room_id": "uuid-string"
  }
}
```

#### `room_leave` — Rời room

```json
{
  "type": "room_leave",
  "data": {
    "room_id": "uuid-string"
  }
}
```

#### `room_end_all` — Đóng room (host)

```json
{
  "type": "room_end_all",
  "data": {
    "room_id": "uuid-string"
  }
}
```

#### `media_change` — Thay đổi media state trong room

```json
{
  "type": "media_change",
  "data": {
    "room_id": "uuid-string",
    "audio": true,
    "video": false
  }
}
```

---

### Server → Client Messages

#### `incoming_call` — Có cuộc gọi đến

```json
{
  "type": "incoming_call",
  "data": {
    "call_id": "uuid-string",
    "caller_id": "uuid-string",
    "caller_name": "John Doe",
    "sdp_offer": "v=0\r\n...",
    "call_type": "video"
  }
}
```

#### `call_accepted` — Cuộc gọi đã được chấp nhận

```json
{
  "type": "call_accepted",
  "data": {
    "call_id": "uuid-string",
    "sdp_answer": "v=0\r\n..."
  }
}
```

#### `call_rejected` — Cuộc gọi bị từ chối

```json
{
  "type": "call_rejected",
  "data": {
    "call_id": "uuid-string",
    "reason": "busy"
  }
}
```

#### `call_ended` — Cuộc gọi kết thúc

```json
{
  "type": "call_ended",
  "data": {
    "call_id": "uuid-string",
    "reason": "normal"
  }
}
```

Reasons: `normal`, `timeout`, `error`

#### `call_cancelled` — Cuộc gọi đã bị hủy

```json
{
  "type": "call_cancelled",
  "data": {
    "call_id": "uuid-string"
  }
}
```

#### `call_glare` — Glare resolution (2 bên gọi đồng thời)

```json
{
  "type": "call_glare",
  "data": {
    "cancelled_call_id": "uuid-string",
    "winning_call_id": "uuid-string",
    "peer_id": "uuid-string"
  }
}
```

#### `call_accepted_elsewhere` — Cuộc gọi đã được nhận trên thiết bị khác

```json
{
  "type": "call_accepted_elsewhere",
  "data": {
    "call_id": "uuid-string",
    "device_id": "device-uuid"
  }
}
```

#### `state_sync` — Đồng bộ trạng thái

```json
{
  "type": "state_sync",
  "data": {
    "active_calls": [
      {
        "call_id": "uuid-string",
        "peer_id": "uuid-string",
        "call_type": "video",
        "state": "connected",
        "role": "caller"
      }
    ]
  }
}
```

#### `session_resumed` — Session đã được khôi phục

```json
{
  "type": "session_resumed",
  "data": {
    "call_id": "uuid-string",
    "state": "connected",
    "peer_id": "uuid-string",
    "sdp_offer": "v=0\r\n..."
  }
}
```

#### `peer_reconnecting` — Peer đang reconnect

```json
{
  "type": "peer_reconnecting",
  "data": {
    "call_id": "uuid-string",
    "peer_id": "uuid-string"
  }
}
```

#### `peer_reconnected` — Peer đã reconnect thành công

```json
{
  "type": "peer_reconnected",
  "data": {
    "call_id": "uuid-string",
    "peer_id": "uuid-string"
  }
}
```

#### `room_created` — Room đã được tạo

```json
{
  "type": "room_created",
  "data": {
    "room_id": "uuid-string",
    "livekit_token": "jwt-token",
    "livekit_url": "ws://localhost:7880"
  }
}
```

#### `room_invitation` — Lời mời tham gia room

```json
{
  "type": "room_invitation",
  "data": {
    "room_id": "uuid-string",
    "inviter_id": "uuid-string",
    "call_type": "video",
    "participants": ["user-id-1", "user-id-2"]
  }
}
```

#### `room_closed` — Room đã đóng

```json
{
  "type": "room_closed",
  "data": {
    "room_id": "uuid-string",
    "reason": "host_left"
  }
}
```

Reasons: `host_left`, `all_left`, `ended`

#### `participant_joined` — Người tham gia vào room

```json
{
  "type": "participant_joined",
  "data": {
    "room_id": "uuid-string",
    "user_id": "uuid-string",
    "role": "participant"
  }
}
```

#### `participant_left` — Người rời room

```json
{
  "type": "participant_left",
  "data": {
    "room_id": "uuid-string",
    "user_id": "uuid-string"
  }
}
```

#### `participant_media_changed` — Thay đổi media trong room

```json
{
  "type": "participant_media_changed",
  "data": {
    "room_id": "uuid-string",
    "user_id": "uuid-string",
    "audio": true,
    "video": false
  }
}
```

#### `error` — Lỗi

```json
{
  "type": "error",
  "data": {
    "code": "invalid_message",
    "message": "Mô tả lỗi",
    "call_id": "uuid-string"
  }
}
```

#### `pong` — Heartbeat response

```json
{
  "type": "pong"
}
```

---

### Error Codes

| Code               | Mô tả                                 |
| ------------------ | ------------------------------------- |
| `invalid_message`  | Message format không hợp lệ           |
| `unauthorized`     | Chưa xác thực hoặc token hết hạn      |
| `not_found`        | Call/room/user không tồn tại          |
| `busy`             | Callee đang trong cuộc gọi khác       |
| `timeout`          | Hết thời gian chờ (ring timeout)      |
| `rate_limited`     | Vượt quá rate limit                   |
| `internal_error`   | Lỗi server nội bộ                     |
| `invalid_state`    | Trạng thái không hợp lệ cho action    |
| `room_full`        | Room đã đủ số lượng tối đa            |
| `reconnect_failed` | Reconnect thất bại                    |
| `glare`            | Phát hiện glare (2 bên gọi đồng thời) |
| `call_cancelled`   | Cuộc gọi đã bị hủy                    |
| `duplicate`        | Request trùng lặp                     |
| `invalid_sdp`      | SDP offer/answer không hợp lệ         |
