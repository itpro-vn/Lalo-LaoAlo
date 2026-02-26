package abr

import (
	"testing"
	"time"
)

func TestEvaluateParticipant_NoSamples(t *testing.T) {
	engine := &PolicyEngine{
		cfg:    DefaultPolicyConfig(),
		metrics: make(map[string]*ParticipantMetrics),
	}

	pm := &ParticipantMetrics{
		Identity: "user1",
		RoomName: "room1",
		Samples:  nil,
	}

	decision := engine.EvaluateParticipant(pm)
	if decision != nil {
		t.Error("expected nil decision for empty samples")
	}
}

func TestEvaluateParticipant_GoodMetrics(t *testing.T) {
	engine := &PolicyEngine{
		cfg:    DefaultPolicyConfig(),
		metrics: make(map[string]*ParticipantMetrics),
	}

	pm := &ParticipantMetrics{
		Identity: "user1",
		RoomName: "room1",
		Samples: []MetricSample{
			{
				Timestamp:     time.Now(),
				RTTMs:         50,
				LossPercent:   1.0,
				JitterMs:      10,
				BandwidthKbps: 2000,
				Tier:          TierGood,
			},
		},
	}

	decision := engine.EvaluateParticipant(pm)
	if decision != nil {
		t.Errorf("expected nil decision for good metrics, got %+v", decision)
	}
}

func TestEvaluateParticipant_HighLoss_CapsFair(t *testing.T) {
	engine := &PolicyEngine{
		cfg:    DefaultPolicyConfig(),
		metrics: make(map[string]*ParticipantMetrics),
	}

	pm := &ParticipantMetrics{
		Identity: "user1",
		RoomName: "room1",
		Samples: []MetricSample{
			{
				Timestamp:     time.Now(),
				RTTMs:         100,
				LossPercent:   10.0, // > 8.0 threshold
				JitterMs:      20,
				BandwidthKbps: 1000,
				Tier:          TierGood,
			},
		},
	}

	decision := engine.EvaluateParticipant(pm)
	if decision == nil {
		t.Fatal("expected non-nil decision for high loss")
	}
	if decision.MaxTier == nil {
		t.Fatal("expected max_tier to be set")
	}
	if *decision.MaxTier != TierFair {
		t.Errorf("expected max_tier=fair, got %s", *decision.MaxTier)
	}
	if decision.Reason == "" {
		t.Error("expected non-empty reason")
	}
}

func TestEvaluateParticipant_VeryHighLoss_CapsPoor(t *testing.T) {
	engine := &PolicyEngine{
		cfg:    DefaultPolicyConfig(),
		metrics: make(map[string]*ParticipantMetrics),
	}

	pm := &ParticipantMetrics{
		Identity: "user1",
		RoomName: "room1",
		Samples: []MetricSample{
			{
				Timestamp:     time.Now(),
				RTTMs:         100,
				LossPercent:   20.0, // > 15.0 threshold
				JitterMs:      20,
				BandwidthKbps: 1000,
				Tier:          TierGood,
			},
		},
	}

	decision := engine.EvaluateParticipant(pm)
	if decision == nil {
		t.Fatal("expected non-nil decision")
	}
	if decision.MaxTier == nil {
		t.Fatal("expected max_tier to be set")
	}
	// Should pick the more restrictive: poor > fair
	if *decision.MaxTier != TierPoor {
		t.Errorf("expected max_tier=poor, got %s", *decision.MaxTier)
	}
}

func TestEvaluateParticipant_HighRTT_CapsFair(t *testing.T) {
	engine := &PolicyEngine{
		cfg:    DefaultPolicyConfig(),
		metrics: make(map[string]*ParticipantMetrics),
	}

	pm := &ParticipantMetrics{
		Identity: "user1",
		RoomName: "room1",
		Samples: []MetricSample{
			{
				Timestamp:     time.Now(),
				RTTMs:         400, // > 300.0 threshold
				LossPercent:   1.0,
				JitterMs:      20,
				BandwidthKbps: 1000,
				Tier:          TierGood,
			},
		},
	}

	decision := engine.EvaluateParticipant(pm)
	if decision == nil {
		t.Fatal("expected non-nil decision for high RTT")
	}
	if decision.MaxTier == nil {
		t.Fatal("expected max_tier to be set")
	}
	if *decision.MaxTier != TierFair {
		t.Errorf("expected max_tier=fair, got %s", *decision.MaxTier)
	}
}

