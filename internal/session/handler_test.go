package session

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHandlerRouting(t *testing.T) {
	tests := []struct {
		name   string
		method string
		path   string
		want   int // expected status (401 = auth required = correct routing)
	}{
		// Session routes
		{"create session", http.MethodPost, "/api/v1/sessions", http.StatusUnauthorized},
		{"get session", http.MethodGet, "/api/v1/sessions/test-id", http.StatusUnauthorized},
		{"join session", http.MethodPost, "/api/v1/sessions/test-id/join", http.StatusUnauthorized},
		{"leave session", http.MethodPost, "/api/v1/sessions/test-id/leave", http.StatusUnauthorized},
		{"end session", http.MethodPost, "/api/v1/sessions/test-id/end", http.StatusUnauthorized},
		{"update media", http.MethodPatch, "/api/v1/sessions/test-id/media", http.StatusUnauthorized},
		{"turn credentials", http.MethodGet, "/api/v1/sessions/test-id/turn-credentials", http.StatusUnauthorized},
		// Room (group call) routes
		{"create room", http.MethodPost, "/api/v1/rooms", http.StatusUnauthorized},
		{"invite to room", http.MethodPost, "/api/v1/rooms/room-id/invite", http.StatusUnauthorized},
		{"join room", http.MethodPost, "/api/v1/rooms/room-id/join", http.StatusUnauthorized},
		{"leave room", http.MethodPost, "/api/v1/rooms/room-id/leave", http.StatusUnauthorized},
		{"end room", http.MethodPost, "/api/v1/rooms/room-id/end", http.StatusUnauthorized},
		{"room participants", http.MethodGet, "/api/v1/rooms/room-id/participants", http.StatusUnauthorized},
		{"get room", http.MethodGet, "/api/v1/rooms/room-id", http.StatusUnauthorized},
		// Not found
		{"not found", http.MethodGet, "/api/v1/unknown", http.StatusNotFound},
	}

	handler := &Handler{} // nil orchestrator/jwt — only testing routing

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest(tt.method, tt.path, nil)
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, req)

			if w.Code != tt.want {
				t.Errorf("%s %s: got status %d, want %d", tt.method, tt.path, w.Code, tt.want)
			}
		})
	}
}

func TestMatchPath(t *testing.T) {
	tests := []struct {
		path   string
		prefix string
		suffix string
		want   bool
	}{
		{"/api/v1/sessions/abc/join", "/api/v1/sessions/", "/join", true},
		{"/api/v1/sessions/abc/leave", "/api/v1/sessions/", "/leave", true},
		{"/api/v1/sessions//join", "/api/v1/sessions/", "/join", false}, // empty ID
		{"/api/v1/sessions/join", "/api/v1/sessions/", "/join", false},  // no ID
		{"/api/v1/sessions/abc", "/api/v1/sessions/", "/join", false},   // no suffix
	}

	for _, tt := range tests {
		got := matchPath(tt.path, tt.prefix, tt.suffix)
		if got != tt.want {
			t.Errorf("matchPath(%q, %q, %q) = %v, want %v",
				tt.path, tt.prefix, tt.suffix, got, tt.want)
		}
	}
}

func TestMatchPrefix(t *testing.T) {
	tests := []struct {
		path   string
		prefix string
		want   bool
	}{
		{"/api/v1/sessions/abc", "/api/v1/sessions/", true},
		{"/api/v1/sessions/", "/api/v1/sessions/", false},              // no ID
		{"/api/v1/sessions/abc/join", "/api/v1/sessions/", false},      // has sub-path
		{"/api/v1/sessions/abc/join/x", "/api/v1/sessions/", false},    // deep path
	}

	for _, tt := range tests {
		got := matchPrefix(tt.path, tt.prefix)
		if got != tt.want {
			t.Errorf("matchPrefix(%q, %q) = %v, want %v",
				tt.path, tt.prefix, got, tt.want)
		}
	}
}

func TestExtractID(t *testing.T) {
	tests := []struct {
		path   string
		prefix string
		want   string
	}{
		{"/api/v1/sessions/abc", "/api/v1/sessions/", "abc"},
		{"/api/v1/sessions/abc/", "/api/v1/sessions/", "abc"},
		{"/api/v1/sessions/", "/api/v1/sessions/", ""},
	}

	for _, tt := range tests {
		got := extractID(tt.path, tt.prefix)
		if got != tt.want {
			t.Errorf("extractID(%q, %q) = %q, want %q",
				tt.path, tt.prefix, got, tt.want)
		}
	}
}

func TestExtractSegment(t *testing.T) {
	tests := []struct {
		path   string
		prefix string
		suffix string
		want   string
	}{
		{"/api/v1/sessions/abc/join", "/api/v1/sessions/", "/join", "abc"},
		{"/api/v1/sessions/uuid-123/end", "/api/v1/sessions/", "/end", "uuid-123"},
		{"/api/v1/sessions//join", "/api/v1/sessions/", "/join", ""},
	}

	for _, tt := range tests {
		got := extractSegment(tt.path, tt.prefix, tt.suffix)
		if got != tt.want {
			t.Errorf("extractSegment(%q, %q, %q) = %q, want %q",
				tt.path, tt.prefix, tt.suffix, got, tt.want)
		}
	}
}

func TestWriteJSON(t *testing.T) {
	w := httptest.NewRecorder()
	writeJSON(w, http.StatusOK, map[string]string{"key": "value"})

	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", w.Code)
	}
	if ct := w.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("expected application/json, got %s", ct)
	}
	if !strings.Contains(w.Body.String(), `"key":"value"`) {
		t.Errorf("unexpected body: %s", w.Body.String())
	}
}
