// Package abr provides the server-side ABR policy engine.
//
// The policy engine receives quality metrics from clients, evaluates
// ABR rules, and pushes policy overrides back via signaling.
package abr

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"github.com/minhgv/lalo/internal/config"
	lk "github.com/minhgv/lalo/internal/livekit"
)

// QualityTier represents a network quality classification.
type QualityTier string

const (
	TierGood QualityTier = "good"
	TierFair QualityTier = "fair"
	TierPoor QualityTier = "poor"
)

// MetricSample is a single quality metric sample from a client.
type MetricSample struct {
	Timestamp     time.Time   `json:"timestamp"`
	RTTMs         float64     `json:"rtt_ms"`
	LossPercent   float64     `json:"loss_percent"`
	JitterMs      float64     `json:"jitter_ms"`
	BandwidthKbps float64     `json:"bandwidth_kbps"`
	Tier          QualityTier `json:"tier"`
	AudioLevel    float64     `json:"audio_level,omitempty"`
	FrameWidth    int         `json:"frame_width,omitempty"`
	FrameHeight   int         `json:"frame_height,omitempty"`
	FPS           float64     `json:"fps,omitempty"`
}

// ParticipantMetrics holds recent quality metrics for a participant.
type ParticipantMetrics struct {
	Identity  string
	RoomName  string
	Samples   []MetricSample
	UpdatedAt time.Time
}

// PolicyDecision is the output of the policy engine for a participant.
type PolicyDecision struct {
	MaxTier        *QualityTier `json:"max_tier,omitempty"`
	ForceAudioOnly *bool        `json:"force_audio_only,omitempty"`
	MaxBitrateKbps *int         `json:"max_bitrate_kbps,omitempty"`
	ForceCodec     *string      `json:"force_codec,omitempty"`
	Reason         string       `json:"reason,omitempty"`
}

// PolicyRule defines a single evaluable ABR rule.
type PolicyRule struct {
	// Name for logging/debugging.
	Name string `yaml:"name" json:"name"`
	// Condition type: "avg_loss_above", "avg_rtt_above", "bandwidth_below".
	Condition string `yaml:"condition" json:"condition"`
	// Threshold value for the condition.
	Threshold float64 `yaml:"threshold" json:"threshold"`
	// Action: "cap_tier", "force_audio_only", "cap_bitrate".
	Action string `yaml:"action" json:"action"`
	// ActionValue for cap_tier ("fair"/"poor") or cap_bitrate (kbps).
	ActionValue string `yaml:"action_value" json:"action_value"`
}

// PolicyConfig holds the policy engine configuration.
type PolicyConfig struct {
	// EvalIntervalSeconds is how often the engine evaluates rules (default: 10).
	EvalIntervalSeconds int `yaml:"eval_interval_seconds" json:"eval_interval_seconds"`
	// MetricWindowSeconds is how far back metrics are considered (default: 30).
	MetricWindowSeconds int `yaml:"metric_window_seconds" json:"metric_window_seconds"`
	// Rules is the list of evaluation rules.
	Rules []PolicyRule `yaml:"rules" json:"rules"`
}

// DefaultPolicyConfig returns sensible defaults.
func DefaultPolicyConfig() PolicyConfig {
	return PolicyConfig{
		EvalIntervalSeconds: 10,
		MetricWindowSeconds: 30,
		Rules: []PolicyRule{
			{
				Name:        "high_loss_cap_fair",
				Condition:   "avg_loss_above",
				Threshold:   8.0,
				Action:      "cap_tier",
				ActionValue: "fair",
			},
			{
				Name:        "very_high_loss_cap_poor",
				Condition:   "avg_loss_above",
				Threshold:   15.0,
				Action:      "cap_tier",
				ActionValue: "poor",
			},
			{
				Name:        "high_rtt_cap_fair",
				Condition:   "avg_rtt_above",
				Threshold:   300.0,
				Action:      "cap_tier",
				ActionValue: "fair",
			},
			{
				Name:        "low_bandwidth_audio_only",
				Condition:   "bandwidth_below",
				Threshold:   80.0,
				Action:      "force_audio_only",
				ActionValue: "true",
			},
		},
	}
}

