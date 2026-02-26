package metrics

import (
	"testing"
	"time"

	"github.com/minhgv/lalo/internal/events"
)

func TestDefaultWriterConfig(t *testing.T) {
	cfg := DefaultWriterConfig()
	if cfg.BatchSize != 100 {
		t.Errorf("expected batch_size=100, got %d", cfg.BatchSize)
	}
	if cfg.FlushInterval != 5*time.Second {
		t.Errorf("expected flush_interval=5s, got %s", cfg.FlushInterval)
	}
}

func TestNewWriter_DefaultsApplied(t *testing.T) {
	w := NewWriter(nil, nil, WriterConfig{})
	if w.batchSize != 100 {
		t.Errorf("expected default batch_size=100, got %d", w.batchSize)
	}
	if w.flushInterval != 5*time.Second {
		t.Errorf("expected default flush_interval=5s, got %s", w.flushInterval)
	}
	w.Stop()
}

func TestWriter_Ingest(t *testing.T) {
	w := NewWriter(nil, nil, WriterConfig{BatchSize: 1000, FlushInterval: time.Hour})
	defer w.Stop()

	now := time.Now().UnixMilli()
	metrics := &events.QualityMetrics{
		CallID: "call-123",
		Samples: []events.QualityMetricsSample{
			{
				ParticipantID: "user-1",
				Timestamp:     now,
				Direction:     "send",
				RTTMs:         50,
				LossPct:       1.5,
				JitterMs:      10.2,
				BitrateKbps:   800,
				Framerate:     30,
				Resolution:    "1280x720",
				NetworkTier:   "good",
			},
			{
				ParticipantID: "user-1",
				Timestamp:     now,
				Direction:     "recv",
				RTTMs:         55,
				LossPct:       2.0,
				JitterMs:      15.0,
				BitrateKbps:   600,
				Framerate:     25,
				Resolution:    "640x480",
				NetworkTier:   "fair",
			},
		},
	}

	w.ingest(metrics)

	if w.BufferLen() != 2 {
		t.Errorf("expected buffer length=2, got %d", w.BufferLen())
	}
}

func TestWriter_IngestZeroTimestamp(t *testing.T) {
	w := NewWriter(nil, nil, WriterConfig{BatchSize: 1000, FlushInterval: time.Hour})
	defer w.Stop()

	metrics := &events.QualityMetrics{
		CallID: "call-456",
		Samples: []events.QualityMetricsSample{
			{
				ParticipantID: "user-2",
				Timestamp:     0, // should default to time.Now()
				Direction:     "send",
				RTTMs:         100,
				LossPct:       3.0,
				JitterMs:      25.0,
				BitrateKbps:   400,
				NetworkTier:   "fair",
			},
		},
	}

	w.ingest(metrics)
	if w.BufferLen() != 1 {
		t.Errorf("expected buffer length=1, got %d", w.BufferLen())
	}
}

func TestWriter_BatchFlush(t *testing.T) {
	// Set batch size to 3 so it auto-flushes
	w := NewWriter(nil, nil, WriterConfig{BatchSize: 3, FlushInterval: time.Hour})
	defer w.Stop()

	now := time.Now().UnixMilli()
	for i := 0; i < 3; i++ {
		w.ingest(&events.QualityMetrics{
			CallID: "call-789",
			Samples: []events.QualityMetricsSample{
				{ParticipantID: "user-3", Timestamp: now, Direction: "send", RTTMs: 50, NetworkTier: "good"},
			},
		})
	}

	// After reaching batch size, buffer should be flushed (reset to 0)
	// Give a moment for async flush
	time.Sleep(50 * time.Millisecond)
	if w.BufferLen() != 0 {
		t.Errorf("expected buffer flushed to 0, got %d", w.BufferLen())
	}
}

func TestDecodePayload(t *testing.T) {
	raw := []byte(`{"id":"test","type":"quality.metrics","timestamp":"2025-01-01T00:00:00Z","source":"signaling","payload":{"call_id":"c1","samples":[{"participant_id":"p1","ts":1234567890,"direction":"send","rtt_ms":50,"loss_pct":1.0,"jitter_ms":10.5,"bitrate_kbps":800,"framerate":30,"resolution":"1280x720","network_tier":"good"}]}}`)

	var m events.QualityMetrics
	err := decodePayload(raw, &m)
	if err != nil {
		t.Fatalf("decode failed: %v", err)
	}

	if m.CallID != "c1" {
		t.Errorf("expected call_id=c1, got %s", m.CallID)
	}
	if len(m.Samples) != 1 {
		t.Fatalf("expected 1 sample, got %d", len(m.Samples))
	}
	s := m.Samples[0]
	if s.ParticipantID != "p1" {
		t.Errorf("expected participant_id=p1, got %s", s.ParticipantID)
	}
	if s.RTTMs != 50 {
		t.Errorf("expected rtt_ms=50, got %d", s.RTTMs)
	}
	if s.JitterMs != 10.5 {
		t.Errorf("expected jitter_ms=10.5, got %f", s.JitterMs)
	}
	if s.Framerate != 30 {
		t.Errorf("expected framerate=30, got %d", s.Framerate)
	}
	if s.NetworkTier != "good" {
		t.Errorf("expected network_tier=good, got %s", s.NetworkTier)
	}
}

func TestMetricsRowFields(t *testing.T) {
	row := metricsRow{
		CallID:        "call-1",
		ParticipantID: "user-1",
		Timestamp:     time.Now(),
		Direction:     "send",
		RTTMs:         100,
		LossPct:       2.5,
		JitterMs:      15.0,
		BitrateKbps:   500,
		Framerate:     24,
		Resolution:    "640x480",
		NetworkTier:   "fair",
	}

	if row.CallID != "call-1" {
		t.Error("unexpected call_id")
	}
	if row.Direction != "send" {
		t.Error("unexpected direction")
	}
	if row.NetworkTier != "fair" {
		t.Error("unexpected network_tier")
	}
}