func TestEvaluateParticipant_LowBandwidth_ForceAudioOnly(t *testing.T) {
	engine := &PolicyEngine{
		cfg:    DefaultPolicyConfig(),
		metrics: make(map[string]*ParticipantMetrics),
	}

	pm := &ParticipantMetrics{
		Identity: "user1",
		RoomName: "room1",
		Samples: []MetricSample{
			{
				Timestamp:     time.Now(),
				RTTMs:         50,
				LossPercent:   1.0,
				JitterMs:      10,
				BandwidthKbps: 50, // < 80.0 threshold
				Tier:          TierPoor,
			},
		},
	}

	decision := engine.EvaluateParticipant(pm)
	if decision == nil {
		t.Fatal("expected non-nil decision for low bandwidth")
	}
	if decision.ForceAudioOnly == nil || !*decision.ForceAudioOnly {
		t.Error("expected force_audio_only=true")
	}
}

func TestIngestMetrics_TrimsOldSamples(t *testing.T) {
	engine := &PolicyEngine{
		cfg: PolicyConfig{
			MetricWindowSeconds: 30,
			Rules:               nil,
		},
		metrics: make(map[string]*ParticipantMetrics),
	}

	now := time.Now()
	old := now.Add(-60 * time.Second) // 60s ago, beyond 30s window

	engine.IngestMetrics("room1", "user1", []MetricSample{
		{Timestamp: old, RTTMs: 100, LossPercent: 5},
		{Timestamp: now, RTTMs: 50, LossPercent: 1},
	})

	key := "room1:user1"
	pm := engine.metrics[key]
	if pm == nil {
		t.Fatal("expected metrics entry")
	}
	if len(pm.Samples) != 1 {
		t.Errorf("expected 1 sample after trim, got %d", len(pm.Samples))
	}
	if pm.Samples[0].RTTMs != 50 {
		t.Errorf("expected recent sample with RTT=50, got %f", pm.Samples[0].RTTMs)
	}
}

func TestRemoveParticipant(t *testing.T) {
	engine := &PolicyEngine{
		cfg:    DefaultPolicyConfig(),
		metrics: make(map[string]*ParticipantMetrics),
	}

	engine.IngestMetrics("room1", "user1", []MetricSample{
		{Timestamp: time.Now(), RTTMs: 50},
	})

	key := "room1:user1"
	if _, ok := engine.metrics[key]; !ok {
		t.Fatal("expected metrics entry before removal")
	}

	engine.RemoveParticipant("room1", "user1")

	if _, ok := engine.metrics[key]; ok {
		t.Error("expected metrics entry to be removed")
	}
}

func TestUpdateConfig(t *testing.T) {
	engine := &PolicyEngine{
		cfg:    DefaultPolicyConfig(),
		metrics: make(map[string]*ParticipantMetrics),
	}

	newCfg := PolicyConfig{
		EvalIntervalSeconds: 5,
		MetricWindowSeconds: 15,
		Rules: []PolicyRule{
			{
				Name:        "custom_rule",
				Condition:   "avg_loss_above",
				Threshold:   5.0,
				Action:      "cap_tier",
				ActionValue: "poor",
			},
		},
	}

	engine.UpdateConfig(newCfg)

	if len(engine.cfg.Rules) != 1 {
		t.Errorf("expected 1 rule after update, got %d", len(engine.cfg.Rules))
	}
	if engine.cfg.Rules[0].Name != "custom_rule" {
		t.Errorf("expected custom_rule, got %s", engine.cfg.Rules[0].Name)
	}
}

func TestTierRank(t *testing.T) {
	if tierRank(TierGood) != 0 {
		t.Errorf("expected good=0, got %d", tierRank(TierGood))
	}
	if tierRank(TierFair) != 1 {
		t.Errorf("expected fair=1, got %d", tierRank(TierFair))
	}
	if tierRank(TierPoor) != 2 {
		t.Errorf("expected poor=2, got %d", tierRank(TierPoor))
	}
}

func TestAppendReason(t *testing.T) {
	r := appendReason("", "rule1")
	if r != "rule1" {
		t.Errorf("expected 'rule1', got '%s'", r)
	}
	r = appendReason(r, "rule2")
	if r != "rule1; rule2" {
		t.Errorf("expected 'rule1; rule2', got '%s'", r)
	}
}
