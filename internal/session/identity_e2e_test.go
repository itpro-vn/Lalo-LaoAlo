package session

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/google/uuid"
	"github.com/minhgv/lalo/internal/auth"
)

// --- C2: Server mux room route tests ---

func TestServerMux_RoomRoutesProtected(t *testing.T) {
	jwtSvc, err := auth.NewJWTService("test-secret-c2", 15, 7)
	if err != nil {
		t.Fatal(err)
	}

	s := NewServer(&Handler{}, jwtSvc, 0)
	mux := http.NewServeMux()

	mux.Handle("/api/v1/rooms", auth.JWTMiddleware(jwtSvc)(s.handler))
	mux.Handle("/api/v1/rooms/", auth.JWTMiddleware(jwtSvc)(s.handler))

	routes := []struct {
		name   string
		method string
		path   string
	}{
		{"create room", http.MethodPost, "/api/v1/rooms"},
		{"invite to room", http.MethodPost, "/api/v1/rooms/room-id/invite"},
		{"join room", http.MethodPost, "/api/v1/rooms/room-id/join"},
		{"leave room", http.MethodPost, "/api/v1/rooms/room-id/leave"},
		{"end room", http.MethodPost, "/api/v1/rooms/room-id/end"},
		{"room participants", http.MethodGet, "/api/v1/rooms/room-id/participants"},
	}

	for _, tt := range routes {
		t.Run(tt.name+" no token", func(t *testing.T) {
			req := httptest.NewRequest(tt.method, tt.path, nil)
			w := httptest.NewRecorder()
			mux.ServeHTTP(w, req)
			if w.Code != http.StatusUnauthorized {
				t.Errorf("expected 401 for %s %s without token, got %d", tt.method, tt.path, w.Code)
			}
		})
	}
}

func TestServerMux_RoomRoutesWithToken(t *testing.T) {
	jwtSvc, err := auth.NewJWTService("test-secret-c2-tok", 15, 7)
	if err != nil {
		t.Fatal(err)
	}

	// Issue a valid token
	callerID := uuid.NewString()
	tp, err := jwtSvc.IssueTokenPair(callerID, "device-1", nil)
	if err != nil {
		t.Fatal(err)
	}

	// Use a recording handler to verify the middleware passes auth
	var authPassed bool
	recorder := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		claims, ok := auth.ClaimsFromContext(r.Context())
		authPassed = ok && claims.UserID == callerID
		w.WriteHeader(http.StatusOK)
	})

	mux := http.NewServeMux()
	mux.Handle("/api/v1/rooms", auth.JWTMiddleware(jwtSvc)(recorder))
	mux.Handle("/api/v1/rooms/", auth.JWTMiddleware(jwtSvc)(recorder))

	req := httptest.NewRequest(http.MethodPost, "/api/v1/rooms", nil)
	req.Header.Set("Authorization", "Bearer "+tp.AccessToken)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)

	if w.Code == http.StatusUnauthorized {
		t.Errorf("expected auth to pass with valid token, got 401")
	}
	if !authPassed {
		t.Error("JWT middleware did not inject claims into context")
	}
}

// --- C2: Identity resolution E2E through handler ---

// testHandlerWithDB creates a Handler backed by a real DB for identity resolution.
// Returns the handler, jwtService, and a seedUser function.
// Skips if DATABASE_URL / postgres not available.
func testHandlerWithDB(t *testing.T) (*Handler, *auth.JWTService, func(phone, extID string) string) {
	t.Helper()

	db := testDB(t) // from identity_resolver_test.go

	jwtSvc, err := auth.NewJWTService("test-secret-e2e", 15, 7)
	if err != nil {
		t.Fatal(err)
	}

	// Create a minimal orchestrator with resolver — no Redis/TURN/LiveKit
	resolver := NewIdentityResolver(db)

	// We test resolution logic directly through the resolver since
	// the full orchestrator needs Redis. Handler tests verify routing/auth.
	_ = resolver

	return &Handler{jwtService: jwtSvc}, jwtSvc, func(phone, extID string) string {
		return seedUser(t, db, phone, extID)
	}
}

