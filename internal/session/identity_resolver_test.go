package session

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"testing"

	"github.com/google/uuid"
	_ "github.com/lib/pq"
)

// testDB returns a *sql.DB connected to the test Postgres instance.
// Skips the test if DATABASE_URL is not set.
func testDB(t *testing.T) *sql.DB {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		dsn = "postgres://postgres:postgres@localhost:5432/lalo_test?sslmode=disable"
	}
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Skipf("skip: cannot open postgres: %v", err)
	}
	if err := db.Ping(); err != nil {
		t.Skipf("skip: cannot ping postgres: %v", err)
	}
	// Ensure schema exists
	_, err = db.Exec(`CREATE TABLE IF NOT EXISTS users (
		id UUID PRIMARY KEY,
		display_name TEXT NOT NULL,
		avatar_url TEXT,
		phone_number TEXT,
		external_id TEXT,
		created_at TIMESTAMPTZ NOT NULL DEFAULT now()
	)`)
	if err != nil {
		t.Fatalf("create table: %v", err)
	}
	return db
}

// seedUser inserts a test user and returns its UUID.
func seedUser(t *testing.T, db *sql.DB, phone, extID string) string {
	t.Helper()
	uid := uuid.NewString()
	_, err := db.Exec(
		`INSERT INTO users (id, display_name, phone_number, external_id) VALUES ($1, $2, $3, $4)`,
		uid, "test-user-"+uid[:8], nilIfEmpty(phone), nilIfEmpty(extID),
	)
	if err != nil {
		t.Fatalf("seed user: %v", err)
	}
	t.Cleanup(func() {
		db.Exec(`DELETE FROM users WHERE id = $1`, uid) //nolint:errcheck
	})
	return uid
}

func nilIfEmpty(s string) interface{} {
	if s == "" {
		return nil
	}
	return s
}

// --- Unit tests (no DB required) ---

func TestIdentityResolver_UUIDPassthrough(t *testing.T) {
	// UUID resolution is pure — no DB needed.
	r := NewIdentityResolver(nil)
	ctx := context.Background()

	uid := uuid.NewString()
	got, err := r.Resolve(ctx, uid)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != uid {
		t.Errorf("got %q, want %q", got, uid)
	}
}

func TestIdentityResolver_UUIDUpperCase(t *testing.T) {
	r := NewIdentityResolver(nil)
	ctx := context.Background()

	uid := "550E8400-E29B-41D4-A716-446655440000"
	got, err := r.Resolve(ctx, uid)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != uid {
		t.Errorf("got %q, want %q", got, uid)
	}
}

func TestIdentityResolver_InvalidFormats(t *testing.T) {
	r := NewIdentityResolver(nil)
	ctx := context.Background()

	cases := []struct {
		name  string
		input string
	}{
		{"empty", ""},
		{"whitespace", "   "},
		{"random string", "hello-world"},
		{"short number", "+123"},
		{"no plus phone", "84912345678"},
		{"ext empty value", "ext:"},
		{"partial uuid", "550e8400-e29b-41d4"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := r.Resolve(ctx, tc.input)
			if err != ErrInvalidIdentity {
				t.Errorf("input %q: got err=%v, want ErrInvalidIdentity", tc.input, err)
			}
		})
	}
}

// --- Integration tests (require Postgres) ---

func TestIdentityResolver_PhoneLookup(t *testing.T) {
	db := testDB(t)
	r := NewIdentityResolver(db)
	ctx := context.Background()

	phone := fmt.Sprintf("+8491%07d", os.Getpid()%10000000)
	uid := seedUser(t, db, phone, "")

	got, err := r.Resolve(ctx, phone)
	if err != nil {
		t.Fatalf("phone lookup: %v", err)
	}
	if got != uid {
		t.Errorf("got %q, want %q", got, uid)
	}
}

func TestIdentityResolver_PhoneNotFound(t *testing.T) {
	db := testDB(t)
	r := NewIdentityResolver(db)
	ctx := context.Background()

	_, err := r.Resolve(ctx, "+84999999999")
	if err != ErrIdentityNotFound {
		t.Errorf("got err=%v, want ErrIdentityNotFound", err)
	}
}

func TestIdentityResolver_ExternalIDLookup(t *testing.T) {
	db := testDB(t)
	r := NewIdentityResolver(db)
	ctx := context.Background()

	extID := "firebase:" + uuid.NewString()[:8]
	uid := seedUser(t, db, "", extID)

	got, err := r.Resolve(ctx, "ext:"+extID)
	if err != nil {
		t.Fatalf("ext lookup: %v", err)
	}
	if got != uid {
		t.Errorf("got %q, want %q", got, uid)
	}
}

func TestIdentityResolver_ExternalIDNotFound(t *testing.T) {
	db := testDB(t)
	r := NewIdentityResolver(db)
	ctx := context.Background()

	_, err := r.Resolve(ctx, "ext:nonexistent-id")
	if err != ErrIdentityNotFound {
		t.Errorf("got err=%v, want ErrIdentityNotFound", err)
	}
}

func TestIdentityResolver_ResolveAll(t *testing.T) {
	db := testDB(t)
	r := NewIdentityResolver(db)
	ctx := context.Background()

	uid1 := uuid.NewString()
	phone := fmt.Sprintf("+8492%07d", os.Getpid()%10000000)
	uid2 := seedUser(t, db, phone, "")

	got, err := r.ResolveAll(ctx, []string{uid1, phone})
	if err != nil {
		t.Fatalf("resolve all: %v", err)
	}
	if len(got) != 2 || got[0] != uid1 || got[1] != uid2 {
		t.Errorf("got %v, want [%s, %s]", got, uid1, uid2)
	}
}

func TestIdentityResolver_ResolveAllStopsOnError(t *testing.T) {
	r := NewIdentityResolver(nil)
	ctx := context.Background()

	_, err := r.ResolveAll(ctx, []string{uuid.NewString(), "bad-input"})
	if err != ErrInvalidIdentity {
		t.Errorf("got err=%v, want ErrInvalidIdentity", err)
	}
}

func TestIdentityResolver_WhitespaceTrimming(t *testing.T) {
	r := NewIdentityResolver(nil)
	ctx := context.Background()

	uid := uuid.NewString()
	got, err := r.Resolve(ctx, "  "+uid+"  ")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != uid {
		t.Errorf("got %q, want %q", got, uid)
	}
}
