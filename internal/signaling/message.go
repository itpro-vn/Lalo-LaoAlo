package signaling

import "encoding/json"

// Client → Server message types.
const (
	MsgCallInitiate   = "call_initiate"
	MsgCallAccept     = "call_accept"
	MsgCallReject     = "call_reject"
	MsgCallEnd        = "call_end"
	MsgCallCancel     = "call_cancel"
	MsgICECandidate   = "ice_candidate"
	MsgQualityMetrics = "quality_metrics"
	MsgPing           = "ping"
	MsgReconnect      = "reconnect" // Client reconnecting to active session

	// Group call — client → server
	MsgRoomCreate = "room_create"
	MsgRoomInvite = "room_invite"
	MsgRoomJoin   = "room_join"
	MsgRoomLeave  = "room_leave"
)

// Server → Client message types.
const (
	MsgIncomingCall  = "incoming_call"
	MsgCallAccepted  = "call_accepted"
	MsgCallRejected  = "call_rejected"
	MsgCallEnded     = "call_ended"
	MsgCallCancelled = "call_cancelled"
	MsgError         = "error"
	MsgPong          = "pong"

	// Reconnection — server → client
	MsgSessionResumed    = "session_resumed"    // Session successfully recovered
	MsgPeerReconnecting  = "peer_reconnecting"  // Notify peer that other side is reconnecting
	MsgPeerReconnected   = "peer_reconnected"   // Notify peer that other side reconnected

	// Glare & multi-device — server → client
	MsgCallGlare             = "call_glare"              // Simultaneous calls detected, one cancelled
	MsgCallAcceptedElsewhere = "call_accepted_elsewhere"  // Another device accepted the call
	MsgStateSync             = "state_sync"               // Current call state sent to reconnecting client

	// Group call — server → client
	MsgRoomCreated             = "room_created"
	MsgRoomInvitation          = "room_invitation"
	MsgRoomClosed              = "room_closed"
	MsgParticipantJoined       = "participant_joined"
	MsgParticipantLeft         = "participant_left"
	MsgParticipantMediaChanged = "participant_media_changed"
)

// Envelope is the base wrapper for all signaling messages.
// Seq and MsgID support message ordering and deduplication.
type Envelope struct {
	Type  string          `json:"type"`
	Data  json.RawMessage `json:"data,omitempty"`
	Seq   int64           `json:"seq,omitempty"`    // Server-assigned sequence number (server→client only)
	MsgID string          `json:"msg_id,omitempty"` // Client-assigned message ID for deduplication
}

// --- Client → Server payloads ---

// CallInitiateMsg is sent by the caller to start a call.
type CallInitiateMsg struct {
	CalleeID string `json:"callee_id"`
	SDPOffer string `json:"sdp_offer"`
	CallType string `json:"call_type"` // "audio" or "video"
}

// CallAcceptMsg is sent by the callee to accept a call.
type CallAcceptMsg struct {
	CallID    string `json:"call_id"`
	SDPAnswer string `json:"sdp_answer"`
}

// CallRejectMsg is sent by the callee to reject a call.
type CallRejectMsg struct {
	CallID string `json:"call_id"`
	Reason string `json:"reason,omitempty"` // "busy", "declined", etc.
}

// CallEndMsg is sent by either party to end a call.
type CallEndMsg struct {
	CallID string `json:"call_id"`
}

// CallCancelMsg is sent by the caller to cancel a ringing call.
type CallCancelMsg struct {
	CallID string `json:"call_id"`
}

// ICECandidateMsg is exchanged between peers for ICE trickle.
type ICECandidateMsg struct {
	CallID    string `json:"call_id"`
	Candidate string `json:"candidate"`
}

// --- Server → Client payloads ---

// IncomingCallMsg notifies the callee of an incoming call.
type IncomingCallMsg struct {
	CallID     string `json:"call_id"`
	CallerID   string `json:"caller_id"`
	CallerName string `json:"caller_name,omitempty"`
	SDPOffer   string `json:"sdp_offer"`
	CallType   string `json:"call_type"`
}

// CallAcceptedMsg notifies the caller that the call was accepted.
type CallAcceptedMsg struct {
	CallID    string `json:"call_id"`
	SDPAnswer string `json:"sdp_answer"`
}

// CallRejectedMsg notifies the caller that the call was rejected.
type CallRejectedMsg struct {
	CallID string `json:"call_id"`
	Reason string `json:"reason,omitempty"`
}

// CallEndedMsg notifies a party that the call has ended.
type CallEndedMsg struct {
	CallID string `json:"call_id"`
	Reason string `json:"reason,omitempty"` // "normal", "timeout", "error"
}

// CallCancelledMsg notifies the callee that the caller cancelled.
type CallCancelledMsg struct {
	CallID string `json:"call_id"`
}

// ErrorMsg sends an error back to the client.
type ErrorMsg struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	CallID  string `json:"call_id,omitempty"`
}

// QualityMetricsMsg is sent by clients with batched QoS samples.
type QualityMetricsMsg struct {
	CallID  string               `json:"call_id"`
	Samples []QualityMetricSample `json:"samples"`
}

// QualityMetricSample is a single client-reported QoS measurement.
type QualityMetricSample struct {
	Timestamp   int64   `json:"ts"`            // unix millis
	Direction   string  `json:"direction"`     // "send" or "recv"
	RTTMs       int     `json:"rtt_ms"`
	LossPct     float64 `json:"loss_pct"`
	JitterMs    float64 `json:"jitter_ms"`
	BitrateKbps int     `json:"bitrate_kbps"`
	Framerate   int     `json:"framerate"`
	Resolution  string  `json:"resolution"`    // "1280x720"
	NetworkTier string  `json:"network_tier"`  // "good", "fair", "poor"
}

