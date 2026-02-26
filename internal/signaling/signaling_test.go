package signaling

import (
	"encoding/json"
	"testing"
)

func TestStateMachine_ValidTransitions(t *testing.T) {
	tests := []struct {
		name string
		path []CallState
	}{
		{"happy path", []CallState{StateRinging, StateConnecting, StateActive, StateEnded, StateCleanup}},
		{"reject path", []CallState{StateRinging, StateEnded, StateCleanup}},
		{"ice timeout", []CallState{StateRinging, StateConnecting, StateEnded, StateCleanup}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			sm := NewStateMachine()
			for _, state := range tt.path {
				if err := sm.Transition(state); err != nil {
					t.Fatalf("transition to %s failed: %v", state, err)
				}
				if sm.State() != state {
					t.Fatalf("expected state %s, got %s", state, sm.State())
				}
			}
		})
	}
}

func TestStateMachine_InvalidTransitions(t *testing.T) {
	tests := []struct {
		name string
		from CallState
		to   CallState
	}{
		{"idle to active", StateIdle, StateActive},
		{"ringing to active", StateRinging, StateActive},
		{"active to connecting", StateActive, StateConnecting},
		{"ended to active", StateEnded, StateActive},
		{"idle to ended", StateIdle, StateEnded},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			sm := NewStateMachineFrom(tt.from)
			if err := sm.Transition(tt.to); err == nil {
				t.Fatalf("expected error for %s → %s", tt.from, tt.to)
			}
		})
	}
}

func TestStateMachine_CanTransition(t *testing.T) {
	sm := NewStateMachine()
	if !sm.CanTransition(StateRinging) {
		t.Error("should be able to transition IDLE → RINGING")
	}
	if sm.CanTransition(StateActive) {
		t.Error("should not be able to transition IDLE → ACTIVE")
	}
}

func TestStateMachine_IsTerminal(t *testing.T) {
	sm := NewStateMachineFrom(StateActive)
	if sm.IsTerminal() {
		t.Error("ACTIVE should not be terminal")
	}

	sm = NewStateMachineFrom(StateEnded)
	if !sm.IsTerminal() {
		t.Error("ENDED should be terminal")
	}
}

func TestEnvelope_Serialization(t *testing.T) {
	msg := CallInitiateMsg{
		CalleeID: "user-2",
		SDPOffer: "v=0\r\n...",
		CallType: "video",
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}

	env := Envelope{
		Type: MsgCallInitiate,
		Data: data,
	}

	raw, err := json.Marshal(env)
	if err != nil {
		t.Fatal(err)
	}

	var decoded Envelope
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatal(err)
	}

	if decoded.Type != MsgCallInitiate {
		t.Errorf("expected type %s, got %s", MsgCallInitiate, decoded.Type)
	}

	var decodedMsg CallInitiateMsg
	if err := json.Unmarshal(decoded.Data, &decodedMsg); err != nil {
		t.Fatal(err)
	}

	if decodedMsg.CalleeID != "user-2" {
		t.Errorf("expected callee_id user-2, got %s", decodedMsg.CalleeID)
	}
	if decodedMsg.CallType != "video" {
		t.Errorf("expected call_type video, got %s", decodedMsg.CallType)
	}
}

func TestMessageTypes_Constants(t *testing.T) {
	// Verify all message type constants are distinct
	types := []string{
		MsgCallInitiate, MsgCallAccept, MsgCallReject, MsgCallEnd,
		MsgCallCancel, MsgICECandidate, MsgPing, MsgQualityMetrics, MsgReconnect,
		MsgIncomingCall, MsgCallAccepted, MsgCallRejected, MsgCallEnded,
		MsgCallCancelled, MsgError, MsgPong,
		MsgSessionResumed, MsgPeerReconnecting, MsgPeerReconnected,
	}

	seen := make(map[string]bool)
	for _, typ := range types {
		if typ == "" {
			t.Error("empty message type constant")
		}
		if seen[typ] {
			t.Errorf("duplicate message type: %s", typ)
		}
		seen[typ] = true
	}
}

func TestErrorMsg_Serialization(t *testing.T) {
	errMsg := ErrorMsg{
		Code:    ErrCodeBusy,
		Message: "user is busy",
		CallID:  "call-123",
	}

	data, err := json.Marshal(errMsg)
	if err != nil {
		t.Fatal(err)
	}

	var decoded ErrorMsg
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}

	if decoded.Code != ErrCodeBusy {
		t.Errorf("expected code %s, got %s", ErrCodeBusy, decoded.Code)
	}
	if decoded.CallID != "call-123" {
		t.Errorf("expected call_id call-123, got %s", decoded.CallID)
	}
}

func TestCallSession_JSON(t *testing.T) {
	session := CallSession{
		CallID:   "call-abc",
		CallerID: "user-1",
		CalleeID: "user-2",
		CallType: "audio",
		State:    StateRinging,
		SDPOffer: "v=0\r\n...",
	}

	data, err := json.Marshal(session)
	if err != nil {
		t.Fatal(err)
	}

	var decoded CallSession
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}

	if decoded.CallID != session.CallID {
		t.Errorf("expected call_id %s, got %s", session.CallID, decoded.CallID)
	}
	if decoded.State != StateRinging {
		t.Errorf("expected state %s, got %s", StateRinging, decoded.State)
	}
}

