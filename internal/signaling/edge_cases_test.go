package signaling

import (
	"encoding/json"
	"testing"
)

// --- SDP Validation ---

func TestIsValidSDP_Valid(t *testing.T) {
	sdp := "v=0\r\no=- 1234 5678 IN IP4 0.0.0.0\r\ns=-\r\n"
	if !isValidSDP(sdp) {
		t.Error("expected valid SDP")
	}
}

func TestIsValidSDP_TooShort(t *testing.T) {
	if isValidSDP("v=0") {
		t.Error("expected invalid SDP for short string")
	}
}

func TestIsValidSDP_TooLong(t *testing.T) {
	long := make([]byte, 65537)
	for i := range long {
		long[i] = 'a'
	}
	if isValidSDP(string(long)) {
		t.Error("expected invalid SDP for long string")
	}
}

func TestIsValidSDP_MissingVersion(t *testing.T) {
	// Has o= but not v=0
	if isValidSDP("o=- 1234 5678 IN IP4 0.0.0.0 some padding text") {
		t.Error("expected invalid SDP without v=0")
	}
}

func TestIsValidSDP_MissingOrigin(t *testing.T) {
	// Has v=0 but not o=
	if isValidSDP("v=0\r\ns=-\r\nt=0 0\r\nsome padding") {
		t.Error("expected invalid SDP without o=")
	}
}

func TestIsValidSDP_Empty(t *testing.T) {
	if isValidSDP("") {
		t.Error("expected invalid SDP for empty string")
	}
}

// --- Multi-device: sendToUser / sendToUserExcept / isUserOnline / nextSeq ---

// newTestClient creates a Client with a send channel but no real websocket
// (SendJSONWithSeq only uses the send channel, not conn).
func newTestClient(hub *Hub, userID, deviceID string) *Client {
	return &Client{
		hub:      hub,
		send:     make(chan []byte, 64),
		userID:   userID,
		deviceID: deviceID,
	}
}

// drainMessages reads all queued messages from a test client's send channel.
func drainMessages(c *Client) []Envelope {
	var msgs []Envelope
	for {
		select {
		case raw := <-c.send:
			var env Envelope
			if err := json.Unmarshal(raw, &env); err == nil {
				msgs = append(msgs, env)
			}
		default:
			return msgs
		}
	}
}

func TestSendToUser_AllDevices(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)

	c1 := newTestClient(h, "alice", "phone")
	c2 := newTestClient(h, "alice", "tablet")

	h.clientsMu.Lock()
	h.clients["alice"] = map[string]*Client{
		"phone":  c1,
		"tablet": c2,
	}
	h.clientsMu.Unlock()

	reached := h.sendToUser("alice", "test_msg", map[string]string{"key": "value"})
	if !reached {
		t.Fatal("expected sendToUser to reach at least one device")
	}

	msgs1 := drainMessages(c1)
	msgs2 := drainMessages(c2)

	if len(msgs1) != 1 {
		t.Fatalf("expected 1 message on phone, got %d", len(msgs1))
	}
	if len(msgs2) != 1 {
		t.Fatalf("expected 1 message on tablet, got %d", len(msgs2))
	}

	if msgs1[0].Type != "test_msg" {
		t.Errorf("expected test_msg, got %s", msgs1[0].Type)
	}
	// Both devices should get the same seq
	if msgs1[0].Seq != msgs2[0].Seq {
		t.Errorf("expected same seq on both devices, got %d and %d", msgs1[0].Seq, msgs2[0].Seq)
	}
	if msgs1[0].Seq == 0 {
		t.Error("expected non-zero seq")
	}
}

func TestSendToUser_NoDevices(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)

	reached := h.sendToUser("nobody", "test_msg", nil)
	if reached {
		t.Fatal("expected sendToUser to return false for offline user")
	}
}

