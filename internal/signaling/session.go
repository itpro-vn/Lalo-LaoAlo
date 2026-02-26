package signaling

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

// SessionStore manages call session state in Redis.
type SessionStore struct {
	rdb *redis.Client
}

// CallSession represents a call session stored in Redis.
type CallSession struct {
	CallID     string    `json:"call_id"`
	CallerID   string    `json:"caller_id"`
	CalleeID   string    `json:"callee_id"`
	CallType   string    `json:"call_type"`
	State      CallState `json:"state"`
	SDPOffer   string    `json:"sdp_offer,omitempty"`
	SDPAnswer  string    `json:"sdp_answer,omitempty"`
	StartedAt  time.Time `json:"started_at"`
	AnsweredAt time.Time `json:"answered_at,omitempty"`
	EndedAt    time.Time `json:"ended_at,omitempty"`
	EndReason  string    `json:"end_reason,omitempty"`
}

var (
	ErrSessionNotFound = errors.New("session not found")
	ErrConcurrentWrite = errors.New("concurrent session modification")
	ErrUserBusy        = errors.New("user already in active call")
)

// NewSessionStore creates a new Redis-backed session store.
func NewSessionStore(rdb *redis.Client) *SessionStore {
	return &SessionStore{rdb: rdb}
}

// sessionKey returns the Redis key for a call session.
func sessionKey(callID string) string {
	return fmt.Sprintf("session:%s", callID)
}

// userActiveCallKey returns the Redis key for a user's active call.
func userActiveCallKey(userID string) string {
	return fmt.Sprintf("user:active_call:%s", userID)
}

// Create stores a new call session in Redis using optimistic locking.
// It also checks that neither caller nor callee is already in an active call.
func (s *SessionStore) Create(ctx context.Context, session *CallSession) error {
	// Check both users are free
	for _, uid := range []string{session.CallerID, session.CalleeID} {
		exists, err := s.rdb.Exists(ctx, userActiveCallKey(uid)).Result()
		if err != nil {
			return fmt.Errorf("check user busy: %w", err)
		}
		if exists > 0 {
			return ErrUserBusy
		}
	}

	data, err := json.Marshal(session)
	if err != nil {
		return fmt.Errorf("marshal session: %w", err)
	}

	pipe := s.rdb.TxPipeline()
	key := sessionKey(session.CallID)

	// Store session with 24h TTL
	pipe.Set(ctx, key, data, 24*time.Hour)

	// Mark both users as having an active call
	pipe.Set(ctx, userActiveCallKey(session.CallerID), session.CallID, 24*time.Hour)
	pipe.Set(ctx, userActiveCallKey(session.CalleeID), session.CallID, 24*time.Hour)

	_, err = pipe.Exec(ctx)
	if err != nil {
		return fmt.Errorf("create session: %w", err)
	}

	return nil
}

// Get retrieves a call session from Redis.
func (s *SessionStore) Get(ctx context.Context, callID string) (*CallSession, error) {
	data, err := s.rdb.Get(ctx, sessionKey(callID)).Bytes()
	if err != nil {
		if errors.Is(err, redis.Nil) {
			return nil, ErrSessionNotFound
		}
		return nil, fmt.Errorf("get session: %w", err)
	}

	var session CallSession
	if err := json.Unmarshal(data, &session); err != nil {
		return nil, fmt.Errorf("unmarshal session: %w", err)
	}

	return &session, nil
}

// TransitionState atomically updates the session state using WATCH/MULTI.
func (s *SessionStore) TransitionState(ctx context.Context, callID string, to CallState, mutate func(*CallSession)) error {
	key := sessionKey(callID)

	// Optimistic locking with WATCH
	err := s.rdb.Watch(ctx, func(tx *redis.Tx) error {
		data, err := tx.Get(ctx, key).Bytes()
		if err != nil {
			if errors.Is(err, redis.Nil) {
				return ErrSessionNotFound
			}
			return err
		}

		var session CallSession
		if err := json.Unmarshal(data, &session); err != nil {
			return err
		}

		// Validate transition
		sm := NewStateMachineFrom(session.State)
		if err := sm.Transition(to); err != nil {
			return err
		}

		session.State = to
		if mutate != nil {
			mutate(&session)
		}

		updated, err := json.Marshal(session)
		if err != nil {
			return err
		}

		_, err = tx.TxPipelined(ctx, func(pipe redis.Pipeliner) error {
			pipe.Set(ctx, key, updated, 24*time.Hour)
			return nil
		})
		return err
	}, key)

	if err != nil {
		if errors.Is(err, redis.TxFailedErr) {
			return ErrConcurrentWrite
		}
		return err
	}
	return nil
}

