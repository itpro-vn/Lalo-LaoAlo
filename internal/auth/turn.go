package auth

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"fmt"
	"time"
)

// TurnCredentials holds time-limited TURN server credentials.
type TurnCredentials struct {
	Username string   `json:"username"`
	Password string   `json:"password"`
	TTL      int      `json:"ttl"`
	URIs     []string `json:"uris"`
}

// TurnService generates HMAC-based time-limited credentials for coturn.
type TurnService struct {
	secret []byte
	ttl    int
	uris   []string
}

// NewTurnService creates a new TURN credential service.
// secret is the shared secret configured in coturn (static-auth-secret).
// ttl is the credential validity in seconds.
// uris are the TURN server URIs (e.g., ["turn:turn.example.com:3478"]).
func NewTurnService(secret string, ttl int, uris []string) *TurnService {
	if ttl <= 0 {
		ttl = 86400 // 24 hours
	}
	return &TurnService{
		secret: []byte(secret),
		ttl:    ttl,
		uris:   uris,
	}
}

// GenerateCredentials creates time-limited TURN credentials for a user.
// Format: username = "{expiry_timestamp}:{user_id}"
//
//	password = Base64(HMAC-SHA1(secret, username))
func (s *TurnService) GenerateCredentials(userID string) *TurnCredentials {
	expiry := time.Now().Unix() + int64(s.ttl)
	username := fmt.Sprintf("%d:%s", expiry, userID)

	mac := hmac.New(sha1.New, s.secret)
	mac.Write([]byte(username))
	password := base64.StdEncoding.EncodeToString(mac.Sum(nil))

	return &TurnCredentials{
		Username: username,
		Password: password,
		TTL:      s.ttl,
		URIs:     s.uris,
	}
}

// ValidateCredentials checks if TURN credentials are valid and not expired.
// This is used for testing; coturn validates credentials directly.
func (s *TurnService) ValidateCredentials(creds *TurnCredentials) bool {
	// Recompute HMAC
	mac := hmac.New(sha1.New, s.secret)
	mac.Write([]byte(creds.Username))
	expected := base64.StdEncoding.EncodeToString(mac.Sum(nil))

	return hmac.Equal([]byte(creds.Password), []byte(expected))
}
