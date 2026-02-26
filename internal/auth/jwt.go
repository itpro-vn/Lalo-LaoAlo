// Package auth provides JWT authentication, TURN credential generation,
// LiveKit room tokens, and rate limiting for the Lalo call system.
package auth

import (
	"errors"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

var (
	ErrInvalidToken  = errors.New("invalid token")
	ErrExpiredToken  = errors.New("expired token")
	ErrInvalidClaims = errors.New("invalid claims")
)

// Claims represents the JWT claims for API and signaling tokens.
type Claims struct {
	UserID      string   `json:"user_id"`
	DeviceID    string   `json:"device_id"`
	Permissions []string `json:"permissions,omitempty"`
	TokenType   string   `json:"token_type"` // "access" or "refresh"
	jwt.RegisteredClaims
}

// JWTService handles JWT token operations.
type JWTService struct {
	secret             []byte
	accessTokenExpiry  time.Duration
	refreshTokenExpiry time.Duration
}

// NewJWTService creates a new JWT service with the given secret and expiry settings.
func NewJWTService(secret string, accessExpiryMins, refreshExpiryDays int) (*JWTService, error) {
	if secret == "" {
		return nil, errors.New("jwt secret must not be empty")
	}
	if accessExpiryMins <= 0 {
		accessExpiryMins = 15
	}
	if refreshExpiryDays <= 0 {
		refreshExpiryDays = 7
	}
	return &JWTService{
		secret:             []byte(secret),
		accessTokenExpiry:  time.Duration(accessExpiryMins) * time.Minute,
		refreshTokenExpiry: time.Duration(refreshExpiryDays) * 24 * time.Hour,
	}, nil
}

// TokenPair contains an access token and a refresh token.
type TokenPair struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int64  `json:"expires_in"` // seconds until access token expires
}

// IssueTokenPair generates both access and refresh tokens for the given user.
func (s *JWTService) IssueTokenPair(userID, deviceID string, permissions []string) (*TokenPair, error) {
	accessToken, err := s.issueToken(userID, deviceID, permissions, "access", s.accessTokenExpiry)
	if err != nil {
		return nil, fmt.Errorf("issue access token: %w", err)
	}

	refreshToken, err := s.issueToken(userID, deviceID, nil, "refresh", s.refreshTokenExpiry)
	if err != nil {
		return nil, fmt.Errorf("issue refresh token: %w", err)
	}

	return &TokenPair{
		AccessToken:  accessToken,
		RefreshToken: refreshToken,
		ExpiresIn:    int64(s.accessTokenExpiry.Seconds()),
	}, nil
}

// IssueAccessToken generates an access token only.
func (s *JWTService) IssueAccessToken(userID, deviceID string, permissions []string) (string, error) {
	return s.issueToken(userID, deviceID, permissions, "access", s.accessTokenExpiry)
}

// Validate parses and validates a JWT token, returning the claims.
func (s *JWTService) Validate(tokenString string) (*Claims, error) {
	token, err := jwt.ParseWithClaims(tokenString, &Claims{}, func(token *jwt.Token) (interface{}, error) {
		if _, ok := token.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", token.Header["alg"])
		}
		return s.secret, nil
	})
	if err != nil {
		if errors.Is(err, jwt.ErrTokenExpired) {
			return nil, ErrExpiredToken
		}
		return nil, fmt.Errorf("%w: %v", ErrInvalidToken, err)
	}

	claims, ok := token.Claims.(*Claims)
	if !ok || !token.Valid {
		return nil, ErrInvalidClaims
	}

	return claims, nil
}

// RefreshTokens validates a refresh token and issues a new token pair.
// The old refresh token is rotated (new one issued on each refresh).
func (s *JWTService) RefreshTokens(refreshTokenString string) (*TokenPair, error) {
	claims, err := s.Validate(refreshTokenString)
	if err != nil {
		return nil, fmt.Errorf("validate refresh token: %w", err)
	}
	if claims.TokenType != "refresh" {
		return nil, fmt.Errorf("%w: not a refresh token", ErrInvalidClaims)
	}

	return s.IssueTokenPair(claims.UserID, claims.DeviceID, nil)
}

func (s *JWTService) issueToken(userID, deviceID string, permissions []string, tokenType string, expiry time.Duration) (string, error) {
	now := time.Now()
	claims := &Claims{
		UserID:      userID,
		DeviceID:    deviceID,
		Permissions: permissions,
		TokenType:   tokenType,
		RegisteredClaims: jwt.RegisteredClaims{
			ID:        uuid.New().String(),
			ExpiresAt: jwt.NewNumericDate(now.Add(expiry)),
			IssuedAt:  jwt.NewNumericDate(now),
			Issuer:    "lalo",
		},
	}

	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString(s.secret)
}