// --- Group call message tests ---

func TestRoomCreateMsgSerialization(t *testing.T) {
	msg := RoomCreateMsg{
		Participants: []string{"user-a", "user-b", "user-c"},
		CallType:     "video",
	}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded RoomCreateMsg
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if len(decoded.Participants) != 3 {
		t.Errorf("expected 3 participants, got %d", len(decoded.Participants))
	}
	if decoded.CallType != "video" {
		t.Errorf("expected video, got %s", decoded.CallType)
	}
}

func TestRoomInviteMsgSerialization(t *testing.T) {
	msg := RoomInviteMsg{
		RoomID:   "room-abc",
		Invitees: []string{"user-d", "user-e"},
	}
	data, _ := json.Marshal(msg)

	var decoded RoomInviteMsg
	json.Unmarshal(data, &decoded)

	if decoded.RoomID != "room-abc" {
		t.Errorf("expected room-abc, got %s", decoded.RoomID)
	}
	if len(decoded.Invitees) != 2 {
		t.Errorf("expected 2 invitees, got %d", len(decoded.Invitees))
	}
}

func TestRoomCreatedMsgSerialization(t *testing.T) {
	msg := RoomCreatedMsg{
		RoomID:       "room-123",
		LiveKitToken: "token-xyz",
		LiveKitURL:   "ws://lk.example.com",
	}
	data, _ := json.Marshal(msg)

	var decoded RoomCreatedMsg
	json.Unmarshal(data, &decoded)

	if decoded.RoomID != "room-123" {
		t.Errorf("expected room-123, got %s", decoded.RoomID)
	}
	if decoded.LiveKitToken != "token-xyz" {
		t.Errorf("expected token-xyz, got %s", decoded.LiveKitToken)
	}
}

func TestRoomInvitationMsgSerialization(t *testing.T) {
	msg := RoomInvitationMsg{
		RoomID:       "room-456",
		InviterID:    "user-host",
		CallType:     "audio",
		Participants: []string{"user-a", "user-b"},
	}
	data, _ := json.Marshal(msg)

	var decoded RoomInvitationMsg
	json.Unmarshal(data, &decoded)

	if decoded.InviterID != "user-host" {
		t.Errorf("expected user-host, got %s", decoded.InviterID)
	}
	if len(decoded.Participants) != 2 {
		t.Errorf("expected 2 participants, got %d", len(decoded.Participants))
	}
}

func TestParticipantJoinedMsgSerialization(t *testing.T) {
	msg := ParticipantJoinedMsg{
		RoomID: "room-1",
		UserID: "user-new",
		Role:   "participant",
	}
	data, _ := json.Marshal(msg)

	var decoded ParticipantJoinedMsg
	json.Unmarshal(data, &decoded)

	if decoded.UserID != "user-new" {
		t.Errorf("expected user-new, got %s", decoded.UserID)
	}
	if decoded.Role != "participant" {
		t.Errorf("expected participant, got %s", decoded.Role)
	}
}

func TestParticipantLeftMsgSerialization(t *testing.T) {
	msg := ParticipantLeftMsg{
		RoomID: "room-1",
		UserID: "user-gone",
	}
	data, _ := json.Marshal(msg)

	var decoded ParticipantLeftMsg
	json.Unmarshal(data, &decoded)

	if decoded.UserID != "user-gone" {
		t.Errorf("expected user-gone, got %s", decoded.UserID)
	}
}

func TestParticipantMediaChangedMsgSerialization(t *testing.T) {
	msg := ParticipantMediaChangedMsg{
		RoomID: "room-1",
		UserID: "user-1",
		Audio:  true,
		Video:  false,
	}
	data, _ := json.Marshal(msg)

	var decoded ParticipantMediaChangedMsg
	json.Unmarshal(data, &decoded)

	if !decoded.Audio {
		t.Error("expected audio=true")
	}
	if decoded.Video {
		t.Error("expected video=false")
	}
}

func TestGroupMessageTypeUniqueness(t *testing.T) {
	types := []string{
		MsgRoomCreate, MsgRoomInvite, MsgRoomJoin, MsgRoomLeave,
		MsgRoomCreated, MsgRoomInvitation, MsgRoomClosed,
		MsgParticipantJoined, MsgParticipantLeft, MsgParticipantMediaChanged,
	}

	seen := make(map[string]bool)
	for _, typ := range types {
		if seen[typ] {
			t.Errorf("duplicate message type: %s", typ)
		}
		seen[typ] = true
	}
}

