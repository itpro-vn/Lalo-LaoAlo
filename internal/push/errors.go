package push

import "errors"

// Sentinel errors for the push package.
var (
	ErrMissingDeviceID  = errors.New("device_id is required")
	ErrMissingPushToken = errors.New("push_token is required")
	ErrInvalidPlatform  = errors.New("platform must be 'ios' or 'android'")
	ErrTokenNotFound    = errors.New("push token not found")
	ErrNoActiveTokens   = errors.New("no active push tokens for user")
)
