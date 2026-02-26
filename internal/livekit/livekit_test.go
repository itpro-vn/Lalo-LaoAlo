package livekit

import (
	"encoding/json"
	"testing"

	"github.com/minhgv/lalo/internal/events"
)

func TestDefaultMediaConfig(t *testing.T) {
	mc := DefaultMediaConfig()

	if mc.AudioCodec != "opus" {
		t.Errorf("expected audio codec opus, got %s", mc.AudioCodec)
	}
	if len(mc.VideoCodecs) != 2 {
		t.Fatalf("expected 2 video codecs, got %d", len(mc.VideoCodecs))
	}
	if mc.VideoCodecs[0] != "vp8" || mc.VideoCodecs[1] != "h264" {
		t.Errorf("expected video codecs [vp8 h264], got %v", mc.VideoCodecs)
	}
	if mc.SimulcastLayers != 3 {
		t.Errorf("expected 3 simulcast layers, got %d", mc.SimulcastLayers)
	}
	if mc.MaxResolution != "720p" {
		t.Errorf("expected max resolution 720p, got %s", mc.MaxResolution)
	}
	if mc.MaxFramerate != 30 {
		t.Errorf("expected max framerate 30, got %d", mc.MaxFramerate)
	}
}

func TestMediaConfigString(t *testing.T) {
	mc := DefaultMediaConfig()
	s := mc.String()
	if s == "" {
		t.Error("expected non-empty string representation")
	}
	// Should contain key info
	if !containsStr(s, "opus") || !containsStr(s, "720p") || !containsStr(s, "30") {
		t.Errorf("media config string missing expected content: %s", s)
	}
}

func TestSFUParticipantEventJSON(t *testing.T) {
	evt := SFUParticipantEvent{
		RoomName:       "call-123",
		Identity:       "user-456",
		ParticipantSID: "PA_abc",
		JoinedAt:       1700000000,
	}

	data, err := json.Marshal(evt)
	if err != nil {
		t.Fatalf("failed to marshal: %v", err)
	}

	var decoded SFUParticipantEvent
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("failed to unmarshal: %v", err)
	}

	if decoded.RoomName != evt.RoomName {
		t.Errorf("room_name mismatch: got %s", decoded.RoomName)
	}
	if decoded.Identity != evt.Identity {
		t.Errorf("identity mismatch: got %s", decoded.Identity)
	}
	if decoded.ParticipantSID != evt.ParticipantSID {
		t.Errorf("participant_sid mismatch: got %s", decoded.ParticipantSID)
	}
	if decoded.JoinedAt != evt.JoinedAt {
		t.Errorf("joined_at mismatch: got %d", decoded.JoinedAt)
	}
}

func TestSFURoomEventJSON(t *testing.T) {
	evt := SFURoomEvent{
		RoomName: "call-789",
		RoomSID:  "RM_xyz",
	}

	data, err := json.Marshal(evt)
	if err != nil {
		t.Fatalf("failed to marshal: %v", err)
	}

	var decoded SFURoomEvent
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("failed to unmarshal: %v", err)
	}

	if decoded.RoomName != evt.RoomName || decoded.RoomSID != evt.RoomSID {
		t.Errorf("room event mismatch: got %+v", decoded)
	}
}

func TestSFUTrackEventJSON(t *testing.T) {
	evt := SFUTrackEvent{
		RoomName:  "call-123",
		Identity:  "user-456",
		TrackSID:  "TR_abc",
		TrackType: "AUDIO",
		Simulcast: true,
	}

	data, err := json.Marshal(evt)
	if err != nil {
		t.Fatalf("failed to marshal: %v", err)
	}

	var decoded SFUTrackEvent
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("failed to unmarshal: %v", err)
	}

	if decoded.TrackSID != evt.TrackSID {
		t.Errorf("track_sid mismatch: got %s", decoded.TrackSID)
	}
	if decoded.TrackType != "AUDIO" {
		t.Errorf("track_type mismatch: got %s", decoded.TrackType)
	}
	if !decoded.Simulcast {
		t.Error("expected simulcast=true")
	}
}

func TestSFUSubjects(t *testing.T) {
	subjects := []string{
		events.SubjectSFUParticipantJoined,
		events.SubjectSFUParticipantLeft,
		events.SubjectSFURoomFinished,
		events.SubjectSFUTrackPublished,
	}

	seen := make(map[string]bool)
	for _, s := range subjects {
		if s == "" {
			t.Error("empty subject found")
		}
		if seen[s] {
			t.Errorf("duplicate subject: %s", s)
		}
		seen[s] = true
	}
}

func TestCreateRoomRequestDefaults(t *testing.T) {
	req := CreateRoomRequest{
		RoomName: "test-room",
	}

	if req.MaxParticipants != 0 {
		t.Errorf("expected zero default for MaxParticipants, got %d", req.MaxParticipants)
	}
	if req.EmptyTimeout != 0 {
		t.Errorf("expected zero default for EmptyTimeout, got %d", req.EmptyTimeout)
	}
	// The CreateRoom method applies defaults — 0 → 8 for MaxParticipants, 0 → 300 for EmptyTimeout
}

func containsStr(s, sub string) bool {
	return len(s) >= len(sub) && (s == sub || len(s) > 0 && containsSubstring(s, sub))
}

func TestUpdateSubscriptionRequestFields(t *testing.T) {
	req := UpdateSubscriptionRequest{
		RoomName:  "call-room-1",
		Identity:  "user-abc",
		TrackSIDs: []string{"TR_001", "TR_002"},
		Subscribe: true,
	}

	if req.RoomName != "call-room-1" {
		t.Errorf("expected room name call-room-1, got %s", req.RoomName)
	}
	if req.Identity != "user-abc" {
		t.Errorf("expected identity user-abc, got %s", req.Identity)
	}
	if len(req.TrackSIDs) != 2 {
		t.Fatalf("expected 2 track SIDs, got %d", len(req.TrackSIDs))
	}
	if req.TrackSIDs[0] != "TR_001" || req.TrackSIDs[1] != "TR_002" {
		t.Errorf("unexpected track SIDs: %v", req.TrackSIDs)
	}
	if !req.Subscribe {
		t.Error("expected subscribe to be true")
	}
}

func TestSendDataRequestFields(t *testing.T) {
	req := SendDataRequest{
		RoomName:              "call-room-1",
		Payload:               []byte(`{"type":"layer_update","layer":"h"}`),
		DestinationIdentities: []string{"user-1", "user-2"},
		Reliable:              true,
	}

	if req.RoomName != "call-room-1" {
		t.Errorf("expected room name call-room-1, got %s", req.RoomName)
	}
	if string(req.Payload) != `{"type":"layer_update","layer":"h"}` {
		t.Errorf("unexpected payload: %s", string(req.Payload))
	}
	if len(req.DestinationIdentities) != 2 {
		t.Fatalf("expected 2 destination identities, got %d", len(req.DestinationIdentities))
	}
	if !req.Reliable {
		t.Error("expected reliable to be true")
	}
}

func TestUpdateSubscriptionRequestDefaultSubscribe(t *testing.T) {
	req := UpdateSubscriptionRequest{
		RoomName:  "call-room-1",
		Identity:  "user-abc",
		TrackSIDs: []string{"TR_001"},
	}

	// Default zero value for bool is false
	if req.Subscribe {
		t.Error("expected default subscribe to be false")
	}
}

func containsSubstring(s, sub string) bool {
	for i := 0; i <= len(s)-len(sub); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
