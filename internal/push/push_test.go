package push

import (
	"encoding/json"
	"testing"
	"time"
)

func TestRegisterRequestValidate(t *testing.T) {
	tests := []struct {
		name    string
		req     RegisterRequest
		wantErr error
	}{
		{
			name:    "valid iOS",
			req:     RegisterRequest{DeviceID: "dev-1", Platform: PlatformIOS, PushToken: "abc123"},
			wantErr: nil,
		},
		{
			name:    "valid Android",
			req:     RegisterRequest{DeviceID: "dev-2", Platform: PlatformAndroid, PushToken: "xyz789"},
			wantErr: nil,
		},
		{
			name:    "missing device_id",
			req:     RegisterRequest{Platform: PlatformIOS, PushToken: "abc"},
			wantErr: ErrMissingDeviceID,
		},
		{
			name:    "missing push_token",
			req:     RegisterRequest{DeviceID: "dev-1", Platform: PlatformIOS},
			wantErr: ErrMissingPushToken,
		},
		{
			name:    "invalid platform",
			req:     RegisterRequest{DeviceID: "dev-1", Platform: "web", PushToken: "abc"},
			wantErr: ErrInvalidPlatform,
		},
		{
			name:    "empty platform",
			req:     RegisterRequest{DeviceID: "dev-1", PushToken: "abc"},
			wantErr: ErrInvalidPlatform,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.req.Validate()
			if err != tt.wantErr {
				t.Errorf("Validate() = %v, want %v", err, tt.wantErr)
			}
		})
	}
}

func TestPushTokenJSON(t *testing.T) {
	token := PushToken{
		ID:        "tok-id-1",
		UserID:    "user-1",
		DeviceID:  "iphone-14",
		Platform:  PlatformIOS,
		PushToken: "apns-token-abc",
		VoIPToken: "voip-token-xyz",
		IsActive:  true,
		CreatedAt: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC),
		UpdatedAt: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC),
	}

	data, err := json.Marshal(token)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded PushToken
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.UserID != "user-1" {
		t.Errorf("UserID: got %q, want user-1", decoded.UserID)
	}
	if decoded.Platform != PlatformIOS {
		t.Errorf("Platform: got %q, want ios", decoded.Platform)
	}
	if decoded.VoIPToken != "voip-token-xyz" {
		t.Errorf("VoIPToken: got %q, want voip-token-xyz", decoded.VoIPToken)
	}
}

func TestIncomingCallPushJSON(t *testing.T) {
	push := IncomingCallPush{
		CallID:          "call-123",
		CallerID:        "user-a",
		CallerName:      "Nguyễn Văn A",
		CallerAvatarURL: "https://example.com/avatar.jpg",
		CallType:        "video",
		Timestamp:       1708876543,
		TTL:             45,
	}

	data, err := json.Marshal(push)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded IncomingCallPush
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.CallID != "call-123" {
		t.Errorf("CallID: got %q, want call-123", decoded.CallID)
	}
	if decoded.CallerName != "Nguyễn Văn A" {
		t.Errorf("CallerName: got %q, want Nguyễn Văn A", decoded.CallerName)
	}
	if decoded.CallType != "video" {
		t.Errorf("CallType: got %q, want video", decoded.CallType)
	}
	if decoded.TTL != 45 {
		t.Errorf("TTL: got %d, want 45", decoded.TTL)
	}
}

func TestDeliveryResultJSON(t *testing.T) {
	dr := DeliveryResult{
		DeviceID: "dev-1",
		Platform: PlatformAndroid,
		Status:   DeliveryStatusSent,
		SentAt:   time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC),
	}

	data, err := json.Marshal(dr)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded DeliveryResult
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.Status != DeliveryStatusSent {
		t.Errorf("Status: got %q, want sent", decoded.Status)
	}
	if decoded.Platform != PlatformAndroid {
		t.Errorf("Platform: got %q, want android", decoded.Platform)
	}
}

func TestDeliveryResultFailedJSON(t *testing.T) {
	dr := DeliveryResult{
		DeviceID: "dev-2",
		Platform: PlatformIOS,
		Status:   DeliveryStatusFailed,
		Error:    "APNs token invalid (410 Gone)",
		SentAt:   time.Now(),
	}

	data, err := json.Marshal(dr)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded DeliveryResult
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.Error != "APNs token invalid (410 Gone)" {
		t.Errorf("Error: got %q", decoded.Error)
	}
}

