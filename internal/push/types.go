// Package push implements the Push Gateway Service for delivering
// incoming call notifications to offline/background mobile clients.
// It supports APNs VoIP push (iOS) and FCM data messages (Android).
package push

import (
	"time"
)

// Platform represents a mobile platform.
type Platform string

const (
	PlatformIOS     Platform = "ios"
	PlatformAndroid Platform = "android"
)

// DeliveryStatus represents the delivery state of a push notification.
type DeliveryStatus string

const (
	DeliveryStatusSent      DeliveryStatus = "sent"
	DeliveryStatusDelivered DeliveryStatus = "delivered"
	DeliveryStatusFailed    DeliveryStatus = "failed"
)

// PushToken represents a registered device push token.
type PushToken struct {
	ID         string    `json:"id" db:"id"`
	UserID     string    `json:"user_id" db:"user_id"`
	DeviceID   string    `json:"device_id" db:"device_id"`
	Platform   Platform  `json:"platform" db:"platform"`
	PushToken  string    `json:"push_token" db:"push_token"`
	VoIPToken  string    `json:"voip_token,omitempty" db:"voip_token"` // iOS PushKit only
	AppVersion string    `json:"app_version,omitempty" db:"app_version"`
	BundleID   string    `json:"bundle_id,omitempty" db:"bundle_id"`
	IsActive   bool      `json:"is_active" db:"is_active"`
	CreatedAt  time.Time `json:"created_at" db:"created_at"`
	UpdatedAt  time.Time `json:"updated_at" db:"updated_at"`
}

// RegisterRequest is the payload for push token registration.
type RegisterRequest struct {
	DeviceID   string   `json:"device_id"`
	Platform   Platform `json:"platform"`
	PushToken  string   `json:"push_token"`
	VoIPToken  string   `json:"voip_token,omitempty"` // iOS only
	AppVersion string   `json:"app_version,omitempty"`
	BundleID   string   `json:"bundle_id,omitempty"`
}

// UnregisterRequest is the payload for push token removal.
type UnregisterRequest struct {
	DeviceID string `json:"device_id"`
}

// IncomingCallPush is the push notification payload for an incoming call.
type IncomingCallPush struct {
	CallID          string `json:"call_id"`
	CallerID        string `json:"caller_id"`
	CallerName      string `json:"caller_name"`
	CallerAvatarURL string `json:"caller_avatar_url,omitempty"`
	CallType        string `json:"call_type"` // "audio" or "video"
	Timestamp       int64  `json:"timestamp"`
	TTL             int    `json:"ttl"` // seconds
}

// DeliveryResult tracks the outcome of sending a push to a single device.
type DeliveryResult struct {
	DeviceID  string         `json:"device_id"`
	Platform  Platform       `json:"platform"`
	Status    DeliveryStatus `json:"status"`
	Error     string         `json:"error,omitempty"`
	SentAt    time.Time      `json:"sent_at"`
}

// PushResult is the aggregate result of sending push to all devices of a user.
type PushResult struct {
	UserID   string           `json:"user_id"`
	CallID   string           `json:"call_id"`
	Devices  []DeliveryResult `json:"devices"`
	AllFailed bool            `json:"all_failed"`
}

// Validate checks that a RegisterRequest has all required fields.
func (r *RegisterRequest) Validate() error {
	if r.DeviceID == "" {
		return ErrMissingDeviceID
	}
	if r.PushToken == "" {
		return ErrMissingPushToken
	}
	if r.Platform != PlatformIOS && r.Platform != PlatformAndroid {
		return ErrInvalidPlatform
	}
	return nil
}