func TestSendToUserExcept(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)

	c1 := newTestClient(h, "bob", "phone")
	c2 := newTestClient(h, "bob", "laptop")
	c3 := newTestClient(h, "bob", "tablet")

	h.clientsMu.Lock()
	h.clients["bob"] = map[string]*Client{
		"phone":  c1,
		"laptop": c2,
		"tablet": c3,
	}
	h.clientsMu.Unlock()

	h.sendToUserExcept("bob", "phone", MsgCallAcceptedElsewhere, CallAcceptedElsewhereMsg{
		CallID:   "call-123",
		DeviceID: "phone",
	})

	msgs1 := drainMessages(c1)
	msgs2 := drainMessages(c2)
	msgs3 := drainMessages(c3)

	if len(msgs1) != 0 {
		t.Fatalf("expected 0 messages on excluded phone device, got %d", len(msgs1))
	}
	if len(msgs2) != 1 {
		t.Fatalf("expected 1 message on laptop, got %d", len(msgs2))
	}
	if len(msgs3) != 1 {
		t.Fatalf("expected 1 message on tablet, got %d", len(msgs3))
	}

	if msgs2[0].Type != MsgCallAcceptedElsewhere {
		t.Errorf("expected %s, got %s", MsgCallAcceptedElsewhere, msgs2[0].Type)
	}
}

func TestSendToUserExcept_NoOtherDevices(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)

	c1 := newTestClient(h, "charlie", "phone")

	h.clientsMu.Lock()
	h.clients["charlie"] = map[string]*Client{
		"phone": c1,
	}
	h.clientsMu.Unlock()

	// Excluding the only device should send to nobody
	h.sendToUserExcept("charlie", "phone", "test_msg", nil)

	msgs := drainMessages(c1)
	if len(msgs) != 0 {
		t.Fatalf("expected 0 messages when excluding the only device, got %d", len(msgs))
	}
}

func TestIsUserOnline(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)

	if h.isUserOnline("alice") {
		t.Error("expected offline for unregistered user")
	}

	c := newTestClient(h, "alice", "phone")
	h.clientsMu.Lock()
	h.clients["alice"] = map[string]*Client{"phone": c}
	h.clientsMu.Unlock()

	if !h.isUserOnline("alice") {
		t.Error("expected online for registered user")
	}
}

func TestNextSeq_Incrementing(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)

	seq1 := h.nextSeq("user-1")
	seq2 := h.nextSeq("user-1")
	seq3 := h.nextSeq("user-1")

	if seq1 != 1 || seq2 != 2 || seq3 != 3 {
		t.Errorf("expected 1,2,3 got %d,%d,%d", seq1, seq2, seq3)
	}

	// Different user gets independent counter
	otherSeq := h.nextSeq("user-2")
	if otherSeq != 1 {
		t.Errorf("expected independent counter for user-2, got %d", otherSeq)
	}
}

func TestGetClient_ReturnsFirstDevice(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)

	c1 := newTestClient(h, "alice", "phone")

	h.clientsMu.Lock()
	h.clients["alice"] = map[string]*Client{"phone": c1}
	h.clientsMu.Unlock()

	got := h.getClient("alice")
	if got == nil {
		t.Fatal("expected non-nil client")
	}
	if got.userID != "alice" {
		t.Errorf("expected alice, got %s", got.userID)
	}
}

func TestGetClient_ReturnsNilForOffline(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)

	got := h.getClient("nobody")
	if got != nil {
		t.Error("expected nil for offline user")
	}
}

func TestGetClientDevice(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)

	c1 := newTestClient(h, "alice", "phone")
	c2 := newTestClient(h, "alice", "tablet")

	h.clientsMu.Lock()
	h.clients["alice"] = map[string]*Client{
		"phone":  c1,
		"tablet": c2,
	}
	h.clientsMu.Unlock()

	got := h.getClientDevice("alice", "tablet")
	if got != c2 {
		t.Error("expected tablet client")
	}

	got = h.getClientDevice("alice", "laptop")
	if got != nil {
		t.Error("expected nil for non-existent device")
	}

	got = h.getClientDevice("nobody", "phone")
	if got != nil {
		t.Error("expected nil for non-existent user")
	}
}

// --- Glare & Multi-device message serialization ---

func TestCallGlareMsgSerialization(t *testing.T) {
	msg := CallGlareMsg{
		CancelledCallID: "call-loser",
		WinningCallID:   "call-winner",
		PeerID:          "user-other",
	}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}

	var decoded CallGlareMsg
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}

	if decoded.CancelledCallID != "call-loser" {
		t.Errorf("expected call-loser, got %s", decoded.CancelledCallID)
	}
	if decoded.WinningCallID != "call-winner" {
		t.Errorf("expected call-winner, got %s", decoded.WinningCallID)
	}
	if decoded.PeerID != "user-other" {
		t.Errorf("expected user-other, got %s", decoded.PeerID)
	}
}