// --- Group call — Client → Server payloads ---

// RoomCreateMsg is sent by the initiator to create a group call room.
type RoomCreateMsg struct {
	Participants []string `json:"participants"` // user IDs to invite
	CallType     string   `json:"call_type"`    // "audio" or "video"
}

// RoomInviteMsg is sent by the host to invite more participants mid-call.
type RoomInviteMsg struct {
	RoomID   string   `json:"room_id"`
	Invitees []string `json:"invitees"` // user IDs to invite
}

// RoomJoinMsg is sent by an invited participant to join a room.
type RoomJoinMsg struct {
	RoomID string `json:"room_id"`
}

// RoomLeaveMsg is sent by a participant to leave a room.
type RoomLeaveMsg struct {
	RoomID string `json:"room_id"`
}

// --- Group call — Server → Client payloads ---

// RoomCreatedMsg notifies the initiator that the room was created.
type RoomCreatedMsg struct {
	RoomID       string `json:"room_id"`
	LiveKitToken string `json:"livekit_token"`
	LiveKitURL   string `json:"livekit_url"`
}

// RoomInvitationMsg notifies an invitee of a group call invitation.
type RoomInvitationMsg struct {
	RoomID     string   `json:"room_id"`
	InviterID  string   `json:"inviter_id"`
	CallType   string   `json:"call_type"`
	Participants []string `json:"participants"` // current participant IDs
}

// RoomClosedMsg notifies all participants that the room is closed.
type RoomClosedMsg struct {
	RoomID string `json:"room_id"`
	Reason string `json:"reason,omitempty"` // "host_left", "all_left", "ended"
}

// ParticipantJoinedMsg notifies room members that someone joined.
type ParticipantJoinedMsg struct {
	RoomID string `json:"room_id"`
	UserID string `json:"user_id"`
	Role   string `json:"role"` // "host" or "participant"
}

// ParticipantLeftMsg notifies room members that someone left.
type ParticipantLeftMsg struct {
	RoomID string `json:"room_id"`
	UserID string `json:"user_id"`
}

// ParticipantMediaChangedMsg notifies room members of a media state change.
type ParticipantMediaChangedMsg struct {
	RoomID string `json:"room_id"`
	UserID string `json:"user_id"`
	Audio  bool   `json:"audio"`
	Video  bool   `json:"video"`
}

// Error codes.
const (
	ErrCodeInvalidMessage = "invalid_message"
	ErrCodeUnauthorized   = "unauthorized"
	ErrCodeNotFound       = "not_found"
	ErrCodeBusy           = "busy"
	ErrCodeTimeout        = "timeout"
	ErrCodeRateLimit      = "rate_limited"
	ErrCodeInternal       = "internal_error"
	ErrCodeInvalidState   = "invalid_state"
	ErrCodeRoomFull       = "room_full"
	ErrCodeReconnectFailed = "reconnect_failed"
	ErrCodeGlare           = "glare"         // Simultaneous calls — one was cancelled
	ErrCodeCallCancelled   = "call_cancelled" // Cancel won the race against accept
	ErrCodeDuplicate       = "duplicate"      // Duplicate message ID
	ErrCodeInvalidSDP      = "invalid_sdp"    // SDP validation failed
)

// --- Reconnection payloads ---

// ReconnectMsg is sent by a client to resume an active call session after a disconnect.
type ReconnectMsg struct {
	CallID string `json:"call_id"`
}

// SessionResumedMsg is sent by the server to confirm session recovery.
type SessionResumedMsg struct {
	CallID   string    `json:"call_id"`
	State    CallState `json:"state"`
	PeerID   string    `json:"peer_id"`
	SDPOffer string    `json:"sdp_offer,omitempty"` // If peer sent a new offer during reconnect
}

// PeerReconnectingMsg notifies a peer that the other side is reconnecting.
type PeerReconnectingMsg struct {
	CallID string `json:"call_id"`
	PeerID string `json:"peer_id"`
}

// PeerReconnectedMsg notifies a peer that the other side has reconnected.
type PeerReconnectedMsg struct {
	CallID string `json:"call_id"`
	PeerID string `json:"peer_id"`
}

// --- Glare & Multi-device payloads ---

// CallGlareMsg notifies the losing caller in a glare scenario.
// The loser's call is automatically cancelled; they should accept/reject the winning call.
type CallGlareMsg struct {
	CancelledCallID string `json:"cancelled_call_id"` // The call that was auto-cancelled
	WinningCallID   string `json:"winning_call_id"`   // The call that won (lower user_id)
	PeerID          string `json:"peer_id"`            // The other user
}

// CallAcceptedElsewhereMsg notifies other devices that one device already accepted.
type CallAcceptedElsewhereMsg struct {
	CallID   string `json:"call_id"`
	DeviceID string `json:"device_id"` // Which device accepted
}

// StateSyncMsg sends current call state to a reconnecting or newly connected client.
type StateSyncMsg struct {
	ActiveCalls []StateSyncCall `json:"active_calls"`
}

// StateSyncCall is a single active call in a state sync response.
type StateSyncCall struct {
	CallID   string    `json:"call_id"`
	PeerID   string    `json:"peer_id"`
	CallType string    `json:"call_type"`
	State    CallState `json:"state"`
	Role     string    `json:"role"` // "caller" or "callee"
}
