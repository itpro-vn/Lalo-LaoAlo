-- ClickHouse CDR (Call Detail Records)
-- High-level aggregated data per call

CREATE TABLE IF NOT EXISTS cdr (
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
CREATE TABLE IF NOT EXISTS qos_metrics (
    call_id UUID,
    participant_id UUID,
    ts DateTime64(3),
    direction LowCardinality(String),   -- 'send' | 'recv'
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
