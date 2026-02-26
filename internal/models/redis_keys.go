// Package models defines shared domain types and Redis key conventions
// used across all Lalo services.
package models

import "fmt"

// Redis key prefixes and patterns.
// TTL conventions:
//   - session keys: 24h (cleanup fallback)
//   - presence keys: 5 min auto-refresh
//   - turn credential keys: per config (default 10 min)

// SessionKey returns the hash key for call session state.
//
//	Fields: state, type, topology, created_at, initiator_id, region
func SessionKey(callID string) string {
	return fmt.Sprintf("session:%s", callID)
}

// SessionParticipantsKey returns the set key for call participants.
//
//	Members: user_id values
func SessionParticipantsKey(callID string) string {
	return fmt.Sprintf("session:%s:participants", callID)
}

// UserActiveCallKey returns the string key for a user's active call.
//
//	Value: call_id or empty
func UserActiveCallKey(userID string) string {
	return fmt.Sprintf("user:%s:active_call", userID)
}

// PresenceKey returns the hash key for user presence.
//
//	Fields: status, last_seen, device_id
func PresenceKey(userID string) string {
	return fmt.Sprintf("presence:%s", userID)
}

// TurnCredentialsKey returns the hash key for TURN credentials.
//
//	Fields: username, password, ttl
func TurnCredentialsKey(sessionID string) string {
	return fmt.Sprintf("turn:creds:%s", sessionID)
}

// Redis TTL constants (in seconds).
const (
	SessionTTL    = 24 * 60 * 60 // 24 hours
	PresenceTTL   = 5 * 60       // 5 minutes
	TurnCredsTTL  = 10 * 60      // 10 minutes (default, overridden by config)
)