// PolicyEngine evaluates ABR rules and pushes policy updates.
type PolicyEngine struct {
	cfg         PolicyConfig
	qualityCfg  config.QualityConfig
	roomService *lk.RoomService

	mu      sync.RWMutex
	metrics map[string]*ParticipantMetrics // key: "room:identity"
	stop    chan struct{}
	running bool
}

// NewPolicyEngine creates a new policy engine.
func NewPolicyEngine(
	cfg PolicyConfig,
	qualityCfg config.QualityConfig,
	roomService *lk.RoomService,
) *PolicyEngine {
	return &PolicyEngine{
		cfg:         cfg,
		qualityCfg:  qualityCfg,
		roomService: roomService,
		metrics:     make(map[string]*ParticipantMetrics),
		stop:        make(chan struct{}),
	}
}

// Start begins the periodic rule evaluation loop.
func (e *PolicyEngine) Start() {
	e.mu.Lock()
	if e.running {
		e.mu.Unlock()
		return
	}
	e.running = true
	e.mu.Unlock()

	interval := time.Duration(e.cfg.EvalIntervalSeconds) * time.Second
	if interval <= 0 {
		interval = 10 * time.Second
	}

	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()

		for {
			select {
			case <-ticker.C:
				e.evaluateAll()
			case <-e.stop:
				return
			}
		}
	}()
}

// Stop halts the evaluation loop.
func (e *PolicyEngine) Stop() {
	e.mu.Lock()
	defer e.mu.Unlock()

	if !e.running {
		return
	}
	e.running = false
	close(e.stop)
}

// IngestMetrics records quality metric samples from a participant.
func (e *PolicyEngine) IngestMetrics(roomName, identity string, samples []MetricSample) {
	key := roomName + ":" + identity
	now := time.Now()

	e.mu.Lock()
	defer e.mu.Unlock()

	pm, ok := e.metrics[key]
	if !ok {
		pm = &ParticipantMetrics{
			Identity: identity,
			RoomName: roomName,
		}
		e.metrics[key] = pm
	}

	pm.Samples = append(pm.Samples, samples...)
	pm.UpdatedAt = now

	// Trim old samples beyond the metric window.
	cutoff := now.Add(-time.Duration(e.cfg.MetricWindowSeconds) * time.Second)
	trimmed := pm.Samples[:0]
	for _, s := range pm.Samples {
		if s.Timestamp.After(cutoff) {
			trimmed = append(trimmed, s)
		}
	}
	pm.Samples = trimmed
}

// RemoveParticipant cleans up metrics for a participant.
func (e *PolicyEngine) RemoveParticipant(roomName, identity string) {
	key := roomName + ":" + identity

	e.mu.Lock()
	defer e.mu.Unlock()
	delete(e.metrics, key)
}

// GetParticipantPolicy returns the current evaluated policy for a participant.
// Returns nil when no metrics are available or no rules are currently triggered.
func (e *PolicyEngine) GetParticipantPolicy(roomName, identity string) *PolicyDecision {
	key := roomName + ":" + identity

	e.mu.RLock()
	pm, ok := e.metrics[key]
	if !ok {
		e.mu.RUnlock()
		return nil
	}

	copyPM := &ParticipantMetrics{
		Identity:  pm.Identity,
		RoomName:  pm.RoomName,
		UpdatedAt: pm.UpdatedAt,
		Samples:   append([]MetricSample(nil), pm.Samples...),
	}
	e.mu.RUnlock()

	return e.EvaluateParticipant(copyPM)
}