func TestCallAcceptedElsewhereMsgSerialization(t *testing.T) {
	msg := CallAcceptedElsewhereMsg{
		CallID:   "call-abc",
		DeviceID: "phone-xyz",
	}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}

	var decoded CallAcceptedElsewhereMsg
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}

	if decoded.CallID != "call-abc" {
		t.Errorf("expected call-abc, got %s", decoded.CallID)
	}
	if decoded.DeviceID != "phone-xyz" {
		t.Errorf("expected phone-xyz, got %s", decoded.DeviceID)
	}
}

func TestStateSyncMsgSerialization(t *testing.T) {
	msg := StateSyncMsg{
		ActiveCalls: []StateSyncCall{
			{
				CallID:   "call-1",
				PeerID:   "user-2",
				CallType: "video",
				State:    StateActive,
				Role:     "caller",
			},
		},
	}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}

	var decoded StateSyncMsg
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}

	if len(decoded.ActiveCalls) != 1 {
		t.Fatalf("expected 1 active call, got %d", len(decoded.ActiveCalls))
	}

	call := decoded.ActiveCalls[0]
	if call.CallID != "call-1" {
		t.Errorf("expected call-1, got %s", call.CallID)
	}
	if call.PeerID != "user-2" {
		t.Errorf("expected user-2, got %s", call.PeerID)
	}
	if call.CallType != "video" {
		t.Errorf("expected video, got %s", call.CallType)
	}
	if call.State != StateActive {
		t.Errorf("expected ACTIVE, got %s", call.State)
	}
	if call.Role != "caller" {
		t.Errorf("expected caller, got %s", call.Role)
	}
}

func TestStateSyncMsg_EmptyCalls(t *testing.T) {
	msg := StateSyncMsg{ActiveCalls: []StateSyncCall{}}
	data, _ := json.Marshal(msg)

	var decoded StateSyncMsg
	json.Unmarshal(data, &decoded)

	if len(decoded.ActiveCalls) != 0 {
		t.Errorf("expected 0 active calls, got %d", len(decoded.ActiveCalls))
	}
}

func TestStateSyncMsg_MultipleCalls(t *testing.T) {
	msg := StateSyncMsg{
		ActiveCalls: []StateSyncCall{
			{CallID: "call-1", PeerID: "user-a", CallType: "audio", State: StateActive, Role: "caller"},
			{CallID: "call-2", PeerID: "user-b", CallType: "video", State: StateRinging, Role: "callee"},
		},
	}
	data, _ := json.Marshal(msg)

	var decoded StateSyncMsg
	json.Unmarshal(data, &decoded)

	if len(decoded.ActiveCalls) != 2 {
		t.Fatalf("expected 2 active calls, got %d", len(decoded.ActiveCalls))
	}
	if decoded.ActiveCalls[0].Role != "caller" {
		t.Errorf("expected caller for first call, got %s", decoded.ActiveCalls[0].Role)
	}
	if decoded.ActiveCalls[1].Role != "callee" {
		t.Errorf("expected callee for second call, got %s", decoded.ActiveCalls[1].Role)
	}
}

// --- Envelope with Seq and MsgID ---

func TestEnvelope_SeqAndMsgID(t *testing.T) {
	env := Envelope{
		Type:  MsgCallInitiate,
		Seq:   42,
		MsgID: "msg-unique-123",
	}

	data, err := json.Marshal(env)
	if err != nil {
		t.Fatal(err)
	}

	var decoded Envelope
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}

	if decoded.Seq != 42 {
		t.Errorf("expected seq 42, got %d", decoded.Seq)
	}
	if decoded.MsgID != "msg-unique-123" {
		t.Errorf("expected msg-unique-123, got %s", decoded.MsgID)
	}
}

