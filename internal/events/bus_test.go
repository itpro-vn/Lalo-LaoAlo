package events

import (
	"encoding/json"
	"testing"
	"time"
)

func TestEnvelopeSerialization(t *testing.T) {
	env := Envelope{
		ID:        "test-id-123",
		Type:      SubjectCallInitiated,
		Timestamp: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC),
		Source:    "signaling",
		Payload: CallInitiated{
			CallID:   "call-abc",
			CallerID: "user-1",
			CalleeID: "user-2",
			CallType: "1:1",
			HasVideo: true,
			Region:   "us-west-2",
		},
	}

	data, err := json.Marshal(env)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded Envelope
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.ID != env.ID {
		t.Errorf("ID: got %q, want %q", decoded.ID, env.ID)
	}
	if decoded.Type != SubjectCallInitiated {
		t.Errorf("Type: got %q, want %q", decoded.Type, SubjectCallInitiated)
	}
	if decoded.Source != "signaling" {
		t.Errorf("Source: got %q, want %q", decoded.Source, "signaling")
	}

	// Payload comes back as map[string]any from JSON
	payloadMap, ok := decoded.Payload.(map[string]any)
	if !ok {
		t.Fatalf("Payload type: got %T, want map[string]any", decoded.Payload)
	}
	if payloadMap["call_id"] != "call-abc" {
		t.Errorf("Payload.call_id: got %v, want call-abc", payloadMap["call_id"])
	}
	if payloadMap["has_video"] != true {
		t.Errorf("Payload.has_video: got %v, want true", payloadMap["has_video"])
	}
}

func TestCallInitiatedRoundtrip(t *testing.T) {
	original := CallInitiated{
		CallID:   "call-xyz",
		CallerID: "user-a",
		CalleeID: "user-b",
		CallType: "group",
		HasVideo: false,
		Region:   "eu-central-1",
	}

	data, err := json.Marshal(original)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded CallInitiated
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded != original {
		t.Errorf("roundtrip mismatch: got %+v, want %+v", decoded, original)
	}
}

func TestCallEndedRoundtrip(t *testing.T) {
	original := CallEnded{
		CallID:    "call-end-1",
		EndReason: "normal",
		Duration:  120,
	}

	data, err := json.Marshal(original)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded CallEnded
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded != original {
		t.Errorf("roundtrip mismatch: got %+v, want %+v", decoded, original)
	}
}

func TestQualityMetricsRoundtrip(t *testing.T) {
	original := QualityMetrics{
		CallID: "call-qos-1",
		Samples: []QualityMetricsSample{
			{
				ParticipantID: "user-1",
				RTTMs:         50,
				LossPct:       1.5,
				JitterMs:      10,
				BitrateKbps:   2500,
			},
			{
				ParticipantID: "user-2",
				RTTMs:         120,
				LossPct:       3.0,
				JitterMs:      25,
				BitrateKbps:   1200,
			},
		},
	}

	data, err := json.Marshal(original)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded QualityMetrics
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if len(decoded.Samples) != 2 {
		t.Fatalf("samples count: got %d, want 2", len(decoded.Samples))
	}
	if decoded.Samples[0].RTTMs != 50 {
		t.Errorf("sample[0].rtt_ms: got %d, want 50", decoded.Samples[0].RTTMs)
	}
	if decoded.Samples[1].LossPct != 3.0 {
		t.Errorf("sample[1].loss_pct: got %f, want 3.0", decoded.Samples[1].LossPct)
	}
}

func TestCallStateChangedRoundtrip(t *testing.T) {
	original := CallStateChanged{
		CallID:    "call-state-1",
		FromState: "ringing",
		ToState:   "active",
		Trigger:   "accept",
	}

	data, err := json.Marshal(original)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded CallStateChanged
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded != original {
		t.Errorf("roundtrip mismatch: got %+v, want %+v", decoded, original)
	}
}

func TestPresenceUpdatedRoundtrip(t *testing.T) {
	original := PresenceUpdated{
		UserID:   "user-presence-1",
		Status:   "online",
		DeviceID: "device-abc",
	}

	data, err := json.Marshal(original)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded PresenceUpdated
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded != original {
		t.Errorf("roundtrip mismatch: got %+v, want %+v", decoded, original)
	}
}

func TestRoomCreatedRoundtrip(t *testing.T) {
	original := RoomCreated{
		RoomID:       "room-abc",
		InitiatorID:  "user-1",
		CallType:     "video",
		Participants: []string{"user-2", "user-3"},
	}

	data, err := json.Marshal(original)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded RoomCreated
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.RoomID != original.RoomID || decoded.InitiatorID != original.InitiatorID {
		t.Errorf("roundtrip mismatch: got %+v, want %+v", decoded, original)
	}
	if len(decoded.Participants) != 2 {
		t.Errorf("expected 2 participants, got %d", len(decoded.Participants))
	}
}

func TestRoomClosedRoundtrip(t *testing.T) {
	original := RoomClosed{
		RoomID:   "room-xyz",
		Reason:   "all_left",
		Duration: 300,
	}

	data, err := json.Marshal(original)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded RoomClosed
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded != original {
		t.Errorf("roundtrip mismatch: got %+v, want %+v", decoded, original)
	}
}

func TestRoomParticipantRoundtrips(t *testing.T) {
	joined := RoomParticipantJoined{
		RoomID: "room-1",
		UserID: "user-2",
		Role:   "participant",
	}
	data, _ := json.Marshal(joined)
	var decodedJ RoomParticipantJoined
	json.Unmarshal(data, &decodedJ)
	if decodedJ != joined {
		t.Errorf("joined roundtrip mismatch: got %+v, want %+v", decodedJ, joined)
	}

	left := RoomParticipantLeft{
		RoomID: "room-1",
		UserID: "user-3",
	}
	data, _ = json.Marshal(left)
	var decodedL RoomParticipantLeft
	json.Unmarshal(data, &decodedL)
	if decodedL != left {
		t.Errorf("left roundtrip mismatch: got %+v, want %+v", decodedL, left)
	}
}

func TestAllSubjects(t *testing.T) {
	subjects := AllSubjects()
	if len(subjects) != 17 {
		t.Errorf("expected 17 subjects, got %d", len(subjects))
	}

	// Verify all expected subjects are present
	expected := map[string]bool{
		SubjectCallInitiated:      false,
		SubjectCallAccepted:       false,
		SubjectCallRejected:       false,
		SubjectCallEnded:          false,
		SubjectCallStateChanged:   false,
		SubjectQualityTierChanged: false,
		SubjectQualityMetrics:     false,
		SubjectPresenceUpdated:    false,
		SubjectSFUParticipantJoined: false,
		SubjectSFUParticipantLeft:   false,
		SubjectSFURoomFinished:      false,
		SubjectSFUTrackPublished:    false,
		SubjectPushDelivery:         false,
		SubjectRoomCreated:            false,
		SubjectRoomClosed:             false,
		SubjectRoomParticipantJoined:  false,
		SubjectRoomParticipantLeft:    false,
	}
	for _, s := range subjects {
		if _, ok := expected[s]; !ok {
			t.Errorf("unexpected subject: %s", s)
		}
		expected[s] = true
	}
	for s, found := range expected {
		if !found {
			t.Errorf("missing subject: %s", s)
		}
	}
}
