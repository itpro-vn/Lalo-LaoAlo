package auth

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// ---- JWT Tests ----

func TestNewJWTService_EmptySecret(t *testing.T) {
	_, err := NewJWTService("", 15, 7)
	if err == nil {
		t.Error("expected error for empty secret")
	}
}

func TestIssueAndValidateAccessToken(t *testing.T) {
	svc, err := NewJWTService("test-secret-key-123", 15, 7)
	if err != nil {
		t.Fatal(err)
	}

	token, err := svc.IssueAccessToken("user-1", "device-1", []string{"call:initiate"})
	if err != nil {
		t.Fatal(err)
	}

	claims, err := svc.Validate(token)
	if err != nil {
		t.Fatal(err)
	}

	if claims.UserID != "user-1" {
		t.Errorf("expected user-1, got %s", claims.UserID)
	}
	if claims.DeviceID != "device-1" {
		t.Errorf("expected device-1, got %s", claims.DeviceID)
	}
	if claims.TokenType != "access" {
		t.Errorf("expected access, got %s", claims.TokenType)
	}
	if len(claims.Permissions) != 1 || claims.Permissions[0] != "call:initiate" {
		t.Errorf("expected [call:initiate], got %v", claims.Permissions)
	}
	if claims.Issuer != "lalo" {
		t.Errorf("expected issuer=lalo, got %s", claims.Issuer)
	}
}

func TestIssueTokenPair(t *testing.T) {
	svc, err := NewJWTService("test-secret-key-123", 15, 7)
	if err != nil {
		t.Fatal(err)
	}

	pair, err := svc.IssueTokenPair("user-1", "device-1", []string{"call:initiate"})
	if err != nil {
		t.Fatal(err)
	}

	if pair.AccessToken == "" {
		t.Error("access token is empty")
	}
	if pair.RefreshToken == "" {
		t.Error("refresh token is empty")
	}
	if pair.ExpiresIn != 900 { // 15 minutes
		t.Errorf("expected 900s expiry, got %d", pair.ExpiresIn)
	}

	// Validate access token
	accessClaims, err := svc.Validate(pair.AccessToken)
	if err != nil {
		t.Fatal(err)
	}
	if accessClaims.TokenType != "access" {
		t.Errorf("expected access, got %s", accessClaims.TokenType)
	}

	// Validate refresh token
	refreshClaims, err := svc.Validate(pair.RefreshToken)
	if err != nil {
		t.Fatal(err)
	}
	if refreshClaims.TokenType != "refresh" {
		t.Errorf("expected refresh, got %s", refreshClaims.TokenType)
	}
}

func TestRefreshTokens(t *testing.T) {
	svc, err := NewJWTService("test-secret-key-123", 15, 7)
	if err != nil {
		t.Fatal(err)
	}

	pair, err := svc.IssueTokenPair("user-1", "device-1", nil)
	if err != nil {
		t.Fatal(err)
	}

	// Refresh using refresh token
	newPair, err := svc.RefreshTokens(pair.RefreshToken)
	if err != nil {
		t.Fatal(err)
	}

	if newPair.AccessToken == "" {
		t.Error("new access token is empty")
	}
	if newPair.RefreshToken == pair.RefreshToken {
		t.Error("refresh token should be rotated")
	}
}

func TestRefreshWithAccessToken_Fails(t *testing.T) {
	svc, err := NewJWTService("test-secret-key-123", 15, 7)
	if err != nil {
		t.Fatal(err)
	}

	pair, err := svc.IssueTokenPair("user-1", "device-1", nil)
	if err != nil {
		t.Fatal(err)
	}

	// Try to refresh using access token — should fail
	_, err = svc.RefreshTokens(pair.AccessToken)
	if err == nil {
		t.Error("expected error when refreshing with access token")
	}
}

func TestValidateInvalidToken(t *testing.T) {
	svc, err := NewJWTService("test-secret-key-123", 15, 7)
	if err != nil {
		t.Fatal(err)
	}

	_, err = svc.Validate("not-a-valid-token")
	if err == nil {
		t.Error("expected error for invalid token")
	}
}