func TestEnvelope_OmitsZeroSeqAndEmptyMsgID(t *testing.T) {
	env := Envelope{Type: MsgPing}

	data, err := json.Marshal(env)
	if err != nil {
		t.Fatal(err)
	}

	// Zero seq and empty msg_id should be omitted (omitempty)
	str := string(data)
	if contains(str, "seq") {
		t.Errorf("expected seq to be omitted, got: %s", str)
	}
	if contains(str, "msg_id") {
		t.Errorf("expected msg_id to be omitted, got: %s", str)
	}
}

func contains(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}

// --- New Error Codes ---

func TestNewErrorCodes(t *testing.T) {
	codes := map[string]string{
		"ErrCodeGlare":         ErrCodeGlare,
		"ErrCodeCallCancelled": ErrCodeCallCancelled,
		"ErrCodeDuplicate":     ErrCodeDuplicate,
		"ErrCodeInvalidSDP":    ErrCodeInvalidSDP,
	}

	for name, code := range codes {
		if code == "" {
			t.Errorf("%s is empty", name)
		}
	}

	// Verify they are distinct from each other and existing codes
	allCodes := []string{
		ErrCodeInvalidMessage, ErrCodeUnauthorized, ErrCodeNotFound,
		ErrCodeBusy, ErrCodeTimeout, ErrCodeRateLimit, ErrCodeInternal,
		ErrCodeInvalidState, ErrCodeRoomFull, ErrCodeReconnectFailed,
		ErrCodeGlare, ErrCodeCallCancelled, ErrCodeDuplicate, ErrCodeInvalidSDP,
	}

	seen := make(map[string]bool)
	for _, code := range allCodes {
		if seen[code] {
			t.Errorf("duplicate error code: %s", code)
		}
		seen[code] = true
	}
}

// --- PB-06 Message Type Uniqueness ---

func TestPB06MessageTypeUniqueness(t *testing.T) {
	types := []string{
		MsgCallGlare, MsgCallAcceptedElsewhere, MsgStateSync,
	}

	// Check non-empty
	for _, typ := range types {
		if typ == "" {
			t.Errorf("empty PB-06 message type")
		}
	}

	// Check distinct from all existing types
	allTypes := []string{
		MsgCallInitiate, MsgCallAccept, MsgCallReject, MsgCallEnd,
		MsgCallCancel, MsgICECandidate, MsgQualityMetrics, MsgPing,
		MsgReconnect,
		MsgIncomingCall, MsgCallAccepted, MsgCallRejected, MsgCallEnded,
		MsgCallCancelled, MsgError, MsgPong,
		MsgSessionResumed, MsgPeerReconnecting, MsgPeerReconnected,
		MsgCallGlare, MsgCallAcceptedElsewhere, MsgStateSync,
		MsgRoomCreate, MsgRoomInvite, MsgRoomJoin, MsgRoomLeave,
		MsgRoomCreated, MsgRoomInvitation, MsgRoomClosed,
		MsgParticipantJoined, MsgParticipantLeft, MsgParticipantMediaChanged,
	}

	seen := make(map[string]bool)
	for _, typ := range allTypes {
		if seen[typ] {
			t.Errorf("duplicate message type: %s", typ)
		}
		seen[typ] = true
	}
}

// --- SendJSONWithSeq via Client ---

func TestClient_SendJSONWithSeq(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)
	c := newTestClient(h, "alice", "phone")

	err := c.SendJSONWithSeq("test_type", map[string]string{"hello": "world"}, 99)
	if err != nil {
		t.Fatalf("SendJSONWithSeq error: %v", err)
	}

	msgs := drainMessages(c)
	if len(msgs) != 1 {
		t.Fatalf("expected 1 message, got %d", len(msgs))
	}

	if msgs[0].Type != "test_type" {
		t.Errorf("expected test_type, got %s", msgs[0].Type)
	}
	if msgs[0].Seq != 99 {
		t.Errorf("expected seq 99, got %d", msgs[0].Seq)
	}
}

func TestClient_SendJSON_DelegatesToSeqZero(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)
	c := newTestClient(h, "alice", "phone")

	c.SendJSON("ping", nil)

	msgs := drainMessages(c)
	if len(msgs) != 1 {
		t.Fatalf("expected 1 message, got %d", len(msgs))
	}

	// SendJSON uses seq=0, which is omitted
	if msgs[0].Seq != 0 {
		t.Errorf("expected seq 0 from SendJSON, got %d", msgs[0].Seq)
	}
}
