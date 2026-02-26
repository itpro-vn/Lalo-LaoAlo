package auth

import (
	"context"
	"net/http"
	"strings"
)

// contextKey is an unexported type for context keys in this package.
type contextKey string

const (
	// ClaimsContextKey is the key used to store JWT claims in request context.
	ClaimsContextKey contextKey = "claims"
)

// ClaimsFromContext extracts JWT claims from the request context.
func ClaimsFromContext(ctx context.Context) (*Claims, bool) {
	claims, ok := ctx.Value(ClaimsContextKey).(*Claims)
	return claims, ok
}

// JWTMiddleware returns an HTTP middleware that validates JWT tokens.
// It extracts the token from the Authorization header (Bearer scheme)
// or from the "token" query parameter (for WebSocket upgrades).
func JWTMiddleware(jwtSvc *JWTService) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			tokenString := extractToken(r)
			if tokenString == "" {
				http.Error(w, `{"error":"missing authentication token"}`, http.StatusUnauthorized)
				return
			}

			claims, err := jwtSvc.Validate(tokenString)
			if err != nil {
				status := http.StatusUnauthorized
				msg := `{"error":"invalid token"}`
				if err == ErrExpiredToken {
					msg = `{"error":"token expired"}`
				}
				http.Error(w, msg, status)
				return
			}

			// Only allow access tokens for API requests
			if claims.TokenType != "access" {
				http.Error(w, `{"error":"invalid token type"}`, http.StatusUnauthorized)
				return
			}

			ctx := context.WithValue(r.Context(), ClaimsContextKey, claims)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// extractToken gets the JWT token from the request.
// Priority: Authorization header > query parameter "token".
func extractToken(r *http.Request) string {
	// Check Authorization header
	auth := r.Header.Get("Authorization")
	if auth != "" {
		parts := strings.SplitN(auth, " ", 2)
		if len(parts) == 2 && strings.EqualFold(parts[0], "bearer") {
			return parts[1]
		}
	}

	// Fallback to query parameter (for WebSocket upgrades)
	return r.URL.Query().Get("token")
}