func TestValidateWrongSecret(t *testing.T) {
	svc1, _ := NewJWTService("secret-1", 15, 7)
	svc2, _ := NewJWTService("secret-2", 15, 7)

	token, _ := svc1.IssueAccessToken("user-1", "device-1", nil)
	_, err := svc2.Validate(token)
	if err == nil {
		t.Error("expected error for wrong secret")
	}
}

// ---- TURN Tests ----

func TestTurnGenerateCredentials(t *testing.T) {
	svc := NewTurnService("coturn-secret-key", 86400, []string{"turn:turn.example.com:3478"})
	creds := svc.GenerateCredentials("user-1")

	if creds.Username == "" {
		t.Error("username is empty")
	}
	if creds.Password == "" {
		t.Error("password is empty")
	}
	if creds.TTL != 86400 {
		t.Errorf("expected TTL=86400, got %d", creds.TTL)
	}
	if len(creds.URIs) != 1 {
		t.Errorf("expected 1 URI, got %d", len(creds.URIs))
	}
}

func TestTurnValidateCredentials(t *testing.T) {
	svc := NewTurnService("coturn-secret-key", 86400, []string{"turn:turn.example.com:3478"})
	creds := svc.GenerateCredentials("user-1")

	if !svc.ValidateCredentials(creds) {
		t.Error("generated credentials should be valid")
	}
}

func TestTurnInvalidCredentials(t *testing.T) {
	svc := NewTurnService("coturn-secret-key", 86400, nil)
	creds := svc.GenerateCredentials("user-1")

	// Tamper with password
	creds.Password = "tampered"
	if svc.ValidateCredentials(creds) {
		t.Error("tampered credentials should be invalid")
	}
}

func TestTurnDefaultTTL(t *testing.T) {
	svc := NewTurnService("secret", 0, nil)
	creds := svc.GenerateCredentials("user-1")
	if creds.TTL != 86400 {
		t.Errorf("expected default TTL=86400, got %d", creds.TTL)
	}
}

// ---- LiveKit Token Tests ----

func TestLiveKitGenerateRoomToken(t *testing.T) {
	svc := NewLiveKitTokenService("api-key", "api-secret-that-is-long-enough")

	token, err := svc.GenerateRoomToken(RoomPermissions{
		RoomName:       "call-room-123",
		Identity:       "user-1",
		CanPublish:     true,
		CanSubscribe:   true,
		CanPublishData: true,
	}, 30*time.Minute)

	if err != nil {
		t.Fatal(err)
	}
	if token == "" {
		t.Error("token is empty")
	}
}

// ---- Rate Limit Parsing Tests ----

func TestParseRateLimit(t *testing.T) {
	tests := []struct {
		spec   string
		limit  int
		window time.Duration
	}{
		{"10/min", 10, time.Minute},
		{"60/min", 60, time.Minute},
		{"5/min", 5, time.Minute},
		{"100/s", 100, time.Second},
		{"1000/hour", 1000, time.Hour},
	}

	for _, tt := range tests {
		rl, err := ParseRateLimit("test", tt.spec)
		if err != nil {
			t.Errorf("ParseRateLimit(%q): %v", tt.spec, err)
			continue
		}
		if rl.Limit != tt.limit {
			t.Errorf("ParseRateLimit(%q).Limit = %d, want %d", tt.spec, rl.Limit, tt.limit)
		}
		if rl.Window != tt.window {
			t.Errorf("ParseRateLimit(%q).Window = %v, want %v", tt.spec, rl.Window, tt.window)
		}
	}
}

func TestParseRateLimit_Invalid(t *testing.T) {
	invalids := []string{"", "10", "abc/min", "10/years"}
	for _, spec := range invalids {
		_, err := ParseRateLimit("test", spec)
		if err == nil {
			t.Errorf("expected error for spec %q", spec)
		}
	}
}

