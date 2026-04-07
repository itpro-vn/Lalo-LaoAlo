package session

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/minhgv/lalo/internal/auth"
)

func TestServerRegistersAuthRoutes(t *testing.T) {
	jwtSvc, err := auth.NewJWTService("test-secret", 15, 7)
	if err != nil {
		t.Fatal(err)
	}

	s := NewServer(&Handler{}, jwtSvc, 8081)
	mux := http.NewServeMux()

	// Mirror route registration in Start()
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	mux.Handle("/api/v1/sessions", auth.JWTMiddleware(jwtSvc)(s.handler))
	mux.Handle("/api/v1/sessions/", auth.JWTMiddleware(jwtSvc)(s.handler))
	mux.Handle("/api/v1/rooms", auth.JWTMiddleware(jwtSvc)(s.handler))
	mux.Handle("/api/v1/rooms/", auth.JWTMiddleware(jwtSvc)(s.handler))
	mux.Handle("/api/v1/auth/login", s.auth)
	mux.Handle("/api/v1/auth/refresh", s.auth)
	mux.Handle("/api/v1/auth/me", auth.JWTMiddleware(jwtSvc)(s.auth))
	mux.Handle("/v1/auth/login", s.auth)
	mux.Handle("/v1/auth/refresh", s.auth)
	mux.Handle("/v1/auth/me", auth.JWTMiddleware(jwtSvc)(s.auth))

	t.Run("rooms protected route", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodPost, "/api/v1/rooms", nil)
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, req)
		if w.Code != http.StatusUnauthorized {
			t.Fatalf("expected 401 for /api/v1/rooms without token, got %d", w.Code)
		}
	})

	t.Run("rooms sub-route protected", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodPost, "/api/v1/rooms/room-id/invite", nil)
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, req)
		if w.Code != http.StatusUnauthorized {
			t.Fatalf("expected 401 for /api/v1/rooms/:id/invite without token, got %d", w.Code)
		}
	})

	t.Run("login open route", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", nil)
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, req)
		if w.Code == http.StatusUnauthorized {
			t.Fatalf("login route unexpectedly protected")
		}
	})

	t.Run("me protected route", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/api/v1/auth/me", nil)
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, req)
		if w.Code != http.StatusUnauthorized {
			t.Fatalf("expected 401 for /api/v1/auth/me without token, got %d", w.Code)
		}
	})

	t.Run("legacy login open route", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodPost, "/v1/auth/login", nil)
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, req)
		if w.Code == http.StatusUnauthorized {
			t.Fatalf("legacy login route unexpectedly protected")
		}
	})

	t.Run("legacy me protected route", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/v1/auth/me", nil)
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, req)
		if w.Code != http.StatusUnauthorized {
			t.Fatalf("expected 401 for /v1/auth/me without token, got %d", w.Code)
		}
	})
}
