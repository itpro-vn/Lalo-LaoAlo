package push

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// Store manages push token persistence in Postgres.
type Store struct {
	db *sql.DB
}

// NewStore creates a new push token store.
func NewStore(db *sql.DB) *Store {
	return &Store{db: db}
}

// Register upserts a push token for a user+device pair.
func (s *Store) Register(ctx context.Context, userID string, req *RegisterRequest) (*PushToken, error) {
	query := `
		INSERT INTO push_tokens (user_id, device_id, platform, push_token, voip_token, app_version, bundle_id, is_active, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, true, now())
		ON CONFLICT (user_id, device_id) DO UPDATE SET
			platform = EXCLUDED.platform,
			push_token = EXCLUDED.push_token,
			voip_token = EXCLUDED.voip_token,
			app_version = EXCLUDED.app_version,
			bundle_id = EXCLUDED.bundle_id,
			is_active = true,
			updated_at = now()
		RETURNING id, user_id, device_id, platform, push_token, voip_token, app_version, bundle_id, is_active, created_at, updated_at`

	token := &PushToken{}
	var voipToken, appVersion, bundleID sql.NullString

	err := s.db.QueryRowContext(ctx, query,
		userID, req.DeviceID, req.Platform, req.PushToken,
		nullString(req.VoIPToken), nullString(req.AppVersion), nullString(req.BundleID),
	).Scan(
		&token.ID, &token.UserID, &token.DeviceID, &token.Platform,
		&token.PushToken, &voipToken, &appVersion, &bundleID,
		&token.IsActive, &token.CreatedAt, &token.UpdatedAt,
	)
	if err != nil {
		return nil, fmt.Errorf("register push token: %w", err)
	}

	token.VoIPToken = voipToken.String
	token.AppVersion = appVersion.String
	token.BundleID = bundleID.String

	return token, nil
}

// Unregister deactivates a push token for a user+device pair.
func (s *Store) Unregister(ctx context.Context, userID, deviceID string) error {
	query := `UPDATE push_tokens SET is_active = false, updated_at = now() WHERE user_id = $1 AND device_id = $2`
	result, err := s.db.ExecContext(ctx, query, userID, deviceID)
	if err != nil {
		return fmt.Errorf("unregister push token: %w", err)
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return ErrTokenNotFound
	}
	return nil
}

// GetActiveTokens returns all active push tokens for a user.
func (s *Store) GetActiveTokens(ctx context.Context, userID string) ([]PushToken, error) {
	query := `
		SELECT id, user_id, device_id, platform, push_token, voip_token, app_version, bundle_id, is_active, created_at, updated_at
		FROM push_tokens
		WHERE user_id = $1 AND is_active = true
		ORDER BY updated_at DESC`

	rows, err := s.db.QueryContext(ctx, query, userID)
	if err != nil {
		return nil, fmt.Errorf("get active tokens: %w", err)
	}
	defer rows.Close()

	var tokens []PushToken
	for rows.Next() {
		var t PushToken
		var voipToken, appVersion, bundleID sql.NullString
		if err := rows.Scan(
			&t.ID, &t.UserID, &t.DeviceID, &t.Platform,
			&t.PushToken, &voipToken, &appVersion, &bundleID,
			&t.IsActive, &t.CreatedAt, &t.UpdatedAt,
		); err != nil {
			return nil, fmt.Errorf("scan push token: %w", err)
		}
		t.VoIPToken = voipToken.String
		t.AppVersion = appVersion.String
		t.BundleID = bundleID.String
		tokens = append(tokens, t)
	}

	return tokens, rows.Err()
}

// InvalidateToken marks a specific push token as inactive (e.g., APNs 410 Gone, FCM UNREGISTERED).
func (s *Store) InvalidateToken(ctx context.Context, pushToken string) error {
	query := `UPDATE push_tokens SET is_active = false, updated_at = now() WHERE push_token = $1 OR voip_token = $1`
	_, err := s.db.ExecContext(ctx, query, pushToken)
	if err != nil {
		return fmt.Errorf("invalidate token: %w", err)
	}
	return nil
}

// UserProfile holds basic user display info for push notifications.
type UserProfile struct {
	DisplayName string
	AvatarURL   string
}

// GetUserProfile looks up display_name and avatar_url from the users table.
// Returns nil (no error) if the user is not found.
func (s *Store) GetUserProfile(ctx context.Context, userID string) (*UserProfile, error) {
	query := `SELECT display_name, avatar_url FROM users WHERE id = $1`
	var displayName string
	var avatarURL sql.NullString

	err := s.db.QueryRowContext(ctx, query, userID).Scan(&displayName, &avatarURL)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("get user profile: %w", err)
	}

	return &UserProfile{
		DisplayName: displayName,
		AvatarURL:   avatarURL.String,
	}, nil
}

// CleanupStaleTokens soft-deletes tokens not updated within the given duration.
func (s *Store) CleanupStaleTokens(ctx context.Context, staleDuration time.Duration) (int64, error) {
	query := `UPDATE push_tokens SET is_active = false, updated_at = now() WHERE is_active = true AND updated_at < $1`
	cutoff := time.Now().Add(-staleDuration)
	result, err := s.db.ExecContext(ctx, query, cutoff)
	if err != nil {
		return 0, fmt.Errorf("cleanup stale tokens: %w", err)
	}
	return result.RowsAffected()
}

func nullString(s string) sql.NullString {
	if s == "" {
		return sql.NullString{}
	}
	return sql.NullString{String: s, Valid: true}
}