func TestIdentityE2E_ResolveInCreateSession(t *testing.T) {
	db := testDB(t)
	resolver := NewIdentityResolver(db)
	ctx := context.Background()

	// Seed a user with phone
	phone := fmt.Sprintf("+8493%07d", os.Getpid()%10000000)
	uid := seedUser(t, db, phone, "")

	// Resolve through the resolver (simulating what orchestrator.CreateSession does)
	got, err := resolver.Resolve(ctx, phone)
	if err != nil {
		t.Fatalf("resolve phone in create session flow: %v", err)
	}
	if got != uid {
		t.Errorf("got %q, want %q", got, uid)
	}
}

func TestIdentityE2E_ResolveInCreateRoom(t *testing.T) {
	db := testDB(t)
	resolver := NewIdentityResolver(db)
	ctx := context.Background()

	// Seed users: one with phone, one with external ID
	phone := fmt.Sprintf("+8494%07d", os.Getpid()%10000000)
	uid1 := seedUser(t, db, phone, "")

	extID := "firebase:" + uuid.NewString()[:8]
	uid2 := seedUser(t, db, "", extID)

	uid3 := uuid.NewString() // UUID pass-through, no DB row needed

	// Resolve all participants (simulating orchestrator.CreateGroupSession)
	resolved, err := resolver.ResolveAll(ctx, []string{phone, "ext:" + extID, uid3})
	if err != nil {
		t.Fatalf("resolve participants in create room: %v", err)
	}

	if len(resolved) != 3 {
		t.Fatalf("expected 3 resolved, got %d", len(resolved))
	}
	if resolved[0] != uid1 {
		t.Errorf("participant[0]: got %q, want %q (phone)", resolved[0], uid1)
	}
	if resolved[1] != uid2 {
		t.Errorf("participant[1]: got %q, want %q (ext)", resolved[1], uid2)
	}
	if resolved[2] != uid3 {
		t.Errorf("participant[2]: got %q, want %q (uuid)", resolved[2], uid3)
	}
}

func TestIdentityE2E_ResolveInInviteToRoom(t *testing.T) {
	db := testDB(t)
	resolver := NewIdentityResolver(db)
	ctx := context.Background()

	// Seed invitees: phone + external_id
	phone := fmt.Sprintf("+8495%07d", os.Getpid()%10000000)
	uid1 := seedUser(t, db, phone, "")

	extID := "auth0:" + uuid.NewString()[:8]
	uid2 := seedUser(t, db, "", extID)

	// Resolve invitees (simulating orchestrator.InviteToRoom)
	resolved, err := resolver.ResolveAll(ctx, []string{phone, "ext:" + extID})
	if err != nil {
		t.Fatalf("resolve invitees: %v", err)
	}

	if len(resolved) != 2 {
		t.Fatalf("expected 2 resolved, got %d", len(resolved))
	}
	if resolved[0] != uid1 {
		t.Errorf("invitee[0]: got %q, want %q", resolved[0], uid1)
	}
	if resolved[1] != uid2 {
		t.Errorf("invitee[1]: got %q, want %q", resolved[1], uid2)
	}
}

func TestIdentityE2E_ResolveNotFoundReturnsError(t *testing.T) {
	db := testDB(t)
	resolver := NewIdentityResolver(db)
	ctx := context.Background()

	// Phone that doesn't exist
	_, err := resolver.Resolve(ctx, "+84999000111")
	if err != ErrIdentityNotFound {
		t.Errorf("expected ErrIdentityNotFound for unknown phone, got %v", err)
	}

	// External ID that doesn't exist
	_, err = resolver.Resolve(ctx, "ext:nonexistent")
	if err != ErrIdentityNotFound {
		t.Errorf("expected ErrIdentityNotFound for unknown ext, got %v", err)
	}
}

func TestIdentityE2E_MixedBatchStopsOnNotFound(t *testing.T) {
	db := testDB(t)
	resolver := NewIdentityResolver(db)
	ctx := context.Background()

	uid := uuid.NewString()
	// Second is a phone that doesn't exist in DB
	_, err := resolver.ResolveAll(ctx, []string{uid, "+84999000222"})
	if err != ErrIdentityNotFound {
		t.Errorf("expected ErrIdentityNotFound, got %v", err)
	}
}

// --- C2: Handler routing with JWT for room endpoints ---
// Note: Room route dispatching is tested in handler_test.go (TestHandlerRouting).
// JWT middleware integration is tested in TestServerMux_RoomRoutesWithToken above.
// Full orchestrator integration requires Redis + LiveKit and is covered in
// signaling/group_integration_test.go.