// End transitions the session to ENDED, clears active call keys.
func (s *SessionStore) End(ctx context.Context, callID, reason string) error {
	session, err := s.Get(ctx, callID)
	if err != nil {
		return err
	}

	err = s.TransitionState(ctx, callID, StateEnded, func(sess *CallSession) {
		sess.EndedAt = time.Now()
		sess.EndReason = reason
	})
	if err != nil {
		return err
	}

	// Clear active call markers
	pipe := s.rdb.TxPipeline()
	pipe.Del(ctx, userActiveCallKey(session.CallerID))
	pipe.Del(ctx, userActiveCallKey(session.CalleeID))
	_, err = pipe.Exec(ctx)

	return err
}

// GetUserActiveCall returns the active call ID for a user, or empty string.
func (s *SessionStore) GetUserActiveCall(ctx context.Context, userID string) (string, error) {
	callID, err := s.rdb.Get(ctx, userActiveCallKey(userID)).Result()
	if err != nil {
		if errors.Is(err, redis.Nil) {
			return "", nil
		}
		return "", err
	}
	return callID, nil
}

// FindGlareCall checks if calleeID has an active/ringing call TO callerID.
// Returns the conflicting call session if found (glare detected), or nil.
func (s *SessionStore) FindGlareCall(ctx context.Context, callerID, calleeID string) (*CallSession, error) {
	// Check if the callee already has an active call
	callID, err := s.GetUserActiveCall(ctx, calleeID)
	if err != nil || callID == "" {
		return nil, err
	}

	sess, err := s.Get(ctx, callID)
	if err != nil {
		return nil, err
	}

	// Glare: callee is the caller of the existing call, and the callerID is the callee
	if sess.CallerID == calleeID && sess.CalleeID == callerID && sess.State == StateRinging {
		return sess, nil
	}

	return nil, nil
}

// ScanActiveSessions scans Redis for all active sessions (for state recovery on startup).
func (s *SessionStore) ScanActiveSessions(ctx context.Context) ([]*CallSession, error) {
	var sessions []*CallSession
	var cursor uint64

	for {
		keys, nextCursor, err := s.rdb.Scan(ctx, cursor, "session:*", 100).Result()
		if err != nil {
			return nil, fmt.Errorf("scan sessions: %w", err)
		}

		for _, key := range keys {
			data, err := s.rdb.Get(ctx, key).Bytes()
			if err != nil {
				continue // skip deleted/expired
			}

			var sess CallSession
			if err := json.Unmarshal(data, &sess); err != nil {
				continue // skip corrupted
			}

			// Only include non-terminal sessions
			if sess.State != StateEnded && sess.State != StateCleanup {
				sessions = append(sessions, &sess)
			}
		}

		cursor = nextCursor
		if cursor == 0 {
			break
		}
	}

	return sessions, nil
}

// CheckMsgDedup checks if a message ID has been seen before.
// Returns true if duplicate (already processed). Sets the ID with 60s TTL if new.
func (s *SessionStore) CheckMsgDedup(ctx context.Context, msgID string) (bool, error) {
	if msgID == "" {
		return false, nil // No dedup for messages without ID
	}

	key := fmt.Sprintf("msgdedup:%s", msgID)
	set, err := s.rdb.SetNX(ctx, key, 1, 60*time.Second).Result()
	if err != nil {
		return false, err
	}

	return !set, nil // set=false means key already existed (duplicate)
}

// Delete removes a session and associated keys from Redis.
func (s *SessionStore) Delete(ctx context.Context, callID string) error {
	session, err := s.Get(ctx, callID)
	if err != nil {
		if errors.Is(err, ErrSessionNotFound) {
			return nil
		}
		return err
	}

	pipe := s.rdb.TxPipeline()
	pipe.Del(ctx, sessionKey(callID))
	pipe.Del(ctx, userActiveCallKey(session.CallerID))
	pipe.Del(ctx, userActiveCallKey(session.CalleeID))
	_, err = pipe.Exec(ctx)
	return err
}

// CheckRateLimit checks if a rate limit has been exceeded for the given key.
// It uses a Redis INCR + EXPIRE pattern. Returns true if rate limited.
func (s *SessionStore) CheckRateLimit(ctx context.Context, key string, maxCount int64, windowSecs int) (bool, error) {
	fullKey := "ratelimit:" + key
	count, err := s.rdb.Incr(ctx, fullKey).Result()
	if err != nil {
		return false, fmt.Errorf("rate limit incr: %w", err)
	}

	// Set expiry on first increment
	if count == 1 {
		s.rdb.Expire(ctx, fullKey, time.Duration(windowSecs)*time.Second)
	}

	return count > maxCount, nil
}
