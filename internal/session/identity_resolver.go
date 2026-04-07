package session

import (
	"context"
	"database/sql"
	"errors"
	"regexp"
	"strings"

	"github.com/google/uuid"
)

// Identity resolution errors.
var (
	ErrIdentityNotFound = errors.New("identity: user not found")
	ErrInvalidIdentity  = errors.New("identity: invalid identifier format")
)

// IdentityResolver resolves phone numbers, external IDs, or UUIDs to
// canonical user UUIDs. It is safe for concurrent use.
type IdentityResolver struct {
	db *sql.DB
}

// NewIdentityResolver creates a resolver backed by the users table.
func NewIdentityResolver(db *sql.DB) *IdentityResolver {
	return &IdentityResolver{db: db}
}

// phoneRe matches E.164 phone numbers: +<country><number>, 7-15 digits.
var phoneRe = regexp.MustCompile(`^\+[1-9]\d{6,14}$`)

// Resolve takes an identifier string and returns the canonical UUID.
//
// Supported formats:
//   - UUID (pass-through after validation)
//   - Phone number (+E.164 → lookup users.phone_number)
//   - "ext:<value>" → lookup users.external_id
//
// Returns ErrInvalidIdentity for unrecognised formats and
// ErrIdentityNotFound when lookup yields no row.
func (r *IdentityResolver) Resolve(ctx context.Context, id string) (string, error) {
	id = strings.TrimSpace(id)
	if id == "" {
		return "", ErrInvalidIdentity
	}

	// 1. UUID pass-through
	if _, err := uuid.Parse(id); err == nil {
		return id, nil
	}

	// 2. Phone number (E.164)
	if phoneRe.MatchString(id) {
		return r.lookupByPhone(ctx, id)
	}

	// 3. External ID prefix
	if strings.HasPrefix(id, "ext:") {
		extID := strings.TrimPrefix(id, "ext:")
		if extID == "" {
			return "", ErrInvalidIdentity
		}
		return r.lookupByExternalID(ctx, extID)
	}

	return "", ErrInvalidIdentity
}

// ResolveAll resolves a slice of identifiers, returning resolved UUIDs
// in the same order. Stops at the first error.
func (r *IdentityResolver) ResolveAll(ctx context.Context, ids []string) ([]string, error) {
	resolved := make([]string, len(ids))
	for i, id := range ids {
		uid, err := r.Resolve(ctx, id)
		if err != nil {
			return nil, err
		}
		resolved[i] = uid
	}
	return resolved, nil
}

func (r *IdentityResolver) lookupByPhone(ctx context.Context, phone string) (string, error) {
	var uid string
	err := r.db.QueryRowContext(ctx,
		`SELECT id FROM users WHERE phone_number = $1`, phone,
	).Scan(&uid)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrIdentityNotFound
	}
	if err != nil {
		return "", err
	}
	return uid, nil
}

func (r *IdentityResolver) lookupByExternalID(ctx context.Context, extID string) (string, error) {
	var uid string
	err := r.db.QueryRowContext(ctx,
		`SELECT id FROM users WHERE external_id = $1`, extID,
	).Scan(&uid)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrIdentityNotFound
	}
	if err != nil {
		return "", err
	}
	return uid, nil
}
