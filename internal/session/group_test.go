package session

import (
	"encoding/json"
	"testing"
	"time"
)

func TestCreateGroupRequest(t *testing.T) {
	req := CreateGroupRequest{
		InitiatorID:  "user-host",
		Participants: []string{"user-a", "user-b", "user-c"},
		CallType:     "video",
		Region:       "us-west-2",
	}

	if req.InitiatorID != "user-host" {
		t.Errorf("expected user-host, got %s", req.InitiatorID)
	}
	if len(req.Participants) != 3 {
		t.Errorf("expected 3 participants, got %d", len(req.Participants))
	}
}

func TestCreateGroupResponse(t *testing.T) {
	resp := CreateGroupResponse{
		RoomID:       "room-123",
		Topology:     TopologySFU,
		LiveKitToken: "token-abc",
		LiveKitURL:   "ws://localhost:7880",
		Participants: []string{"user-a", "user-b"},
	}

	data, err := json.Marshal(resp)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded CreateGroupResponse
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.RoomID != "room-123" {
		t.Errorf("expected room-123, got %s", decoded.RoomID)
	}
	if decoded.Topology != TopologySFU {
		t.Errorf("expected SFU, got %s", decoded.Topology)
	}
	if len(decoded.Participants) != 2 {
		t.Errorf("expected 2 participants, got %d", len(decoded.Participants))
	}
}

func TestInviteToRoomResponse(t *testing.T) {
	resp := InviteToRoomResponse{
		Invited: []string{"user-a", "user-b"},
		Skipped: []string{"user-c"},
	}

	data, err := json.Marshal(resp)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded InviteToRoomResponse
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if len(decoded.Invited) != 2 {
		t.Errorf("expected 2 invited, got %d", len(decoded.Invited))
	}
	if len(decoded.Skipped) != 1 {
		t.Errorf("expected 1 skipped, got %d", len(decoded.Skipped))
	}
}

func TestGroupSessionType(t *testing.T) {
	// Group sessions always use SFU
	sess := Session{
		CallID:      "room-001",
		CallType:    "group",
		Topology:    TopologySFU,
		InitiatorID: "user-host",
		HasVideo:    true,
		Participants: []Participant{
			{UserID: "user-host", Role: RoleCaller, JoinedAt: time.Now()},
			{UserID: "user-a", Role: RoleParticipant, JoinedAt: time.Now()},
			{UserID: "user-b", Role: RoleParticipant, JoinedAt: time.Now()},
		},
		CreatedAt: time.Now(),
	}

	if sess.CallType != "group" {
		t.Errorf("expected group, got %s", sess.CallType)
	}
	if sess.Topology != TopologySFU {
		t.Errorf("expected SFU, got %s", sess.Topology)
	}

	active := sess.ActiveParticipants()
	if len(active) != 3 {
		t.Errorf("expected 3 active participants, got %d", len(active))
	}

	// Find host
	host := sess.FindParticipant("user-host")
	if host == nil {
		t.Fatal("host not found")
	}
	if host.Role != RoleCaller {
		t.Errorf("expected host role=caller, got %s", host.Role)
	}
}

func TestGroupMaxParticipants(t *testing.T) {
	maxP := 8
	participants := make([]Participant, maxP)
	for i := 0; i < maxP; i++ {
		participants[i] = Participant{
			UserID:   "user-" + string(rune('A'+i)),
			Role:     RoleParticipant,
			JoinedAt: time.Now(),
		}
	}
	participants[0].Role = RoleCaller

	sess := Session{
		CallID:       "room-full",
		CallType:     "group",
		Topology:     TopologySFU,
		Participants: participants,
	}

	active := sess.ActiveParticipants()
	if len(active) != maxP {
		t.Errorf("expected %d active, got %d", maxP, len(active))
	}
}

func TestGroupLeaveAndAutoClose(t *testing.T) {
	now := time.Now()
	sess := Session{
		CallID:      "room-leave",
		CallType:    "group",
		Topology:    TopologySFU,
		InitiatorID: "user-host",
		Participants: []Participant{
			{UserID: "user-host", Role: RoleCaller, JoinedAt: now, LeftAt: now.Add(5 * time.Minute)},
			{UserID: "user-a", Role: RoleParticipant, JoinedAt: now, LeftAt: now.Add(3 * time.Minute)},
		},
	}

	active := sess.ActiveParticipants()
	if len(active) != 0 {
		t.Errorf("expected 0 active after all left, got %d", len(active))
	}
}

func TestHostPermissions(t *testing.T) {
	// Host (RoleCaller) should have invite permission
	if err := CheckPermission(RoleCaller, PermInvite); err != nil {
		t.Errorf("host should have invite permission: %v", err)
	}

	// Participant should NOT have invite permission
	if err := CheckPermission(RoleParticipant, PermInvite); err == nil {
		t.Error("participant should NOT have invite permission")
	}

	// Host should have remove-other permission
	if err := CheckPermission(RoleCaller, PermRemoveOther); err != nil {
		t.Errorf("host should have remove-other permission: %v", err)
	}

	// Participant should NOT have remove-other permission
	if err := CheckPermission(RoleParticipant, PermRemoveOther); err == nil {
		t.Error("participant should NOT have remove-other permission")
	}
}
