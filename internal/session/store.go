package session

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/minhgv/lalo/internal/models"
	"github.com/redis/go-redis/v9"
)

// Store manages orchestrator session state in Redis.
type Store struct {
	rdb *redis.Client
}

var (
	ErrSessionNotFound = errors.New("session not found")
	ErrUserBusy        = errors.New("user already in active call")
	ErrAlreadyInCall   = errors.New("user already in this call")
	ErrMaxParticipants = errors.New("maximum participants reached")
)

// NewStore creates a new Redis-backed session store.
func NewStore(rdb *redis.Client) *Store {
	return &Store{rdb: rdb}
}

// Create stores a new session in Redis and marks initiator as busy.
func (s *Store) Create(ctx context.Context, sess *Session) error {
	// Check initiator is free
	exists, err := s.rdb.Exists(ctx, models.UserActiveCallKey(sess.InitiatorID)).Result()
	if err != nil {
		return fmt.Errorf("check user busy: %w", err)
	}
	if exists > 0 {
		return ErrUserBusy
	}

	data, err := json.Marshal(sess)
	if err != nil {
		return fmt.Errorf("marshal session: %w", err)
	}

	pipe := s.rdb.TxPipeline()
	key := models.SessionKey(sess.CallID)
	ttl := time.Duration(models.SessionTTL) * time.Second

	pipe.Set(ctx, key, data, ttl)

	// Mark all initial participants as having an active call
	for _, p := range sess.Participants {
		pipe.Set(ctx, models.UserActiveCallKey(p.UserID), sess.CallID, ttl)
	}

	// Add participants to the participants set
	for _, p := range sess.Participants {
		pipe.SAdd(ctx, models.SessionParticipantsKey(sess.CallID), p.UserID)
	}
	pipe.Expire(ctx, models.SessionParticipantsKey(sess.CallID), ttl)

	_, err = pipe.Exec(ctx)
	if err != nil {
		return fmt.Errorf("create session: %w", err)
	}
	return nil
}

// Get retrieves a session from Redis.
func (s *Store) Get(ctx context.Context, callID string) (*Session, error) {
	data, err := s.rdb.Get(ctx, models.SessionKey(callID)).Bytes()
	if err != nil {
		if errors.Is(err, redis.Nil) {
			return nil, ErrSessionNotFound
		}
		return nil, fmt.Errorf("get session: %w", err)
	}

	var sess Session
	if err := json.Unmarshal(data, &sess); err != nil {
		return nil, fmt.Errorf("unmarshal session: %w", err)
	}
	return &sess, nil
}

// Update saves the session back to Redis.
func (s *Store) Update(ctx context.Context, sess *Session) error {
	data, err := json.Marshal(sess)
	if err != nil {
		return fmt.Errorf("marshal session: %w", err)
	}

	ttl := time.Duration(models.SessionTTL) * time.Second
	return s.rdb.Set(ctx, models.SessionKey(sess.CallID), data, ttl).Err()
}

// AddParticipant adds a participant to the session.
func (s *Store) AddParticipant(ctx context.Context, callID string, p Participant, maxParticipants int) error {
	sess, err := s.Get(ctx, callID)
	if err != nil {
		return err
	}

	// Check if already in call
	if sess.FindParticipant(p.UserID) != nil {
		return ErrAlreadyInCall
	}

	// Check max participants
	if len(sess.ActiveParticipants()) >= maxParticipants {
		return ErrMaxParticipants
	}

	// Check user is free
	exists, err := s.rdb.Exists(ctx, models.UserActiveCallKey(p.UserID)).Result()
	if err != nil {
		return fmt.Errorf("check user busy: %w", err)
	}
	if exists > 0 {
		return ErrUserBusy
	}

	sess.Participants = append(sess.Participants, p)

	ttl := time.Duration(models.SessionTTL) * time.Second
	pipe := s.rdb.TxPipeline()

	data, err := json.Marshal(sess)
	if err != nil {
		return fmt.Errorf("marshal session: %w", err)
	}

	pipe.Set(ctx, models.SessionKey(callID), data, ttl)
	pipe.Set(ctx, models.UserActiveCallKey(p.UserID), callID, ttl)
	pipe.SAdd(ctx, models.SessionParticipantsKey(callID), p.UserID)

	_, err = pipe.Exec(ctx)
	return err
}

// RemoveParticipant marks a participant as having left the session.
func (s *Store) RemoveParticipant(ctx context.Context, callID, userID string) (*Session, error) {
	sess, err := s.Get(ctx, callID)
	if err != nil {
		return nil, err
	}

	p := sess.FindParticipant(userID)
	if p == nil {
		return sess, nil // not in call, no-op
	}

	p.LeftAt = time.Now()

	pipe := s.rdb.TxPipeline()

	data, err := json.Marshal(sess)
	if err != nil {
		return nil, fmt.Errorf("marshal session: %w", err)
	}

	ttl := time.Duration(models.SessionTTL) * time.Second
	pipe.Set(ctx, models.SessionKey(callID), data, ttl)
	pipe.Del(ctx, models.UserActiveCallKey(userID))
	pipe.SRem(ctx, models.SessionParticipantsKey(callID), userID)

	_, err = pipe.Exec(ctx)
	if err != nil {
		return nil, fmt.Errorf("remove participant: %w", err)
	}

	return sess, nil
}

// EndSession marks the session as ended and clears all active call markers.
func (s *Store) EndSession(ctx context.Context, callID, reason string) (*Session, error) {
	sess, err := s.Get(ctx, callID)
	if err != nil {
		return nil, err
	}

	sess.EndedAt = time.Now()
	sess.EndReason = reason

	// Mark all remaining active participants as left
	for i := range sess.Participants {
		if sess.Participants[i].LeftAt.IsZero() {
			sess.Participants[i].LeftAt = sess.EndedAt
		}
	}

	pipe := s.rdb.TxPipeline()

	data, err := json.Marshal(sess)
	if err != nil {
		return nil, fmt.Errorf("marshal session: %w", err)
	}

	// Keep session data for CDR processing, shorter TTL
	pipe.Set(ctx, models.SessionKey(callID), data, 1*time.Hour)

	// Clear all active call markers
	for _, p := range sess.Participants {
		pipe.Del(ctx, models.UserActiveCallKey(p.UserID))
	}
	pipe.Del(ctx, models.SessionParticipantsKey(callID))

	_, err = pipe.Exec(ctx)
	if err != nil {
		return nil, fmt.Errorf("end session: %w", err)
	}

	return sess, nil
}

// Delete removes a session entirely from Redis.
func (s *Store) Delete(ctx context.Context, callID string) error {
	sess, err := s.Get(ctx, callID)
	if err != nil {
		if errors.Is(err, ErrSessionNotFound) {
			return nil
		}
		return err
	}

	pipe := s.rdb.TxPipeline()
	pipe.Del(ctx, models.SessionKey(callID))
	pipe.Del(ctx, models.SessionParticipantsKey(callID))
	for _, p := range sess.Participants {
		pipe.Del(ctx, models.UserActiveCallKey(p.UserID))
	}
	_, err = pipe.Exec(ctx)
	return err
}
