package events

import "time"

// Envelope wraps every event with metadata.
type Envelope struct {
	ID        string    `json:"id"`
	Type      string    `json:"type"`
	Timestamp time.Time `json:"timestamp"`
	Source    string    `json:"source"`    // originating service
	Payload   any       `json:"payload"`
}

// --- Call lifecycle events ---

// CallInitiated is published when a new call is created.
type CallInitiated struct {
	CallID      string `json:"call_id"`
	CallerID    string `json:"caller_id"`
	CalleeID    string `json:"callee_id"`
	CallType    string `json:"call_type"`    // "1:1" or "group"
	HasVideo    bool   `json:"has_video"`
	Region      string `json:"region"`
}

// CallAccepted is published when the callee accepts a call.
type CallAccepted struct {
	CallID   string `json:"call_id"`
	UserID   string `json:"user_id"`
	Topology string `json:"topology"` // "p2p", "turn", "sfu"
}

// CallRejected is published when the callee rejects a call.
type CallRejected struct {
	CallID string `json:"call_id"`
	UserID string `json:"user_id"`
	Reason string `json:"reason"` // "busy", "declined", "timeout"
}

// CallEnded is published when a call terminates.
type CallEnded struct {
	CallID    string `json:"call_id"`
	EndReason string `json:"end_reason"` // "normal", "timeout", "error", "network_failure"
	Duration  int    `json:"duration"`   // seconds
}

// CallStateChanged is published on state machine transitions.
type CallStateChanged struct {
	CallID    string `json:"call_id"`
	FromState string `json:"from_state"`
	ToState   string `json:"to_state"`
	Trigger   string `json:"trigger"`
}

// --- Quality events ---

// QualityTierChanged is published when network tier changes.
type QualityTierChanged struct {
	CallID        string `json:"call_id"`
	ParticipantID string `json:"participant_id"`
	FromTier      string `json:"from_tier"` // "good", "fair", "poor"
	ToTier        string `json:"to_tier"`
}

// QualityMetricsSample is a single QoS measurement.
type QualityMetricsSample struct {
	ParticipantID string  `json:"participant_id"`
	Timestamp     int64   `json:"ts"`              // unix millis
	Direction     string  `json:"direction"`        // "send" or "recv"
	RTTMs         int     `json:"rtt_ms"`
	LossPct       float64 `json:"loss_pct"`
	JitterMs      float64 `json:"jitter_ms"`
	BitrateKbps   int     `json:"bitrate_kbps"`
	Framerate     int     `json:"framerate"`
	Resolution    string  `json:"resolution"`       // e.g. "1280x720"
	NetworkTier   string  `json:"network_tier"`     // "good", "fair", "poor"
}

// QualityMetrics is published as a batch of QoS samples.
type QualityMetrics struct {
	CallID  string                 `json:"call_id"`
	Region  string                 `json:"region,omitempty"`
	Samples []QualityMetricsSample `json:"samples"`
}

// --- Presence events ---

// PresenceUpdated is published when user online status changes.
type PresenceUpdated struct {
	UserID   string `json:"user_id"`
	Status   string `json:"status"`    // "online", "offline"
	DeviceID string `json:"device_id"`
}

// --- Room/group call events ---

// RoomCreated is published when a new group call room is created.
type RoomCreated struct {
	RoomID       string   `json:"room_id"`
	InitiatorID  string   `json:"initiator_id"`
	CallType     string   `json:"call_type"` // "audio" or "video"
	Participants []string `json:"participants"`
}

// RoomClosed is published when a group call room is closed.
type RoomClosed struct {
	RoomID   string `json:"room_id"`
	Reason   string `json:"reason"` // "host_left", "all_left", "ended"
	Duration int    `json:"duration"` // seconds
}

// RoomParticipantJoined is published when a participant joins a room.
type RoomParticipantJoined struct {
	RoomID string `json:"room_id"`
	UserID string `json:"user_id"`
	Role   string `json:"role"` // "host" or "participant"
}

// RoomParticipantLeft is published when a participant leaves a room.
type RoomParticipantLeft struct {
	RoomID string `json:"room_id"`
	UserID string `json:"user_id"`
}
