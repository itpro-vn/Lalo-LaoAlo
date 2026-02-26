package session

import (
	"testing"
	"time"
)

// --- Topology Tests ---

func TestDecideTopology(t *testing.T) {
	tests := []struct {
		name     string
		count    int
		expected Topology
	}{
		{"1 participant", 1, TopologyP2P},
		{"2 participants", 2, TopologyP2P},
		{"3 participants", 3, TopologySFU},
		{"8 participants", 8, TopologySFU},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := DecideTopology(tt.count)
			if got != tt.expected {
				t.Errorf("DecideTopology(%d) = %s, want %s", tt.count, got, tt.expected)
			}
		})
	}
}

func TestShouldEscalateToSFU(t *testing.T) {
	tests := []struct {
		name      string
		topology  Topology
		newCount  int
		expected  bool
	}{
		{"P2P with 2", TopologyP2P, 2, false},
		{"P2P with 3", TopologyP2P, 3, true},
		{"TURN with 3", TopologyTURN, 3, true},
		{"SFU with 4", TopologySFU, 4, false}, // already SFU
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ShouldEscalateToSFU(tt.topology, tt.newCount)
			if got != tt.expected {
				t.Errorf("ShouldEscalateToSFU(%s, %d) = %v, want %v", tt.topology, tt.newCount, got, tt.expected)
			}
		})
	}
}

func TestShouldFallbackToTURN(t *testing.T) {
	tests := []struct {
		name      string
		topology  Topology
		iceFailed bool
		expected  bool
	}{
		{"P2P with ICE failed", TopologyP2P, true, true},
		{"P2P without ICE fail", TopologyP2P, false, false},
		{"SFU with ICE failed", TopologySFU, true, false},
		{"TURN with ICE failed", TopologyTURN, true, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ShouldFallbackToTURN(tt.topology, tt.iceFailed)
			if got != tt.expected {
				t.Errorf("ShouldFallbackToTURN(%s, %v) = %v, want %v", tt.topology, tt.iceFailed, got, tt.expected)
			}
		})
	}
}

// --- Permission Tests ---

func TestHasPermission(t *testing.T) {
	tests := []struct {
		name     string
		role     Role
		perm     Permission
		expected bool
	}{
		// Caller permissions
		{"caller can initiate", RoleCaller, PermInitiateCall, true},
		{"caller can end", RoleCaller, PermEndCall, true},
		{"caller can mute self", RoleCaller, PermMuteSelf, true},
		{"caller can invite", RoleCaller, PermInvite, true},
		{"caller can remove other", RoleCaller, PermRemoveOther, true},
		{"caller can mute other", RoleCaller, PermMuteOther, true},
		{"caller cannot accept", RoleCaller, PermAcceptCall, false},

		// Callee permissions
		{"callee can accept", RoleCallee, PermAcceptCall, true},
		{"callee can reject", RoleCallee, PermRejectCall, true},
		{"callee can end", RoleCallee, PermEndCall, true},
		{"callee cannot initiate", RoleCallee, PermInitiateCall, false},
		{"callee cannot invite", RoleCallee, PermInvite, false},
		{"callee cannot remove other", RoleCallee, PermRemoveOther, false},

		// Participant permissions
		{"participant can accept", RoleParticipant, PermAcceptCall, true},
		{"participant can mute self", RoleParticipant, PermMuteSelf, true},
		{"participant cannot invite", RoleParticipant, PermInvite, false},
		{"participant cannot remove other", RoleParticipant, PermRemoveOther, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := HasPermission(tt.role, tt.perm)
			if got != tt.expected {
				t.Errorf("HasPermission(%s, %s) = %v, want %v", tt.role, tt.perm, got, tt.expected)
			}
		})
	}
}

func TestCheckPermission(t *testing.T) {
	// Should succeed
	if err := CheckPermission(RoleCaller, PermEndCall); err != nil {
		t.Errorf("unexpected error: %v", err)
	}

	// Should fail
	if err := CheckPermission(RoleCallee, PermRemoveOther); err == nil {
		t.Error("expected permission denied error")
	}

	// Unknown role
	if HasPermission(Role("unknown"), PermEndCall) {
		t.Error("expected false for unknown role")
	}
}

func TestGroupPermissions(t *testing.T) {
	// In group calls, everyone can invite
	if !GroupPermissions(RoleCallee, PermInvite) {
		t.Error("callee should be able to invite in group calls")
	}
	if !GroupPermissions(RoleParticipant, PermInvite) {
		t.Error("participant should be able to invite in group calls")
	}

	// Other permissions unchanged
	if GroupPermissions(RoleParticipant, PermRemoveOther) {
		t.Error("participant should not be able to remove others even in group")
	}
}

// --- Session/Types Tests ---

func TestSessionActiveParticipants(t *testing.T) {
	now := time.Now()
	sess := &Session{
		CallID:   "test-call",
		CallType: "group",
		Participants: []Participant{
			{UserID: "user1", JoinedAt: now},
			{UserID: "user2", JoinedAt: now, LeftAt: now.Add(1 * time.Minute)},
			{UserID: "user3", JoinedAt: now},
		},
	}

	active := sess.ActiveParticipants()
	if len(active) != 2 {
		t.Errorf("expected 2 active participants, got %d", len(active))
	}
}

func TestSessionFindParticipant(t *testing.T) {
	sess := &Session{
		Participants: []Participant{
			{UserID: "user1"},
			{UserID: "user2"},
		},
	}

	p := sess.FindParticipant("user1")
	if p == nil || p.UserID != "user1" {
		t.Error("expected to find user1")
	}

	p = sess.FindParticipant("nonexistent")
	if p != nil {
		t.Error("expected nil for nonexistent user")
	}
}

// --- CDR Tests ---

func TestGenerateCDR(t *testing.T) {
	start := time.Now().Add(-5 * time.Minute)
	end := time.Now()

	sess := &Session{
		CallID:      "call-123",
		CallType:    "1:1",
		Topology:    TopologyP2P,
		InitiatorID: "user1",
		Region:      "us-east-1",
		HasVideo:    true,
		CreatedAt:   start,
		EndedAt:     end,
		EndReason:   "normal",
		Participants: []Participant{
			{UserID: "user1", Role: RoleCaller},
			{UserID: "user2", Role: RoleCallee},
		},
	}

	cdr := GenerateCDR(sess)

	if cdr.CallID != "call-123" {
		t.Errorf("expected call_id=call-123, got %s", cdr.CallID)
	}
	if cdr.CallType != "1:1" {
		t.Errorf("expected call_type=1:1, got %s", cdr.CallType)
	}
	if cdr.Topology != "p2p" {
		t.Errorf("expected topology=p2p, got %s", cdr.Topology)
	}
	if cdr.DurationSeconds < 290 || cdr.DurationSeconds > 310 {
		t.Errorf("expected duration ~300s, got %d", cdr.DurationSeconds)
	}
	if cdr.ParticipantCount != 2 {
		t.Errorf("expected 2 participants, got %d", cdr.ParticipantCount)
	}
	if !cdr.HasVideo {
		t.Error("expected has_video=true")
	}
}

func TestGenerateCDR_ZeroDuration(t *testing.T) {
	sess := &Session{
		CallID:    "call-456",
		CreatedAt: time.Now(),
		// EndedAt is zero
	}

	cdr := GenerateCDR(sess)
	if cdr.DurationSeconds != 0 {
		t.Errorf("expected 0 duration for unended call, got %d", cdr.DurationSeconds)
	}
}
