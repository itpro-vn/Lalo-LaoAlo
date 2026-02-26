package auth

import (
	"time"

	"github.com/livekit/protocol/auth"
)

// LiveKitTokenService generates LiveKit room access tokens.
type LiveKitTokenService struct {
	apiKey    string
	apiSecret string
}

// NewLiveKitTokenService creates a new LiveKit token service.
func NewLiveKitTokenService(apiKey, apiSecret string) *LiveKitTokenService {
	return &LiveKitTokenService{
		apiKey:    apiKey,
		apiSecret: apiSecret,
	}
}

// RoomPermissions defines what a participant can do in a LiveKit room.
type RoomPermissions struct {
	RoomName       string
	Identity       string
	CanPublish     bool
	CanSubscribe   bool
	CanPublishData bool
}

// GenerateRoomToken creates a LiveKit access token with the specified permissions.
// The token expiry is set to the given duration + 5 minute buffer.
func (s *LiveKitTokenService) GenerateRoomToken(perms RoomPermissions, duration time.Duration) (string, error) {
	at := auth.NewAccessToken(s.apiKey, s.apiSecret)

	grant := &auth.VideoGrant{
		RoomJoin: true,
		Room:     perms.RoomName,
	}
	grant.SetCanPublish(perms.CanPublish)
	grant.SetCanSubscribe(perms.CanSubscribe)
	grant.SetCanPublishData(perms.CanPublishData)

	// Add 5 minute buffer to call duration
	ttl := duration + 5*time.Minute

	at.AddGrant(grant).
		SetIdentity(perms.Identity).
		SetValidFor(ttl)

	return at.ToJWT()
}
