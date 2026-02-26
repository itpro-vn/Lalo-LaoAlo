package models

import "testing"

func TestRedisKeys(t *testing.T) {
	tests := []struct {
		name     string
		fn       func() string
		expected string
	}{
		{"SessionKey", func() string { return SessionKey("abc-123") }, "session:abc-123"},
		{"SessionParticipantsKey", func() string { return SessionParticipantsKey("abc-123") }, "session:abc-123:participants"},
		{"UserActiveCallKey", func() string { return UserActiveCallKey("user-1") }, "user:user-1:active_call"},
		{"PresenceKey", func() string { return PresenceKey("user-1") }, "presence:user-1"},
		{"TurnCredentialsKey", func() string { return TurnCredentialsKey("sess-1") }, "turn:creds:sess-1"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.fn()
			if got != tt.expected {
				t.Errorf("got %q, want %q", got, tt.expected)
			}
		})
	}
}

func TestRedisKeyTTLs(t *testing.T) {
	if SessionTTL != 86400 {
		t.Errorf("SessionTTL = %d, want 86400", SessionTTL)
	}
	if PresenceTTL != 300 {
		t.Errorf("PresenceTTL = %d, want 300", PresenceTTL)
	}
	if TurnCredsTTL != 600 {
		t.Errorf("TurnCredsTTL = %d, want 600", TurnCredsTTL)
	}
}
