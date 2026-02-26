package session

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"time"

	"github.com/minhgv/lalo/internal/events"
)

// CDRWriter handles CDR generation and persistence.
type CDRWriter struct {
	db  *sql.DB
	bus *events.Bus
}

// NewCDRWriter creates a CDR writer with Postgres and event bus access.
func NewCDRWriter(db *sql.DB, bus *events.Bus) *CDRWriter {
	return &CDRWriter{db: db, bus: bus}
}

// GenerateCDR creates a CDR from a completed session.
func GenerateCDR(sess *Session) *CDR {
	duration := 0
	if !sess.EndedAt.IsZero() && !sess.CreatedAt.IsZero() {
		duration = int(sess.EndedAt.Sub(sess.CreatedAt).Seconds())
	}

	return &CDR{
		CallID:           sess.CallID,
		CallType:         sess.CallType,
		InitiatorID:      sess.InitiatorID,
		Topology:         string(sess.Topology),
		Region:           sess.Region,
		StartedAt:        sess.CreatedAt,
		EndedAt:          sess.EndedAt,
		DurationSeconds:  duration,
		EndReason:        sess.EndReason,
		ParticipantCount: len(sess.Participants),
		HasVideo:         sess.HasVideo,
	}
}

// WriteCallHistory writes a call record to Postgres (synchronous).
func (w *CDRWriter) WriteCallHistory(ctx context.Context, cdr *CDR) error {
	query := `
		INSERT INTO call_history (
			call_id, call_type, initiator_id, topology, region,
			started_at, ended_at, duration_seconds, end_reason
		) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
		ON CONFLICT (call_id) DO UPDATE SET
			ended_at = EXCLUDED.ended_at,
			duration_seconds = EXCLUDED.duration_seconds,
			end_reason = EXCLUDED.end_reason`

	_, err := w.db.ExecContext(ctx, query,
		cdr.CallID,
		cdr.CallType,
		cdr.InitiatorID,
		cdr.Topology,
		cdr.Region,
		cdr.StartedAt,
		cdr.EndedAt,
		cdr.DurationSeconds,
		cdr.EndReason,
	)
	if err != nil {
		return fmt.Errorf("write call history: %w", err)
	}
	return nil
}

// WriteCallParticipants writes participant records to Postgres.
func (w *CDRWriter) WriteCallParticipants(ctx context.Context, callID string, participants []Participant) error {
	query := `
		INSERT INTO call_participants (call_id, user_id, role, joined_at, left_at)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (call_id, user_id) DO UPDATE SET
			left_at = EXCLUDED.left_at`

	for _, p := range participants {
		var leftAt *time.Time
		if !p.LeftAt.IsZero() {
			leftAt = &p.LeftAt
		}
		_, err := w.db.ExecContext(ctx, query,
			callID, p.UserID, string(p.Role), p.JoinedAt, leftAt,
		)
		if err != nil {
			return fmt.Errorf("write participant %s: %w", p.UserID, err)
		}
	}
	return nil
}

// PublishCDR publishes the CDR event to NATS for async ClickHouse ingestion.
func (w *CDRWriter) PublishCDR(ctx context.Context, cdr *CDR) error {
	return w.bus.Publish(ctx, events.SubjectCallEnded, events.CallEnded{
		CallID:    cdr.CallID,
		EndReason: cdr.EndReason,
		Duration:  cdr.DurationSeconds,
	})
}

// WriteFull writes call history to Postgres and publishes CDR event.
func (w *CDRWriter) WriteFull(ctx context.Context, sess *Session) {
	cdr := GenerateCDR(sess)

	// Sync: write to Postgres
	if err := w.WriteCallHistory(ctx, cdr); err != nil {
		log.Printf("[cdr] failed to write call history: %v", err)
	}
	if err := w.WriteCallParticipants(ctx, sess.CallID, sess.Participants); err != nil {
		log.Printf("[cdr] failed to write participants: %v", err)
	}

	// Async: publish CDR event for ClickHouse ingestion
	if err := w.PublishCDR(ctx, cdr); err != nil {
		log.Printf("[cdr] failed to publish CDR event: %v", err)
	}
}