func TestPushResultAllFailed(t *testing.T) {
	result := PushResult{
		UserID:    "user-1",
		CallID:    "call-1",
		AllFailed: true,
		Devices: []DeliveryResult{
			{DeviceID: "dev-1", Status: DeliveryStatusFailed, Error: "timeout"},
			{DeviceID: "dev-2", Status: DeliveryStatusFailed, Error: "invalid token"},
		},
	}

	if !result.AllFailed {
		t.Error("expected AllFailed=true")
	}
	if len(result.Devices) != 2 {
		t.Errorf("expected 2 devices, got %d", len(result.Devices))
	}
}

func TestIsGoneError(t *testing.T) {
	tests := []struct {
		err  error
		want bool
	}{
		{nil, false},
		{ErrMissingDeviceID, false},
		{ErrNoActiveTokens, false},
	}

	for _, tt := range tests {
		if got := IsGoneError(tt.err); got != tt.want {
			t.Errorf("IsGoneError(%v) = %v, want %v", tt.err, got, tt.want)
		}
	}
}

func TestIsUnregisteredError(t *testing.T) {
	tests := []struct {
		err  error
		want bool
	}{
		{nil, false},
		{ErrMissingDeviceID, false},
	}

	for _, tt := range tests {
		if got := IsUnregisteredError(tt.err); got != tt.want {
			t.Errorf("IsUnregisteredError(%v) = %v, want %v", tt.err, got, tt.want)
		}
	}
}

func TestPlatformConstants(t *testing.T) {
	if PlatformIOS != "ios" {
		t.Errorf("PlatformIOS: got %q, want ios", PlatformIOS)
	}
	if PlatformAndroid != "android" {
		t.Errorf("PlatformAndroid: got %q, want android", PlatformAndroid)
	}
}

func TestDeliveryStatusConstants(t *testing.T) {
	if DeliveryStatusSent != "sent" {
		t.Errorf("DeliveryStatusSent: got %q", DeliveryStatusSent)
	}
	if DeliveryStatusDelivered != "delivered" {
		t.Errorf("DeliveryStatusDelivered: got %q", DeliveryStatusDelivered)
	}
	if DeliveryStatusFailed != "failed" {
		t.Errorf("DeliveryStatusFailed: got %q", DeliveryStatusFailed)
	}
}

func TestGatewayConfigDefaults(t *testing.T) {
	gw := NewGateway(nil, nil, nil, nil, GatewayConfig{})
	if gw.ringTTL != 45 {
		t.Errorf("default ringTTL: got %d, want 45", gw.ringTTL)
	}
}

func TestGatewayConfigCustomTTL(t *testing.T) {
	gw := NewGateway(nil, nil, nil, nil, GatewayConfig{RingTimeoutSeconds: 60})
	if gw.ringTTL != 60 {
		t.Errorf("custom ringTTL: got %d, want 60", gw.ringTTL)
	}
}

func TestFCMMessageFormat(t *testing.T) {
	// Verify FCM uses data-only messages (not notification)
	payload := &IncomingCallPush{
		CallID:     "call-fcm-1",
		CallerID:   "user-a",
		CallerName: "Test User",
		CallType:   "audio",
		Timestamp:  1708876543,
		TTL:        45,
	}

	msg := fcmMessage{
		To:       "fcm-token-abc",
		Priority: "high",
		TTL:      "45",
		Data: map[string]string{
			"type":        "incoming_call",
			"call_id":     payload.CallID,
			"caller_id":   payload.CallerID,
			"caller_name": payload.CallerName,
			"call_type":   payload.CallType,
		},
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	// Verify no "notification" field exists (data-only message)
	var rawMsg map[string]any
	json.Unmarshal(data, &rawMsg)

	if _, hasNotif := rawMsg["notification"]; hasNotif {
		t.Error("FCM message MUST NOT contain 'notification' field — use data-only messages")
	}
	if rawMsg["priority"] != "high" {
		t.Errorf("FCM priority: got %v, want high", rawMsg["priority"])
	}
	if _, hasData := rawMsg["data"]; !hasData {
		t.Error("FCM message MUST contain 'data' field")
	}
}