// ---- Middleware Tests ----

func TestJWTMiddleware_ValidToken(t *testing.T) {
	svc, _ := NewJWTService("test-secret", 15, 7)
	token, _ := svc.IssueAccessToken("user-1", "device-1", nil)

	handler := JWTMiddleware(svc)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		claims, ok := ClaimsFromContext(r.Context())
		if !ok {
			t.Error("claims not found in context")
			return
		}
		if claims.UserID != "user-1" {
			t.Errorf("expected user-1, got %s", claims.UserID)
		}
		w.WriteHeader(http.StatusOK)
	}))

	req := httptest.NewRequest("GET", "/api/test", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr := httptest.NewRecorder()

	handler.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", rr.Code)
	}
}

func TestJWTMiddleware_MissingToken(t *testing.T) {
	svc, _ := NewJWTService("test-secret", 15, 7)
	handler := JWTMiddleware(svc)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("handler should not be called")
	}))

	req := httptest.NewRequest("GET", "/api/test", nil)
	rr := httptest.NewRecorder()

	handler.ServeHTTP(rr, req)
	if rr.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", rr.Code)
	}
}

func TestJWTMiddleware_InvalidToken(t *testing.T) {
	svc, _ := NewJWTService("test-secret", 15, 7)
	handler := JWTMiddleware(svc)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("handler should not be called")
	}))

	req := httptest.NewRequest("GET", "/api/test", nil)
	req.Header.Set("Authorization", "Bearer invalid-token")
	rr := httptest.NewRecorder()

	handler.ServeHTTP(rr, req)
	if rr.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", rr.Code)
	}
}

func TestJWTMiddleware_RefreshTokenRejected(t *testing.T) {
	svc, _ := NewJWTService("test-secret", 15, 7)
	pair, _ := svc.IssueTokenPair("user-1", "device-1", nil)

	handler := JWTMiddleware(svc)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("handler should not be called for refresh tokens")
	}))

	req := httptest.NewRequest("GET", "/api/test", nil)
	req.Header.Set("Authorization", "Bearer "+pair.RefreshToken)
	rr := httptest.NewRecorder()

	handler.ServeHTTP(rr, req)
	if rr.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", rr.Code)
	}
}

func TestJWTMiddleware_QueryParam(t *testing.T) {
	svc, _ := NewJWTService("test-secret", 15, 7)
	token, _ := svc.IssueAccessToken("user-1", "device-1", nil)

	handler := JWTMiddleware(svc)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		claims, ok := ClaimsFromContext(r.Context())
		if !ok {
			t.Error("claims not found")
			return
		}
		if claims.UserID != "user-1" {
			t.Errorf("expected user-1, got %s", claims.UserID)
		}
		w.WriteHeader(http.StatusOK)
	}))

	req := httptest.NewRequest("GET", "/ws?token="+token, nil)
	rr := httptest.NewRecorder()

	handler.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", rr.Code)
	}
}

// ---- extractToken Tests ----

func TestExtractToken(t *testing.T) {
	// Bearer header
	r1 := httptest.NewRequest("GET", "/", nil)
	r1.Header.Set("Authorization", "Bearer abc123")
	if got := extractToken(r1); got != "abc123" {
		t.Errorf("expected abc123, got %s", got)
	}

	// Query param
	r2 := httptest.NewRequest("GET", "/?token=xyz789", nil)
	if got := extractToken(r2); got != "xyz789" {
		t.Errorf("expected xyz789, got %s", got)
	}

	// No token
	r3 := httptest.NewRequest("GET", "/", nil)
	if got := extractToken(r3); got != "" {
		t.Errorf("expected empty, got %s", got)
	}

	// Case insensitive bearer
	r4 := httptest.NewRequest("GET", "/", nil)
	r4.Header.Set("Authorization", "bearer abc123")
	if got := extractToken(r4); got != "abc123" {
		t.Errorf("expected abc123, got %s", got)
	}
}

// Suppress unused import warning
var _ = context.Background
