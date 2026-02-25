# Technical Design Specification v1 — Adaptive Voice/Video Call System

| Field        | Value                                      |
| ------------ | ------------------------------------------ |
| **Version**  | 1.0                                        |
| **Status**   | Draft                                      |
| **Created**  | 2026-02-25                                 |
| **Authors**  | ITPRO                                      |
| **Platform** | Mobile-first (iOS / Android); web deferred |

---

## Table of Contents

1. [Overview](#1-overview)
2. [Scope & Constraints](#2-scope--constraints)
3. [Architecture](#3-architecture)
4. [Technology Stack](#4-technology-stack)
5. [Adaptive Quality Policy](#5-adaptive-quality-policy)
6. [Call Flow](#6-call-flow)
7. [Capacity Sizing](#7-capacity-sizing)
8. [SLO / SLI](#8-slo--sli)
9. [Failure Modes & Degradation](#9-failure-modes--degradation)
10. [Security](#10-security)
11. [Observability](#11-observability)
12. [Test Plan](#12-test-plan)
13. [Rollout Phases](#13-rollout-phases)
14. [Appendix](#14-appendix)

---

## 1. Overview

Hệ thống voice/video call real-time cho mobile app với 500k MAU. Thiết kế theo hướng **cost/quality balanced** — tối ưu chi phí infrastructure trong khi vẫn giữ chất lượng cuộc gọi tốt cho người dùng.

### Design Principles

- **Hybrid topology**: P2P cho 1:1, SFU cho group — minimize server cost khi có thể.
- **Adaptive bitrate**: tự động điều chỉnh chất lượng theo network condition thực tế.
- **OSS-first**: toàn bộ stack dùng open-source, không phụ thuộc 3rd-party API tính phí per-minute.
- **Mobile-first**: CallKit (iOS) / ConnectionService (Android) integration, xử lý tốt background + handover.

---

## 2. Scope & Constraints

### In Scope (v1)

| Feature              | Detail                                     |
| -------------------- | ------------------------------------------ |
| 1:1 voice/video call | P2P preferred, auto-fallback TURN          |
| Group call           | Max 8 participants, SFU-routed             |
| Active video display | 4 slots (2 HQ + 2 MQ), còn lại LQ/paused   |
| Adaptive quality     | 2-loop ABR (fast bitrate + slow codec)     |
| Transport encryption | DTLS-SRTP for media, TLS 1.3 for signaling |
| Platform             | iOS (Swift) + Android (Kotlin)             |

### Out of Scope (v1)

| Feature              | Reason                                       |
| -------------------- | -------------------------------------------- |
| Web client           | Deferred — mobile-first strategy             |
| Recording / playback | Storage + compliance complexity, defer to v2 |
| App-layer E2EE       | Performance trade-off, DTLS-SRTP đủ cho v1   |
| Screen sharing       | UX complexity, defer to v2                   |
| AI noise suppression | Can add as post-processing layer later       |

### Key Numbers

| Metric         | Value                              |
| -------------- | ---------------------------------- |
| MAU            | 500,000                            |
| Peak CCU       | ~5,000 (1% MAU)                    |
| Call mix       | 98% 1:1 / 2% group                 |
| Max group size | 8 participants                     |
| Target regions | Vietnam (primary), SEA (secondary) |

---

## 3. Architecture

### 3.1 High-Level Topology

```
┌──────────────────────────────────────────────────────────────────┐
│                        CLIENT LAYER                              │
│  ┌──────────┐    ┌──────────┐                                    │
│  │  iOS App  │    │ Android  │    (libwebrtc native)              │
│  │  CallKit  │    │ ConnSvc  │                                    │
│  └─────┬─────┘    └─────┬────┘                                   │
│        │                │                                        │
│        └───────┬────────┘                                        │
│                │ WSS (signaling) + HTTPS (API)                   │
└────────────────┼─────────────────────────────────────────────────┘
                 │
┌────────────────┼─────────────────────────────────────────────────┐
│           CONTROL PLANE                                          │
│                │                                                 │
│  ┌─────────────▼──────────────┐                                  │
│  │     API Gateway / LB       │                                  │
│  └──────┬──────────┬──────────┘                                  │
│         │          │                                             │
│  ┌──────▼──────┐  ┌▼───────────────┐  ┌────────────────┐        │
│  │  Signaling  │  │    Session     │  │  Policy Engine │        │
│  │  Server     │  │  Orchestrator  │  │  (ABR rules)   │        │
│  │  (Go+WSS)   │  │    (Go)        │  │    (Go)        │        │
│  └──────┬──────┘  └───────┬────────┘  └───────┬────────┘        │
│         │                 │                    │                 │
│  ┌──────▼─────────────────▼────────────────────▼──────┐          │
│  │              Event Bus (NATS)                      │          │
│  └────────────────────────┬───────────────────────────┘          │
│                           │                                     │
│  ┌────────────┐  ┌────────▼───┐  ┌──────────────┐               │
│  │   Redis    │  │  Postgres  │  │  ClickHouse  │               │
│  │  Cluster   │  │ (metadata) │  │  (QoS/CDR)   │               │
│  │ (session)  │  │            │  │              │               │
│  └────────────┘  └────────────┘  └──────────────┘               │
└──────────────────────────────────────────────────────────────────┘
                 │
┌────────────────┼─────────────────────────────────────────────────┐
│           MEDIA PLANE                                            │
│                │                                                 │
│  ┌─────────────▼──────────────┐                                  │
│  │    LiveKit SFU (OSS)       │  ← group calls                   │
│  │    (simulcast/SVC)         │                                  │
│  └────────────────────────────┘                                  │
│                                                                  │
│  ┌────────────────────────────┐                                  │
│  │    coturn (TURN/STUN)      │  ← 1:1 fallback relay            │
│  │    (per-region deploy)     │                                  │
│  └────────────────────────────┘                                  │
│                                                                  │
│  ┌────────────────────────────┐                                  │
│  │  P2P direct (ICE)         │  ← 1:1 preferred path             │
│  └────────────────────────────┘                                  │
└──────────────────────────────────────────────────────────────────┘
```

### 3.2 Component Responsibilities

| Component                | Responsibility                                                       |
| ------------------------ | -------------------------------------------------------------------- |
| **Signaling Server**     | WebSocket-based SDP/ICE exchange, presence, call state machine       |
| **Session Orchestrator** | Create/join/leave logic, participant management, routing decisions   |
| **Policy Engine**        | ABR rules evaluation, network tier classification, quality decisions |
| **LiveKit SFU**          | Media routing for group calls, simulcast layer selection             |
| **coturn**               | TURN relay for P2P fallback, STUN for NAT traversal                  |
| **Redis Cluster**        | Active session state, participant mapping, ephemeral data            |
| **Postgres**             | User metadata, call history, configuration                           |
| **ClickHouse**           | QoS metrics, CDR (Call Detail Records), analytics                    |
| **NATS**                 | Internal event fanout (call events, quality updates, presence)       |

### 3.3 Call Topology Decision

```
┌─────────────────────────────────────────┐
│          New Call Request                │
│                                         │
│  participants == 2?                     │
│    ├── YES → attempt P2P (ICE)          │
│    │         ├── ICE success → P2P      │
│    │         └── ICE fail/timeout       │
│    │             (800-1200ms) → TURN    │
│    │                                    │
│    └── NO (group) → SFU (LiveKit)       │
└─────────────────────────────────────────┘
```

---

## 4. Technology Stack

### 4.1 Complete Stack

| Layer             | Technology                                 | Version / Notes                          |
| ----------------- | ------------------------------------------ | ---------------------------------------- |
| **Client SDK**    | libwebrtc (native)                         | M120+ branch, per-platform build         |
| **iOS**           | Swift + CallKit                            | iOS 15+                                  |
| **Android**       | Kotlin + ConnectionService                 | API 26+                                  |
| **SFU**           | LiveKit OSS                                | Self-hosted, Go-based                    |
| **TURN/STUN**     | coturn                                     | Per-region deployment                    |
| **Backend**       | Go                                         | 1.22+, signaling + orchestrator + policy |
| **Signaling**     | WebSocket (gorilla/websocket)              | JSON-based protocol                      |
| **State**         | Redis Cluster                              | 7.x, session + presence                  |
| **Database**      | PostgreSQL                                 | 16+, metadata + config                   |
| **Analytics**     | ClickHouse                                 | QoS metrics, CDR                         |
| **Events**        | NATS                                       | JetStream for durability                 |
| **Infra**         | Kubernetes                                 | Multi-AZ, HPA-enabled                    |
| **DNS**           | GeoDNS                                     | Latency-based routing                    |
| **Observability** | OTel + Prometheus + Grafana + Loki + Tempo | Full stack                               |
| **CI/CD**         | GitHub Actions                             | Build + test + deploy                    |

### 4.2 Codec Support

| Type  | Mandatory           | Optional (flag-gated) |
| ----- | ------------------- | --------------------- |
| Audio | Opus (DTX+FEC+PLC)  | —                     |
| Video | VP8, H.264 Baseline | VP9, AV1 (Phase D)    |

### 4.3 Why This Stack

| Decision                    | Rationale                                                             |
| --------------------------- | --------------------------------------------------------------------- |
| LiveKit over mediasoup      | Go-native (matches backend), better K8s integration, active community |
| coturn over cloud TURN      | Cost control — cloud TURN is per-GB, coturn is fixed infra cost       |
| Go for backend              | Low latency, excellent concurrency, matches LiveKit ecosystem         |
| NATS over RabbitMQ          | Lower latency, simpler ops, JetStream covers durability needs         |
| ClickHouse over TimescaleDB | Better compression for high-cardinality QoS metrics                   |
| Redis Cluster over single   | HA required for session state, partition tolerance                    |

---

## 5. Adaptive Quality Policy

### 5.1 Network Tier Classification

Client đo liên tục RTT, packet loss, jitter và phân loại network vào 3 tier:

| Tier     | RTT        | Packet Loss | Jitter   | Trigger                           |
| -------- | ---------- | ----------- | -------- | --------------------------------- |
| **Good** | < 120 ms   | < 2%        | < 20 ms  | Default; upgrade after 10s stable |
| **Fair** | 120–250 ms | 2–6%        | 20–50 ms | Downgrade after 2s sustained      |
| **Poor** | > 250 ms   | > 6%        | > 50 ms  | Downgrade after 1s sustained      |

**Hysteresis rule**: upgrade chỉ xảy ra khi tier mới duy trì ổn định **10 giây liên tục** — tránh oscillation.

### 5.2 Audio Policy

Opus là codec duy nhất, luôn bật. Audio được ưu tiên tuyệt đối trước video.

| Parameter     | Good             | Fair              | Poor              |
| ------------- | ---------------- | ----------------- | ----------------- |
| Bitrate       | 24–32 kbps       | 16–24 kbps        | 12–16 kbps        |
| DTX           | ON               | ON                | ON                |
| FEC (in-band) | OFF              | ON                | ON                |
| PLC           | ON               | ON                | ON                |
| Packet time   | 20 ms            | 20 ms             | 40 ms             |
| Jitter buffer | Adaptive 20-80ms | Adaptive 40-120ms | Adaptive 60-200ms |

### 5.3 Video Policy

| Parameter         | Good              | Fair         | Poor         |
| ----------------- | ----------------- | ------------ | ------------ |
| Resolution        | 720p (1280×720)   | 360–480p     | 180–360p     |
| Framerate         | 30 fps            | 15–20 fps    | 12–15 fps    |
| Bitrate           | 1.2–2.0 Mbps      | 400–900 kbps | 150–350 kbps |
| Keyframe interval | 2s                | 3s           | 4s           |
| B-frames          | OFF (low latency) | OFF          | OFF          |

### 5.4 Group Call Video Slots

Khi group call, max 8 participants nhưng chỉ hiển thị 4 video slots đồng thời:

| Slot     | Quality         | Resolution           | Bitrate          |
| -------- | --------------- | -------------------- | ---------------- |
| Slot 1–2 | **High (HQ)**   | 720p/30fps           | 1.2–2.0 Mbps     |
| Slot 3–4 | **Medium (MQ)** | 360p/20fps           | 400–600 kbps     |
| Slot 5–8 | **Low/Paused**  | 180p/10fps or paused | 50–150 kbps or 0 |

**Slot assignment logic**:

- Active speaker → HQ slot (voice activity detection)
- Last 2 recent speakers → MQ slots
- Pinned participant → HQ slot (user override)
- Remaining → LQ thumbnails hoặc avatar-only

### 5.5 Two-Loop Adaptation

```
┌──────────────────────────────────────────────────┐
│  FAST LOOP (500ms – 1s cycle)                    │
│                                                  │
│  Inputs:  RTCP feedback, TWCC, bandwidth est.    │
│  Actions: bitrate adjustment                     │
│           simulcast layer switch (SFU)            │
│           framerate reduction                     │
│           resolution downscale                    │
│                                                  │
│  Thresholds:                                     │
│  - Loss > 4% sustained 1s → reduce bitrate 30%  │
│  - RTT spike > 300ms → drop framerate first      │
│  - Available BW < 500kbps → video off suggestion │
│                                                  │
├──────────────────────────────────────────────────┤
│  SLOW LOOP (5–10s cycle)                         │
│                                                  │
│  Inputs:  Aggregated network tier, battery,      │
│           thermal state, sustained quality        │
│  Actions: codec profile change                   │
│           Opus complexity adjustment              │
│           video codec switch (VP8↔H264)           │
│           tier reclassification                   │
│                                                  │
│  Hysteresis:                                     │
│  - Upgrade only after 10s stable in higher tier  │
│  - Downgrade after 2s (Fair) or 1s (Poor)        │
│  - Max 1 codec change per 30s                    │
└──────────────────────────────────────────────────┘
```

### 5.6 Audio Priority Rule

Khi bandwidth cực thấp (< 100 kbps):

1. **Video OFF** — chuyển sang voice-only mode
2. **Audio giữ nguyên** — Opus 12-16 kbps vẫn hoạt động tốt
3. **UI indicator** — hiển thị "Poor connection, video paused"
4. **Auto-recover** — khi bandwidth > 200 kbps stable 10s → bật lại video

---

## 6. Call Flow

### 6.1 1:1 Call — P2P Path (Happy Path)

```
Caller                 Signaling Server              Callee
  │                          │                          │
  ├── WSS: call_initiate ───►│                          │
  │   {callee_id, sdp_offer, │                          │
  │    call_type: video}     │                          │
  │                          ├── Push notification ────►│
  │                          │   (APNS/FCM + VoIP push)│
  │                          │                          │
  │                          │◄── WSS: call_accept ─────┤
  │                          │    {sdp_answer}          │
  │                          │                          │
  │◄── sdp_answer ───────────┤                          │
  │                          │                          │
  │◄────── ICE candidates exchange (trickle) ──────────►│
  │                          │                          │
  │◄═══════════ P2P media stream (DTLS-SRTP) ═════════►│
  │                          │                          │
  │── RTCP/TWCC feedback ──►│◄── RTCP/TWCC feedback ───│
  │  (for quality metrics)   │                          │
  │                          │                          │
  ├── WSS: call_end ────────►│                          │
  │                          ├── call_ended ───────────►│
  │                          │                          │
```

### 6.2 1:1 Call — TURN Fallback

```
Caller                 Signaling         coturn              Callee
  │                      │                  │                  │
  │  ICE P2P failed      │                  │                  │
  │  (timeout 800ms)     │                  │                  │
  │                      │                  │                  │
  ├── TURN allocate ─────┼────────────────►│                  │
  │◄── relay candidate ──┼─────────────────┤                  │
  │                      │                  │                  │
  │                      ├── relay candidate ────────────────►│
  │                      │                  │                  │
  │◄══════ Media via TURN relay (DTLS-SRTP) ═════════════════►│
  │                      │                  │                  │
```

### 6.3 Group Call — SFU Path

```
Participant A      Signaling/Orchestrator      LiveKit SFU       Participant B,C,D
     │                      │                      │                    │
     ├── create_room ──────►│                      │                    │
     │                      ├── provision_room ───►│                    │
     │                      │◄── room_token ───────┤                    │
     │◄── room_info + token─┤                      │                    │
     │                      │                      │                    │
     │                      │  (invite participants B, C, D)            │
     │                      ├── push notifications ────────────────────►│
     │                      │                      │                    │
     ├── join SFU (token) ──┼─────────────────────►│                    │
     │                      │                      │◄── join (token) ───┤
     │                      │                      │                    │
     │══ publish tracks ═══►│                      │                    │
     │  (simulcast: hi/mid/low)                    │                    │
     │                      │                      │═══ subscribe ═════►│
     │                      │                      │  (layer selection  │
     │                      │                      │   per subscriber)  │
     │                      │                      │                    │
     │  ◄════════ selective forwarding ════════════►│                    │
     │     (SFU chọn layer phù hợp per subscriber) │                    │
     │                      │                      │                    │
```

### 6.4 Call State Machine

```
                    ┌──────────┐
                    │   IDLE   │
                    └────┬─────┘
                         │ initiate
                    ┌────▼─────┐
              ┌─────┤ RINGING  ├─────┐
              │     └────┬─────┘     │
          timeout/       │ accept    │ reject/busy
          cancel         │           │
              │     ┌────▼─────┐     │
              │     │CONNECTING│     │
              │     └────┬─────┘     │
              │          │ media     │
              │          │ flowing   │
              │     ┌────▼─────┐     │
              │     │  ACTIVE  │     │
              │     └────┬─────┘     │
              │          │           │
              │     ┌────▼─────┐     │
              └────►│  ENDED   │◄────┘
                    └────┬─────┘
                         │
                    ┌────▼─────┐
                    │ CLEANUP  │  (release TURN, SFU resources)
                    └──────────┘
```

**Timeouts:**

- RINGING → ENDED: 45 seconds (configurable)
- CONNECTING → ENDED: 15 seconds (ICE timeout)
- ACTIVE: no timeout (user-driven end)
- CLEANUP: 5 seconds max (force release resources)

### 6.5 Reconnection / Handover

Khi mobile switch network (WiFi → 4G, 4G → 5G):

```
Client                  Signaling                  Media Plane
  │                        │                          │
  │  network change        │                          │
  │  detected              │                          │
  │                        │                          │
  ├── ICE restart ────────►│                          │
  │   (new candidates)     │                          │
  │                        ├── forward candidates ───►│
  │                        │                          │
  │◄═══ new media path established ══════════════════►│
  │     (target: < 2s interruption)                   │
  │                        │                          │
```

**ICE restart policy:**

- Triggered automatically on network interface change
- Max 3 restart attempts before call termination
- Backoff: 0s → 1s → 3s between attempts
- During restart: audio continues on old path if possible (seamless for TURN)

### 6.6 Push/Incoming Call Plane

Dù kiến trúc media/control plane tốt đến đâu, incoming call sẽ fail nếu push notification không đánh thức app đúng cách. Section này mô tả end-to-end flow từ push delivery → app wake → native call UI → media connect.

#### 6.6.1 Architecture Overview

```
                    Push Gateway Service
                    ┌──────────────────┐
                    │  Token Registry  │  ← device_token + platform + user_id
                    │  Push Router     │  ← chọn APNs/FCM dựa trên platform
                    │  Delivery Tracker│  ← track push sent/delivered/failed
                    └───────┬──────────┘
                            │
              ┌─────────────┼─────────────┐
              │                           │
     ┌────────▼────────┐        ┌─────────▼────────┐
     │   APNs (VoIP)   │        │  FCM (high-pri)  │
     │   PushKit push  │        │  data message     │
     └────────┬────────┘        └─────────┬────────┘
              │                           │
     ┌────────▼────────┐        ┌─────────▼────────┐
     │   iOS Client    │        │  Android Client  │
     │   PushKit       │        │  FirebaseMsg     │
     │   delegate      │        │  Service         │
     └────────┬────────┘        └─────────┬────────┘
              │                           │
     ┌────────▼────────┐        ┌─────────▼────────┐
     │   CallKit       │        │  ConnectionSvc   │
     │   reportNew     │        │  + ForegroundSvc │
     │   IncomingCall  │        │  + FullScreenUI  │
     └─────────────────┘        └──────────────────┘
```

#### 6.6.2 Push Token Management

```
Client                     Push Gateway                   Database
  │                             │                            │
  │  register_push_token        │                            │
  │  {user_id, device_id,      │                            │
  │   platform: "ios"|"android",│                            │
  │   token: "<apns/fcm_token>",│                            │
  │   voip_token: "<pushkit>",  │  (iOS only)               │
  │   app_version, bundle_id}  │                            │
  │ ──────────────────────────►│                            │
  │                             │  UPSERT push_tokens       │
  │                             │ ──────────────────────────►│
  │                             │                            │
  │  token refresh              │                            │
  │  (APNs/FCM token rotate)   │                            │
  │ ──────────────────────────►│  UPDATE token              │
  │                             │ ──────────────────────────►│
```

**Push Token Table:**

```sql
CREATE TABLE push_tokens (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES users(id),
    device_id   TEXT NOT NULL,
    platform    TEXT NOT NULL CHECK (platform IN ('ios', 'android')),
    push_token  TEXT NOT NULL,           -- APNs device token / FCM registration token
    voip_token  TEXT,                    -- iOS PushKit VoIP token (iOS only)
    app_version TEXT,
    bundle_id   TEXT,
    is_active   BOOLEAN DEFAULT true,
    created_at  TIMESTAMPTZ DEFAULT now(),
    updated_at  TIMESTAMPTZ DEFAULT now(),
    UNIQUE(user_id, device_id)
);

CREATE INDEX idx_push_tokens_user ON push_tokens(user_id) WHERE is_active = true;
```

#### 6.6.3 iOS — PushKit VoIP Push + CallKit

**Critical constraint:** iOS **BẮT BUỘC** phải gọi `provider.reportNewIncomingCall()` ngay trong `pushRegistry(_:didReceiveIncomingPushWith:)` callback. Nếu không gọi → iOS sẽ **kill app** và **revoke PushKit token**.

```
APNs VoIP Push arrives
        │
        ▼
┌──────────────────────────────────────────────┐
│  pushRegistry(_:didReceiveIncomingPushWith:)  │
│                                              │
│  1. Parse push payload                       │
│  2. CXProvider.reportNewIncomingCall()  ◄──── BẮT BUỘC gọi NGAY
│     - uuid: call_id from payload             │  (trước bất kỳ async work nào)
│     - update: CXCallUpdate(remoteHandle...)  │
│  3. Start WebSocket connection (background)  │
│  4. Begin SDP exchange                       │
└──────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────┐
│  CallKit Native UI shown │  (hệ thống hiện incoming call UI)
│  ┌────────────────────┐  │
│  │  [Decline] [Accept]│  │
│  └────────────────────┘  │
└──────────┬───────────────┘
           │
    ┌──────┴──────┐
    │             │
 Accept        Decline
    │             │
    ▼             ▼
 provider       provider
 (_:perform     (_:perform
  answer)        end)
    │             │
    ▼             │
 Connect WSS     └──► send DECLINE
 SDP/ICE              to signaling
 Media flow
```

**Push payload (APNs VoIP):**

```json
{
  "call_id": "uuid",
  "caller_id": "uuid",
  "caller_name": "Nguyễn Văn A",
  "caller_avatar_url": "https://...",
  "call_type": "audio|video",
  "room_id": "optional-for-group",
  "timestamp": 1708876543,
  "ttl": 45
}
```

**APNs configuration:**

| Field       | Value                                       |
| ----------- | ------------------------------------------- |
| Push type   | `voip` (PushKit)                            |
| Topic       | `{bundle_id}.voip`                          |
| Priority    | `10` (immediate)                            |
| Expiration  | `0` (don't store if device offline quá lâu) |
| Collapse ID | `call_{call_id}` (dedup nếu push retry)     |

#### 6.6.4 Android — FCM Data Message + Full-Screen Intent

**Critical constraint:** PHẢI dùng FCM **data message** (không phải notification message). Notification message bị hệ thống handle trước khi app nhận → không thể show custom incoming call UI khi app background/killed.

```
FCM data message arrives (high priority)
        │
        ▼
┌──────────────────────────────────────────────────┐
│  FirebaseMessagingService.onMessageReceived()     │
│                                                  │
│  1. Parse data payload                           │
│  2. Start Foreground Service (TYPE_PHONE_CALL)   │
│     - Android 12+: TYPE_PHONE_CALL               │
│     - Android < 12: TYPE_DEFAULT                 │
│  3. Show Full-Screen Intent notification         │
│     - USE_FULL_SCREEN_INTENT permission          │
│     - fullScreenIntent → IncomingCallActivity    │
│  4. ConnectionService.addNewIncomingCall()        │
│  5. Start WebSocket connection                   │
└──────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────┐
│  IncomingCallActivity (full-screen)      │
│  ┌───────────────────────────────────┐  │
│  │  Caller: Nguyễn Văn A            │  │
│  │  [Decline]           [Accept]    │  │
│  └───────────────────────────────────┘  │
└──────────┬──────────────────────────────┘
           │
    ┌──────┴──────┐
    │             │
 Accept        Decline
    │             │
    ▼             ▼
 onAnswer()    onReject()
 Connect WSS   send DECLINE
 SDP/ICE       stop service
 Media flow
```

**FCM message format:**

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
    "caller_avatar_url": "https://...",
    "call_type": "audio|video",
    "timestamp": "1708876543"
  }
}
```

> **Không dùng `notification` field** — chỉ dùng `data` field để đảm bảo `onMessageReceived()` luôn được gọi khi app background/killed.

**Android permissions required:**

```xml
<uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_PHONE_CALL" />
<uses-permission android:name="android.permission.MANAGE_OWN_CALLS" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />  <!-- Android 13+ -->
```

#### 6.6.5 Client-Side Call State Machine

Server-side state machine (§6.4) track trạng thái call. Client cần state machine riêng cho push → ring → connect flow:

```
                  ┌──────────┐
                  │   IDLE   │
                  └─┬──────┬─┘
         outgoing   │      │  push/WSS
         call       │      │  incoming
              ┌─────▼──┐ ┌─▼──────┐
              │CALLING │ │INCOMING│   ← native UI shown
              └───┬────┘ └─┬──┬───┘
                  │   accept│  │decline/timeout
                  │        │  │
              ┌───▼────────▼┐ │
              │ CONNECTING  │ │   ← SDP/ICE exchange
              └──────┬──────┘ │
                     │ media  │
                     │ ready  │
              ┌──────▼──────┐ │
              │   ACTIVE    │ │   ← audio/video flowing
              └──────┬──────┘ │
                     │        │
              ┌──────▼────────▼┐
              │     ENDED      │   ← cleanup resources
              └────────────────┘
```

**State transitions & actions:**

| From       | Event            | To         | Action                                          |
| ---------- | ---------------- | ---------- | ----------------------------------------------- |
| IDLE       | user_initiate    | CALLING    | Send `call_initiate` via WSS                    |
| IDLE       | push_received    | INCOMING   | Show native call UI (CallKit/ConnectionService) |
| IDLE       | wss_incoming     | INCOMING   | Show native call UI (dedup với push)            |
| INCOMING   | user_accept      | CONNECTING | Send `call_accept`, start SDP/ICE               |
| INCOMING   | user_decline     | ENDED      | Send `call_decline`, dismiss UI                 |
| INCOMING   | timeout (45s)    | ENDED      | Send `call_timeout`, dismiss UI                 |
| CALLING    | callee_accept    | CONNECTING | Start SDP/ICE exchange                          |
| CALLING    | callee_decline   | ENDED      | Show "declined" UI                              |
| CALLING    | user_cancel      | ENDED      | Send `call_cancel`                              |
| CALLING    | timeout (45s)    | ENDED      | Show "no answer" UI                             |
| CONNECTING | media_flowing    | ACTIVE     | Show in-call UI                                 |
| CONNECTING | ice_timeout(15s) | ENDED      | Show "connection failed" UI                     |
| ACTIVE     | user_hangup      | ENDED      | Send `call_end`, stop media                     |
| ACTIVE     | remote_hangup    | ENDED      | Show "call ended" UI, stop media                |
| ENDED      | cleanup_done     | IDLE       | Release all resources                           |

#### 6.6.6 Race Conditions & Deduplication

| Scenario                                    | Giải pháp                                                                                 |
| ------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Push arrives + WSS `incoming_call` cùng lúc | Client check `call_id`: nếu đã có → ignore duplicate                                      |
| Push arrives nhưng WSS đã connected         | Ưu tiên WSS event (lower latency). Push → check state → nếu đã INCOMING → skip            |
| Push arrives sau khi caller cancel          | Push payload có `ttl` + `timestamp`. Client check call validity via WSS trước khi show UI |
| Multiple devices cùng user nhận push        | First device accept → server broadcast `call_accepted` → other devices dismiss            |
| CallKit report trước khi có call info       | Dùng placeholder data, update via `CXCallUpdate` khi WSS connected                        |

#### 6.6.7 Push Delivery Reliability

```
Signaling Server          Push Gateway              APNs/FCM
       │                       │                       │
       │  send_push(call_id,   │                       │
       │    user_id, payload)  │                       │
       │ ─────────────────────►│                       │
       │                       │  lookup active tokens │
       │                       │  (multi-device)       │
       │                       │                       │
       │                       │  send to ALL devices  │
       │                       │ ─────────────────────►│
       │                       │                       │
       │                       │  delivery receipt     │
       │                       │ ◄─────────────────────│
       │                       │                       │
       │  push_status          │                       │
       │  {sent/delivered/     │                       │
       │   failed per device}  │                       │
       │ ◄─────────────────────│                       │
       │                       │                       │
       │  (if all failed)      │                       │
       │  → callee unreachable │                       │
       │  → notify caller      │                       │
```

**Retry policy:**

- APNs: no retry (VoIP push là best-effort, iOS xử lý delivery)
- FCM: 1 retry sau 2s nếu failed, max 2 attempts
- Nếu tất cả devices fail → notify caller "Không thể liên lạc"
- Push TTL = ring timeout (45s) — không store push quá thời gian ring

**Token invalidation:**

- APNs trả `410 Gone` → mark token inactive, yêu cầu client re-register
- FCM trả `UNREGISTERED` → mark token inactive
- Scheduled cleanup: tokens không update > 30 ngày → soft delete

---

## 7. Capacity Sizing

### 7.1 Concurrent Load

| Metric                 | Value  | Calculation        |
| ---------------------- | ------ | ------------------ |
| Peak CCU               | ~5,000 | 1% of 500k MAU     |
| Concurrent 1:1 calls   | ~2,450 | 98% × 5,000 ÷ 2    |
| — via P2P              | ~1,470 | 60% of 1:1         |
| — via TURN             | ~980   | 40% of 1:1         |
| Concurrent group rooms | ~16-17 | 2% × 5,000 ÷ 6 avg |
| Total SFU participants | ~100   | 16.7 rooms × 6 avg |

### 7.2 Bandwidth Estimation

| Path                    | Per-call BW (avg)       | Concurrent | Total BW      |
| ----------------------- | ----------------------- | ---------- | ------------- |
| P2P                     | 0 (server)              | 1,470      | 0 (direct)    |
| TURN relay              | ~2 Mbps (bidirectional) | 980        | ~2 Gbps       |
| SFU (group)             | ~4 Mbps per room        | 17         | ~68 Mbps      |
| Signaling               | ~5 kbps per user        | 5,000      | ~25 Mbps      |
| **Total server egress** |                         |            | **~2.1 Gbps** |

### 7.3 Infrastructure Sizing (Starting Point)

| Component                | Spec                        | Count | Notes                        |
| ------------------------ | --------------------------- | ----- | ---------------------------- |
| **Signaling Server**     | 4 vCPU, 8GB RAM             | 3     | Behind LB, stateless         |
| **Session Orchestrator** | 4 vCPU, 8GB RAM             | 2     | Active-active                |
| **Policy Engine**        | 2 vCPU, 4GB RAM             | 2     | Low compute, high throughput |
| **LiveKit SFU**          | 8 vCPU, 16GB RAM            | 2-3   | ~50 rooms/node capacity      |
| **coturn**               | 8 vCPU, 8GB RAM, 10Gbps NIC | 4-6   | Main bandwidth consumer      |
| **Redis Cluster**        | 4 vCPU, 16GB RAM            | 6     | 3 masters + 3 replicas       |
| **Postgres**             | 4 vCPU, 16GB RAM, SSD       | 2     | Primary + hot standby        |
| **ClickHouse**           | 8 vCPU, 32GB RAM, NVMe      | 2     | Can grow independently       |
| **NATS**                 | 2 vCPU, 4GB RAM             | 3     | JetStream cluster            |

### 7.4 Cost Estimate (Monthly, Cloud Pricing)

| Category       | Est. Monthly Cost   | Notes                            |
| -------------- | ------------------- | -------------------------------- |
| Compute        | $2,000 – $3,500     | All K8s nodes combined           |
| Bandwidth      | $1,500 – $3,000     | Main cost — TURN egress dominant |
| Storage (DB)   | $200 – $500         | Postgres + ClickHouse + Redis    |
| Misc (DNS, LB) | $100 – $300         | GeoDNS, load balancers           |
| **Total**      | **$3,800 – $7,300** | At 5,000 CCU peak                |

> **Cost optimization note**: P2P ratio tăng = bandwidth cost giảm. Mỗi 10% tăng P2P success rate ~ 5-8% giảm TURN bandwidth cost.

---

## 8. SLO / SLI

### 8.1 Service Level Objectives

| SLO                          | Target      | Measurement                                 |
| ---------------------------- | ----------- | ------------------------------------------- |
| Call setup success (1:1)     | ≥ 99.7%     | `successful_connects / total_attempts`      |
| Call setup success (group)   | ≥ 99.3%     | `successful_joins / total_join_attempts`    |
| P95 setup latency (intra)    | < 2 seconds | Time from initiate → media flowing          |
| P95 one-way audio latency    | < 150 ms    | Measured via RTP timestamps                 |
| Audio jitter (P95)           | < 30 ms     | RTCP jitter reports                         |
| Reconnect success (handover) | ≥ 98%       | `successful_reconnects / total_disconnects` |
| Control plane availability   | 99.95%      | Signaling server uptime                     |
| Video quality (MOS estimate) | ≥ 3.5 / 5.0 | Calculated from bitrate, loss, resolution   |

### 8.2 Service Level Indicators

| SLI                  | Source               | Collection Interval |
| -------------------- | -------------------- | ------------------- |
| ICE connection time  | Client SDK metrics   | Per-call            |
| TURN allocation time | coturn logs          | Per-allocation      |
| SFU join latency     | LiveKit metrics      | Per-join            |
| Audio RTT            | RTCP reports         | 5 seconds           |
| Packet loss rate     | RTCP/TWCC            | 1 second            |
| Available bandwidth  | TWCC estimation      | 1 second            |
| Bitrate (send/recv)  | RTP stats            | 1 second            |
| Frame drop rate      | Client SDK           | 5 seconds           |
| Network tier         | Policy engine        | Per-evaluation      |
| Call duration        | Session orchestrator | Per-call            |

### 8.3 Alerting

| Alert                    | Condition                 | Severity | Action                       |
| ------------------------ | ------------------------- | -------- | ---------------------------- |
| Setup success < 99%      | 5-min rolling window      | P1       | On-call page                 |
| P95 latency > 3s         | 5-min rolling window      | P2       | On-call notification         |
| TURN node unhealthy      | Health check fail × 3     | P1       | Auto-remove from pool + page |
| SFU overload (CPU > 85%) | 2-min sustained           | P2       | HPA scale-up + notification  |
| Redis cluster degraded   | Node unreachable          | P1       | Auto-failover + page         |
| Packet loss > 10% avg    | 1-min rolling, per-region | P2       | Investigate network path     |

---

## 9. Failure Modes & Degradation

### 9.1 Degradation Cascade

```
Network degrades
  │
  ├── Fast loop triggers (< 1s)
  │   ├── Reduce bitrate
  │   ├── Drop simulcast layer
  │   └── Reduce framerate
  │
  ├── Slow loop triggers (5-10s)
  │   ├── Switch codec profile
  │   ├── Reduce resolution
  │   └── Reclassify network tier
  │
  ├── Critical threshold (BW < 100kbps)
  │   ├── VIDEO OFF (audio-only mode)
  │   └── UI: "Poor connection"
  │
  └── Unrecoverable (BW < 20kbps or loss > 30%)
      ├── Call quality warning
      └── Auto-terminate after 30s
```

### 9.2 Component Failure Handling

| Failure                    | Detection              | Response                                           | Recovery Time |
| -------------------------- | ---------------------- | -------------------------------------------------- | ------------- |
| **P2P ICE fail**           | ICE timeout            | Auto-fallback to TURN                              | 800–1200 ms   |
| **TURN node crash**        | Health check           | Route to next TURN; ICE restart                    | 2–5 s         |
| **SFU overload**           | CPU/connection metrics | Admission control; new rooms to other nodes        | Immediate     |
| **SFU node crash**         | Health check           | Reconnect participants to other node               | 3–8 s         |
| **Signaling server crash** | LB health check        | Route to healthy instance                          | < 1 s         |
| **Redis master fail**      | Sentinel/Cluster       | Auto-failover to replica                           | 1–3 s         |
| **Postgres primary fail**  | Streaming replication  | Promote standby                                    | 5–15 s        |
| **Region failure**         | GeoDNS monitoring      | Route to neighbor region                           | 30–60 s       |
| **Full NATS cluster fail** | Health checks          | Control plane degraded; calls in progress continue | Varies        |

### 9.3 Graceful Degradation Rules

1. **Audio > Video**: Luôn ưu tiên audio. Video bị cut trước audio.
2. **Active calls > New calls**: Khi overload, reject new calls trước khi degrade active calls.
3. **1:1 > Group**: Group calls bị admission-controlled trước 1:1.
4. **Resolution > Framerate > Bitrate**: Giảm theo thứ tự impact thấp nhất cho perceived quality.

---

## 10. Security

### 10.1 Transport Security

| Layer     | Protocol        | Notes                                 |
| --------- | --------------- | ------------------------------------- |
| Media     | DTLS-SRTP       | Mandatory for all WebRTC media        |
| Signaling | WSS (TLS 1.3)   | Certificate pinning on mobile clients |
| API       | HTTPS (TLS 1.3) | HSTS enabled                          |
| Internal  | mTLS            | Service-to-service communication      |

### 10.2 Authentication & Authorization

| Mechanism         | Usage                                         |
| ----------------- | --------------------------------------------- |
| JWT (short-lived) | API + signaling authentication, 15-min expiry |
| Refresh token     | Token renewal, 7-day expiry, rotation on use  |
| Room token        | SFU access, per-session, includes permissions |
| TURN credentials  | Time-limited, per-session, HMAC-based         |

### 10.3 Access Control

```
Call Permissions Matrix:
┌─────────────┬──────────┬──────────┬─────────────┐
│ Action      │ Caller   │ Callee   │ Participant │
├─────────────┼──────────┼──────────┼─────────────┤
│ Initiate    │ ✓        │ ✗        │ ✗           │
│ Accept      │ ✗        │ ✓        │ ✗           │
│ Reject      │ ✗        │ ✓        │ ✗           │
│ End call    │ ✓        │ ✓        │ ✓ (self)    │
│ Mute self   │ ✓        │ ✓        │ ✓           │
│ Mute other  │ ✗        │ ✗        │ ✗ (v1)      │
│ Add member  │ ✓ (host) │ ✗        │ ✗           │
│ Pin video   │ ✓        │ ✓        │ ✓           │
└─────────────┴──────────┴──────────┴─────────────┘
```

### 10.4 Rate Limiting

| Endpoint               | Limit                     | Window   |
| ---------------------- | ------------------------- | -------- |
| Call initiate          | 10 calls / user           | 1 minute |
| Call initiate (global) | 500 CPS                   | 1 second |
| Signaling messages     | 100 messages / connection | 1 minute |
| TURN allocation        | 5 allocations / user      | 1 minute |
| API requests           | 60 requests / user        | 1 minute |

---

## 11. Observability

### 11.1 Stack

```
┌─────────────┐    ┌──────────────┐    ┌──────────────┐
│   OTel SDK  │───►│  OTel        │───►│  Backends    │
│   (all svcs)│    │  Collector   │    │              │
└─────────────┘    └──────┬───────┘    │ ┌──────────┐ │
                          │            │ │Prometheus│ │ ← metrics
                          │            │ └──────────┘ │
                          │            │ ┌──────────┐ │
                          ├───────────►│ │   Loki   │ │ ← logs
                          │            │ └──────────┘ │
                          │            │ ┌──────────┐ │
                          └───────────►│ │  Tempo   │ │ ← traces
                                       │ └──────────┘ │
                                       │ ┌──────────┐ │
                                       │ │ Grafana  │ │ ← dashboards
                                       │ └──────────┘ │
                                       └──────────────┘
```

### 11.2 Key Dashboards

| Dashboard          | Metrics                                                |
| ------------------ | ------------------------------------------------------ |
| **Call Health**    | Setup rate, success rate, duration distribution        |
| **Quality (QoE)**  | MOS score, bitrate, resolution, packet loss by region  |
| **Infrastructure** | CPU, memory, network I/O per component                 |
| **TURN**           | Active allocations, bandwidth, allocation success rate |
| **SFU**            | Active rooms, participants, CPU per node               |
| **Network Tiers**  | Distribution of Good/Fair/Poor per region              |
| **Error Budget**   | SLO burn rate, remaining error budget                  |

### 11.3 Distributed Tracing

Mỗi cuộc gọi tạo 1 trace xuyên suốt:

```
call_trace
├── signaling.initiate     (caller → signaling server)
├── signaling.route        (orchestrator → decide P2P/TURN/SFU)
├── notification.send      (push to callee via APNS/FCM)
├── signaling.accept       (callee → signaling server)
├── ice.negotiation        (ICE candidate exchange)
│   ├── ice.p2p_attempt    (direct connection try)
│   └── ice.turn_fallback  (if P2P fails)
├── media.connected        (DTLS handshake complete)
├── quality.tier_changes   (ABR tier transitions)
└── call.ended             (cleanup + CDR write)
```

### 11.4 CDR (Call Detail Record)

Mỗi cuộc gọi kết thúc sẽ ghi 1 CDR vào ClickHouse:

```json
{
  "call_id": "uuid",
  "type": "1:1 | group",
  "initiator_id": "user_uuid",
  "participants": ["user_uuid_1", "user_uuid_2"],
  "started_at": "2026-02-25T10:00:00Z",
  "ended_at": "2026-02-25T10:05:30Z",
  "duration_seconds": 330,
  "setup_latency_ms": 1200,
  "topology": "p2p | turn | sfu",
  "region": "ap-southeast-1",
  "quality_summary": {
    "avg_mos": 4.1,
    "avg_packet_loss": 0.8,
    "avg_rtt_ms": 85,
    "avg_bitrate_kbps": 1500,
    "tier_distribution": { "good": 0.85, "fair": 0.12, "poor": 0.03 },
    "video_off_seconds": 0,
    "reconnect_count": 0
  },
  "end_reason": "user_hangup | timeout | error | network_loss"
}
```

---

## 12. Test Plan

### 12.1 Network Chaos Matrix

Test dưới các condition kết hợp:

| Scenario            | RTT      | Loss | Jitter | Expected Behavior                     |
| ------------------- | -------- | ---- | ------ | ------------------------------------- |
| Perfect             | 20 ms    | 0%   | 2 ms   | 720p/30fps, full quality              |
| Good                | 80 ms    | 1%   | 10 ms  | 720p/30fps, slight bitrate adapt      |
| Fair (urban 4G)     | 150 ms   | 3%   | 30 ms  | 480p/20fps, FEC enabled               |
| Poor (rural 3G)     | 300 ms   | 8%   | 60 ms  | 180-360p/15fps, audio priority        |
| Extreme (edge case) | 500 ms   | 15%  | 100 ms | Audio-only, video paused              |
| Asymmetric          | 50/200ms | 0/5% | 5/40ms | Sender adapts to receiver constraints |

**Tool**: `tc` (traffic control) hoặc network emulator on device.

### 12.2 Mobile-Specific Tests

| Test Case                | Steps                                  | Expected                             |
| ------------------------ | -------------------------------------- | ------------------------------------ |
| WiFi → 4G handover       | Disable WiFi during call               | ICE restart, < 2s interruption       |
| 4G → WiFi handover       | Connect WiFi during call               | Seamless switch, quality upgrade     |
| Background → Foreground  | Press home during call                 | Audio continues (CallKit/ConnSvc)    |
| Push notification wakeup | Call when app killed                   | VoIP push wakes app, ring UI shows   |
| Low battery mode         | Enable low power mode during call      | Reduce video quality, maintain audio |
| Thermal throttle         | Sustained call > 10 min on weak device | Graceful quality reduction           |
| Airplane mode toggle     | Toggle airplane mode briefly           | Reconnect attempt, eventual recovery |
| Dual SIM                 | Call on SIM1, data on SIM2             | Correct interface selection          |

### 12.3 Load Testing

| Test            | Target                                    | Duration  | Tool              |
| --------------- | ----------------------------------------- | --------- | ----------------- |
| Steady state    | 5,000 CCU, normal call mix                | 1 hour    | Custom WebRTC bot |
| Burst CPS       | 200 calls/second spike for 60s            | 5 minutes | Load generator    |
| Soak test       | 3,000 CCU sustained                       | 24 hours  | WebRTC bot farm   |
| TURN saturation | Fill TURN bandwidth to 90%                | 30 min    | Synthetic media   |
| SFU stress      | 50 concurrent group rooms, 8 ppl each     | 1 hour    | Bot participants  |
| Signaling flood | 10,000 WSS connections, high message rate | 30 min    | WebSocket client  |

### 12.4 Resilience / Game Day

| Scenario               | Action                                 | Expected                                            |
| ---------------------- | -------------------------------------- | --------------------------------------------------- |
| Kill SFU pod           | `kubectl delete pod livekit-0`         | Rooms rebalance, < 5s recovery                      |
| TURN node outage       | Stop coturn on 1 node                  | Active calls ICE restart, new calls route elsewhere |
| Redis master fail      | Kill Redis master                      | Sentinel promotes replica, < 3s                     |
| Signaling full restart | Rolling restart all signaling pods     | Active WSS reconnect, no call drop                  |
| DNS failover           | Remove region from GeoDNS              | Traffic routes to next region                       |
| Network partition      | Isolate control plane from media plane | Active calls continue, new calls fail               |

---

## 13. Rollout Phases

### Phase A — MVP (8–12 weeks)

| Deliverable               | Detail                                       |
| ------------------------- | -------------------------------------------- |
| 1:1 voice call            | P2P + TURN fallback, Opus audio              |
| 1:1 video call            | VP8/H264, basic ABR (fast loop only)         |
| Signaling server          | Call state machine, SDP/ICE exchange         |
| coturn deployment         | Single-region, 2-3 nodes                     |
| Basic SFU                 | LiveKit, 2-3 person test                     |
| iOS CallKit integration   | VoIP push, incoming call UI                  |
| Android ConnectionService | Foreground service, incoming call            |
| Basic quality metrics     | Client-side collection, ClickHouse ingestion |

**Exit Criteria**: 1:1 calls work reliably with < 2s setup, audio quality good on 4G.

### Phase B — Group & Quality (6–8 weeks)

| Deliverable                | Detail                                        |
| -------------------------- | --------------------------------------------- |
| Group call (3-8 ppl)       | Full SFU integration, room management         |
| Simulcast / SVC            | Multi-layer publish, per-subscriber selection |
| Two-loop ABR               | Fast + slow loop, network tier classification |
| Video slot management      | 4 active slots, speaker-based assignment      |
| Reconnection / ICE restart | Automatic on network change                   |
| Full signaling protocol    | All call states, edge cases, timeouts         |

**Exit Criteria**: Group calls stable with 8 participants, ABR adapts correctly across tiers.

### Phase C — Scale & Resilience (6–8 weeks)

| Deliverable             | Detail                                      |
| ----------------------- | ------------------------------------------- |
| Multi-region deployment | 2 regions, GeoDNS routing                   |
| Load testing            | 5k CCU target, soak test 24h                |
| Chaos engineering       | Game day scenarios, failure recovery        |
| Auto-scaling (HPA)      | SFU + TURN + signaling                      |
| Cost optimization       | P2P ratio tuning, TURN bandwidth management |
| Full observability      | All dashboards, alerting, error budgets     |

**Exit Criteria**: System handles 5k CCU, all SLOs met, recovery from single-node failures automatic.

### Phase D — Advanced (Ongoing)

| Deliverable                | Detail                                        |
| -------------------------- | --------------------------------------------- |
| VP9 / AV1 codec rollout    | Flag-gated, per-device capability             |
| ML-based QoE tuning        | Predict quality degradation before it happens |
| Advanced noise suppression | RNNoise or similar, client-side               |
| Screen sharing             | Content-type optimization                     |
| E2EE (optional)            | Insertable Streams API                        |

---

## 14. Appendix

### A. Glossary

| Term      | Definition                                                  |
| --------- | ----------------------------------------------------------- |
| ABR       | Adaptive Bitrate — dynamic quality adjustment               |
| CCU       | Concurrent Users                                            |
| CDR       | Call Detail Record                                          |
| CPS       | Calls Per Second                                            |
| DTLS-SRTP | Datagram TLS + Secure RTP — encrypted media transport       |
| DTX       | Discontinuous Transmission — silence suppression            |
| FEC       | Forward Error Correction — redundant audio packets          |
| ICE       | Interactive Connectivity Establishment — NAT traversal      |
| MOS       | Mean Opinion Score — perceived quality metric (1-5)         |
| mTLS      | Mutual TLS — bidirectional certificate verification         |
| PLC       | Packet Loss Concealment — audio gap filling                 |
| P2P       | Peer-to-Peer — direct client connection                     |
| SDP       | Session Description Protocol — media capability negotiation |
| SFU       | Selective Forwarding Unit — media routing server            |
| SVC       | Scalable Video Coding — layered video encoding              |
| TURN      | Traversal Using Relays around NAT — relay server            |
| TWCC      | Transport-Wide Congestion Control — bandwidth estimation    |

### B. Reference Architecture Comparisons

| Feature           | Our Design      | WhatsApp-like  | Discord-like      |
| ----------------- | --------------- | -------------- | ----------------- |
| 1:1 topology      | P2P + TURN      | P2P + TURN     | Always relay      |
| Group topology    | SFU             | SFU            | SFU               |
| E2EE              | Transport (v1)  | App-layer E2EE | None              |
| Max group         | 8               | 32             | Unlimited (stage) |
| Recording         | No (v1)         | No             | Yes               |
| Audio codec       | Opus            | Opus           | Opus              |
| Video codec       | VP8/H264        | VP8/H264       | H264/VP8          |
| Server cost model | OSS self-hosted | Custom infra   | Mixed             |

### C. Configuration Defaults

```yaml
# call-config.yaml
call:
  ring_timeout_seconds: 45
  ice_timeout_seconds: 15
  cleanup_timeout_seconds: 5
  max_reconnect_attempts: 3
  reconnect_backoff: [0, 1000, 3000] # ms

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

group:
  max_participants: 8
  active_video_slots: 4
  hq_slots: 2
  mq_slots: 2
  speaker_detection_threshold_db: -40
  speaker_hold_seconds: 3

turn:
  allocation_ttl_seconds: 600
  max_allocations_per_user: 5
  credential_ttl_seconds: 86400

rate_limits:
  call_initiate_per_user: 10/min
  call_initiate_global_cps: 500
  signaling_messages_per_connection: 100/min
  turn_allocations_per_user: 5/min
  api_requests_per_user: 60/min
```

---

_Document version: 1.0 | Last updated: 2026-02-25_