func TestRoomClosedMsgSerialization(t *testing.T) {
	msg := RoomClosedMsg{
		RoomID: "room-dead",
		Reason: "all_left",
	}
	data, _ := json.Marshal(msg)

	var decoded RoomClosedMsg
	json.Unmarshal(data, &decoded)

	if decoded.RoomID != "room-dead" {
		t.Errorf("expected room-dead, got %s", decoded.RoomID)
	}
	if decoded.Reason != "all_left" {
		t.Errorf("expected all_left, got %s", decoded.Reason)
	}
}

func TestErrCodeRoomFull(t *testing.T) {
	if ErrCodeRoomFull != "room_full" {
		t.Errorf("expected room_full, got %s", ErrCodeRoomFull)
	}
}

// --- Reconnection tests ---

func TestStateMachine_ReconnectPath(t *testing.T) {
	tests := []struct {
		name string
		path []CallState
	}{
		{"reconnect success", []CallState{StateRinging, StateConnecting, StateActive, StateReconnecting, StateActive, StateEnded, StateCleanup}},
		{"reconnect fail", []CallState{StateRinging, StateConnecting, StateActive, StateReconnecting, StateEnded, StateCleanup}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			sm := NewStateMachine()
			for _, state := range tt.path {
				if err := sm.Transition(state); err != nil {
					t.Fatalf("transition to %s failed: %v", state, err)
				}
				if sm.State() != state {
					t.Fatalf("expected state %s, got %s", state, sm.State())
				}
			}
		})
	}
}

func TestStateMachine_InvalidReconnectTransitions(t *testing.T) {
	tests := []struct {
		name string
		from CallState
		to   CallState
	}{
		{"idle to reconnecting", StateIdle, StateReconnecting},
		{"ringing to reconnecting", StateRinging, StateReconnecting},
		{"connecting to reconnecting", StateConnecting, StateReconnecting},
		{"reconnecting to connecting", StateReconnecting, StateConnecting},
		{"reconnecting to ringing", StateReconnecting, StateRinging},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			sm := NewStateMachineFrom(tt.from)
			if err := sm.Transition(tt.to); err == nil {
				t.Fatalf("expected error for %s → %s", tt.from, tt.to)
			}
		})
	}
}

func TestReconnectingIsNotTerminal(t *testing.T) {
	sm := NewStateMachineFrom(StateReconnecting)
	if sm.IsTerminal() {
		t.Error("RECONNECTING should not be terminal")
	}
}

func TestReconnectMsgSerialization(t *testing.T) {
	msg := ReconnectMsg{CallID: "call-123"}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}

	var decoded ReconnectMsg
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.CallID != "call-123" {
		t.Errorf("expected call-123, got %s", decoded.CallID)
	}
}

func TestSessionResumedMsgSerialization(t *testing.T) {
	msg := SessionResumedMsg{
		CallID:   "call-456",
		State:    StateActive,
		PeerID:   "user-2",
		SDPOffer: "v=0\r\n...",
	}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}

	var decoded SessionResumedMsg
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.CallID != "call-456" {
		t.Errorf("expected call-456, got %s", decoded.CallID)
	}
	if decoded.State != StateActive {
		t.Errorf("expected ACTIVE, got %s", decoded.State)
	}
	if decoded.PeerID != "user-2" {
		t.Errorf("expected user-2, got %s", decoded.PeerID)
	}
	if decoded.SDPOffer != "v=0\r\n..." {
		t.Errorf("expected sdp offer, got %s", decoded.SDPOffer)
	}
}

func TestPeerReconnectingMsgSerialization(t *testing.T) {
	msg := PeerReconnectingMsg{CallID: "call-789", PeerID: "user-3"}
	data, _ := json.Marshal(msg)

	var decoded PeerReconnectingMsg
	json.Unmarshal(data, &decoded)

	if decoded.CallID != "call-789" {
		t.Errorf("expected call-789, got %s", decoded.CallID)
	}
	if decoded.PeerID != "user-3" {
		t.Errorf("expected user-3, got %s", decoded.PeerID)
	}
}

func TestPeerReconnectedMsgSerialization(t *testing.T) {
	msg := PeerReconnectedMsg{CallID: "call-789", PeerID: "user-3"}
	data, _ := json.Marshal(msg)

	var decoded PeerReconnectedMsg
	json.Unmarshal(data, &decoded)

	if decoded.CallID != "call-789" {
		t.Errorf("expected call-789, got %s", decoded.CallID)
	}
	if decoded.PeerID != "user-3" {
		t.Errorf("expected user-3, got %s", decoded.PeerID)
	}
}

func TestErrCodeReconnectFailed(t *testing.T) {
	if ErrCodeReconnectFailed != "reconnect_failed" {
		t.Errorf("expected reconnect_failed, got %s", ErrCodeReconnectFailed)
	}
}

func TestReconnectMessageTypeUniqueness(t *testing.T) {
	types := []string{
		MsgReconnect, MsgSessionResumed, MsgPeerReconnecting, MsgPeerReconnected,
	}

	seen := make(map[string]bool)
	for _, typ := range types {
		if typ == "" {
			t.Error("empty reconnect message type")
		}
		if seen[typ] {
			t.Errorf("duplicate reconnect message type: %s", typ)
		}
		seen[typ] = true
	}
}
