package session

import "time"

// Topology represents the media transport path for a call.
type Topology string

const (
	TopologyP2P  Topology = "p2p"
	TopologyTURN Topology = "turn"
	TopologySFU  Topology = "sfu"
)

// Role defines a participant's role in a call.
type Role string

const (
	RoleCaller      Role = "caller"
	RoleCallee      Role = "callee"
	RoleParticipant Role = "participant"
)

// MediaState tracks a participant's media stream state.
type MediaState struct {
	AudioEnabled  bool `json:"audio_enabled"`
	VideoEnabled  bool `json:"video_enabled"`
	ScreenSharing bool `json:"screen_sharing"`
}

// Participant represents a user in a call session.
type Participant struct {
	UserID     string     `json:"user_id"`
	Role       Role       `json:"role"`
	MediaState MediaState `json:"media_state"`
	JoinedAt   time.Time  `json:"joined_at"`
	LeftAt     time.Time  `json:"left_at,omitempty"`
}

// Session represents the orchestrator's view of a call session.
type Session struct {
	CallID       string        `json:"call_id"`
	CallType     string        `json:"call_type"` // "1:1" or "group"
	Topology     Topology      `json:"topology"`
	InitiatorID  string        `json:"initiator_id"`
	Region       string        `json:"region"`
	HasVideo     bool          `json:"has_video"`
	Participants []Participant `json:"participants"`
	CreatedAt    time.Time     `json:"created_at"`
	EndedAt      time.Time     `json:"ended_at,omitempty"`
	EndReason    string        `json:"end_reason,omitempty"`
}

// ActiveParticipants returns participants who haven't left.
func (s *Session) ActiveParticipants() []Participant {
	active := make([]Participant, 0, len(s.Participants))
	for _, p := range s.Participants {
		if p.LeftAt.IsZero() {
			active = append(active, p)
		}
	}
	return active
}

// FindParticipant returns the participant with the given userID, or nil.
func (s *Session) FindParticipant(userID string) *Participant {
	for i := range s.Participants {
		if s.Participants[i].UserID == userID {
			return &s.Participants[i]
		}
	}
	return nil
}

// CDR is a Call Detail Record written after each call ends.
type CDR struct {
	CallID           string    `json:"call_id"`
	CallType         string    `json:"call_type"`
	InitiatorID      string    `json:"initiator_id"`
	Topology         string    `json:"topology"`
	Region           string    `json:"region"`
	StartedAt        time.Time `json:"started_at"`
	EndedAt          time.Time `json:"ended_at"`
	DurationSeconds  int       `json:"duration_seconds"`
	EndReason        string    `json:"end_reason"`
	ParticipantCount int       `json:"participant_count"`
	HasVideo         bool      `json:"has_video"`
}

// Permission defines what actions a role can perform.
type Permission string

const (
	PermInitiateCall  Permission = "initiate_call"
	PermAcceptCall    Permission = "accept_call"
	PermRejectCall    Permission = "reject_call"
	PermEndCall       Permission = "end_call"
	PermMuteSelf      Permission = "mute_self"
	PermUnmuteSelf    Permission = "unmute_self"
	PermToggleVideo   Permission = "toggle_video"
	PermShareScreen   Permission = "share_screen"
	PermInvite        Permission = "invite"         // group only
	PermRemoveOther   Permission = "remove_other"   // caller only in group
	PermMuteOther     Permission = "mute_other"     // caller only in group
)
