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
	CallID      string    `json:"call_id"`
	CallerID    string    `json:"caller_id"`
	CalleeID    string    `json:"callee_id"`
	CallType    string    `json:"call_type"`
	State       CallState `json:"state"`
	SDPOffer    string    `json:"sdp_offer,omitempty"`
	SDPAnswer   string    `json:"sdp_answer,omitempty"`
	StartedAt   time.Time `json:"started_at"`
	AnsweredAt  time.Time `json:"answered_at,omitempty"`
	EndedAt     time.Time `json:"ended_at,omitempty"`
	EndReason   string    `json:"end_reason,omitempty"`
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