// EvaluateParticipant evaluates rules for a single participant.
// Exported for testing — the periodic loop calls evaluateAll.
func (e *PolicyEngine) EvaluateParticipant(pm *ParticipantMetrics) *PolicyDecision {
	if len(pm.Samples) == 0 {
		return nil
	}

	// Compute aggregates.
	var totalRTT, totalLoss, totalBW float64
	for _, s := range pm.Samples {
		totalRTT += s.RTTMs
		totalLoss += s.LossPercent
		totalBW += s.BandwidthKbps
	}
	n := float64(len(pm.Samples))
	avgRTT := totalRTT / n
	avgLoss := totalLoss / n
	avgBW := totalBW / n

	// Evaluate rules in order; first matching rule with the most
	// restrictive action wins.
	var decision PolicyDecision
	var matched bool

	for _, rule := range e.cfg.Rules {
		triggered := false

		switch rule.Condition {
		case "avg_loss_above":
			triggered = avgLoss > rule.Threshold
		case "avg_rtt_above":
			triggered = avgRTT > rule.Threshold
		case "bandwidth_below":
			triggered = avgBW > 0 && avgBW < rule.Threshold
		}

		if !triggered {
			continue
		}

		matched = true

		switch rule.Action {
		case "cap_tier":
			tier := QualityTier(rule.ActionValue)
			// Keep the most restrictive tier cap.
			if decision.MaxTier == nil || tierRank(tier) > tierRank(*decision.MaxTier) {
				decision.MaxTier = &tier
			}
			decision.Reason = appendReason(decision.Reason, rule.Name)

		case "force_audio_only":
			v := true
			decision.ForceAudioOnly = &v
			decision.Reason = appendReason(decision.Reason, rule.Name)

		case "cap_bitrate":
			var kbps int
			fmt.Sscanf(rule.ActionValue, "%d", &kbps)
			if kbps > 0 {
				if decision.MaxBitrateKbps == nil || kbps < *decision.MaxBitrateKbps {
					decision.MaxBitrateKbps = &kbps
				}
			}
			decision.Reason = appendReason(decision.Reason, rule.Name)
		}
	}

	if !matched {
		return nil
	}

	return &decision
}

// UpdateConfig hot-reloads the policy rules.
func (e *PolicyEngine) UpdateConfig(cfg PolicyConfig) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.cfg = cfg
}

// evaluateAll runs rules for all participants and pushes overrides.
func (e *PolicyEngine) evaluateAll() {
	e.mu.RLock()
	// Copy metrics map for evaluation outside lock.
	participants := make([]*ParticipantMetrics, 0, len(e.metrics))
	for _, pm := range e.metrics {
		// Shallow copy is fine — we only read samples.
		participants = append(participants, pm)
	}
	e.mu.RUnlock()

	for _, pm := range participants {
		decision := e.EvaluateParticipant(pm)
		if decision == nil {
			continue
		}

		// Push policy override via LiveKit data channel.
		e.pushPolicyUpdate(pm.RoomName, pm.Identity, decision)
	}
}

// pushPolicyUpdate sends a policy_update message to a participant.
func (e *PolicyEngine) pushPolicyUpdate(roomName, identity string, decision *PolicyDecision) {
	payload := map[string]interface{}{
		"type": "policy_update",
		"data": map[string]interface{}{
			"room_id": roomName,
		},
	}

	data := payload["data"].(map[string]interface{})
	if decision.MaxTier != nil {
		data["max_tier"] = string(*decision.MaxTier)
	}
	if decision.ForceAudioOnly != nil {
		data["force_audio_only"] = *decision.ForceAudioOnly
	}
	if decision.MaxBitrateKbps != nil {
		data["max_bitrate_kbps"] = *decision.MaxBitrateKbps
	}
	if decision.ForceCodec != nil {
		data["force_codec"] = *decision.ForceCodec
	}
	if decision.Reason != "" {
		data["reason"] = decision.Reason
	}

	jsonBytes, err := json.Marshal(payload)
	if err != nil {
		return
	}

	_ = e.roomService.SendData(context.Background(), lk.SendDataRequest{
		RoomName:              roomName,
		Payload:               jsonBytes,
		DestinationIdentities: []string{identity},
		Reliable:              true,
	})
}

func tierRank(t QualityTier) int {
	switch t {
	case TierGood:
		return 0
	case TierFair:
		return 1
	case TierPoor:
		return 2
	default:
		return 0
	}
}

func appendReason(existing, rule string) string {
	if existing == "" {
		return rule
	}
	return existing + "; " + rule
}
