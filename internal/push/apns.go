package push

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// APNsConfig holds Apple Push Notification service settings.
type APNsConfig struct {
	TeamID     string // Apple Developer Team ID
	KeyID      string // APNs Auth Key ID
	KeyPath    string // Path to .p8 private key file
	BundleID   string // App bundle ID (e.g., com.lalo.app)
	Production bool   // Use production APNs endpoint
}

// APNsSender sends VoIP push notifications via APNs HTTP/2 API.
type APNsSender struct {
	cfg        APNsConfig
	httpClient *http.Client
	privateKey *ecdsa.PrivateKey

	mu       sync.Mutex
	jwtToken string
	jwtExp   time.Time
}

// NewAPNsSender creates a new APNs VoIP push sender.
func NewAPNsSender(cfg APNsConfig) (*APNsSender, error) {
	keyData, err := os.ReadFile(cfg.KeyPath)
	if err != nil {
		return nil, fmt.Errorf("read APNs key file: %w", err)
	}

	block, _ := pem.Decode(keyData)
	if block == nil {
		return nil, fmt.Errorf("failed to decode PEM block from APNs key")
	}

	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse APNs private key: %w", err)
	}

	ecKey, ok := key.(*ecdsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("APNs key is not an ECDSA private key")
	}

	return &APNsSender{
		cfg:        cfg,
		privateKey: ecKey,
		httpClient: &http.Client{Timeout: 10 * time.Second},
	}, nil
}

// Send delivers a VoIP push notification to an iOS device via APNs.
func (s *APNsSender) Send(ctx context.Context, voipToken string, payload *IncomingCallPush) error {
	token, err := s.getJWT()
	if err != nil {
		return fmt.Errorf("generate APNs JWT: %w", err)
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshal APNs payload: %w", err)
	}

	url := fmt.Sprintf("%s/3/device/%s", s.endpoint(), voipToken)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("create APNs request: %w", err)
	}

	// APNs headers for VoIP push
	req.Header.Set("Authorization", "bearer "+token)
	req.Header.Set("apns-topic", s.cfg.BundleID+".voip")
	req.Header.Set("apns-push-type", "voip")
	req.Header.Set("apns-priority", "10")
	req.Header.Set("apns-expiration", "0") // Don't store if device offline
	req.Header.Set("apns-collapse-id", "call_"+payload.CallID)

	resp, err := s.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("send APNs request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusOK {
		return nil
	}

	respBody, _ := io.ReadAll(resp.Body)

	// 410 Gone = token is no longer valid
	if resp.StatusCode == http.StatusGone {
		return fmt.Errorf("APNs token invalid (410 Gone): %s", string(respBody))
	}

	return fmt.Errorf("APNs error (status %d): %s", resp.StatusCode, string(respBody))
}

// Platform returns PlatformIOS.
func (s *APNsSender) Platform() Platform {
	return PlatformIOS
}

// IsGoneError returns true if the error indicates the APNs token is invalid.
func IsGoneError(err error) bool {
	if err == nil {
		return false
	}
	return contains(err.Error(), "410 Gone")
}

func (s *APNsSender) endpoint() string {
	if s.cfg.Production {
		return "https://api.push.apple.com"
	}
	return "https://api.sandbox.push.apple.com"
}

// getJWT returns a cached or fresh APNs provider JWT.
// APNs JWTs are valid for 1 hour; we refresh at 50 minutes.
func (s *APNsSender) getJWT() (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.jwtToken != "" && time.Now().Before(s.jwtExp) {
		return s.jwtToken, nil
	}

	now := time.Now()
	claims := jwt.RegisteredClaims{
		Issuer:   s.cfg.TeamID,
		IssuedAt: jwt.NewNumericDate(now),
	}

	token := jwt.NewWithClaims(jwt.SigningMethodES256, claims)
	token.Header["kid"] = s.cfg.KeyID

	signed, err := token.SignedString(s.privateKey)
	if err != nil {
		return "", fmt.Errorf("sign APNs JWT: %w", err)
	}

	s.jwtToken = signed
	s.jwtExp = now.Add(50 * time.Minute) // Refresh before 1h expiry

	return signed, nil
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && searchSubstring(s, substr)
}

func searchSubstring(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
