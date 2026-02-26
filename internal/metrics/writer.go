package metrics

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/minhgv/lalo/internal/events"
)

// Writer batches QoS metrics from NATS and writes them to ClickHouse.
type Writer struct {
	db  *sql.DB
	bus *events.Bus

	// Batching
	buffer    []metricsRow
	bufferMu  sync.Mutex
	batchSize int
	flushInterval time.Duration

	ctx    context.Context
	cancel context.CancelFunc
}

type metricsRow struct {
	CallID        string
	ParticipantID string
	Timestamp     time.Time
	Direction     string
	RTTMs         int
	LossPct       float64
	JitterMs      float64
	BitrateKbps   int
	Framerate     int
	Resolution    string
	NetworkTier   string
}

// WriterConfig configures the metrics writer.
type WriterConfig struct {
	BatchSize     int           // flush when buffer reaches this size (default: 100)
	FlushInterval time.Duration // flush at this interval regardless (default: 5s)
}

// DefaultWriterConfig returns sensible defaults.
func DefaultWriterConfig() WriterConfig {
	return WriterConfig{
		BatchSize:     100,
		FlushInterval: 5 * time.Second,
	}
}

// NewWriter creates a new ClickHouse metrics writer.
func NewWriter(db *sql.DB, bus *events.Bus, cfg WriterConfig) *Writer {
	if cfg.BatchSize <= 0 {
		cfg.BatchSize = 100
	}
	if cfg.FlushInterval <= 0 {
		cfg.FlushInterval = 5 * time.Second
	}

	ctx, cancel := context.WithCancel(context.Background())
	return &Writer{
		db:            db,
		bus:           bus,
		buffer:        make([]metricsRow, 0, cfg.BatchSize),
		batchSize:     cfg.BatchSize,
		flushInterval: cfg.FlushInterval,
		ctx:           ctx,
		cancel:        cancel,
	}
}

// Start subscribes to quality.metrics NATS subject and begins batch writing.
func (w *Writer) Start(ctx context.Context) error {
	err := w.bus.Subscribe(ctx, events.SubjectQualityMetrics, "metrics-writer", func(env events.Envelope, raw []byte) error {
		metrics, ok := env.Payload.(*events.QualityMetrics)
		if !ok {
			// Re-decode from raw
			var m events.QualityMetrics
			if err := decodePayload(raw, &m); err != nil {
				log.Printf("metrics-writer: failed to decode payload: %v", err)
				return nil // ack anyway, don't block
			}
			metrics = &m
		}

		w.ingest(metrics)
		return nil
	})
	if err != nil {
		return fmt.Errorf("subscribe to quality metrics: %w", err)
	}

	// Start periodic flusher
	go w.flushLoop()

	log.Printf("metrics-writer started (batch=%d, interval=%s)", w.batchSize, w.flushInterval)
	return nil
}

// Stop flushes remaining buffer and stops the writer.
func (w *Writer) Stop() {
	w.cancel()
	w.flush() // final flush
}

func (w *Writer) ingest(metrics *events.QualityMetrics) {
	w.bufferMu.Lock()
	defer w.bufferMu.Unlock()

	for _, s := range metrics.Samples {
		ts := time.UnixMilli(s.Timestamp)
		if s.Timestamp == 0 {
			ts = time.Now()
		}

		w.buffer = append(w.buffer, metricsRow{
			CallID:        metrics.CallID,
			ParticipantID: s.ParticipantID,
			Timestamp:     ts,
			Direction:     s.Direction,
			RTTMs:         s.RTTMs,
			LossPct:       s.LossPct,
			JitterMs:      s.JitterMs,
			BitrateKbps:   s.BitrateKbps,
			Framerate:     s.Framerate,
			Resolution:    s.Resolution,
			NetworkTier:   s.NetworkTier,
		})
	}

	if len(w.buffer) >= w.batchSize {
		w.flushLocked()
	}
}

func (w *Writer) flushLoop() {
	ticker := time.NewTicker(w.flushInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			w.flush()
		case <-w.ctx.Done():
			return
		}
	}
}

func (w *Writer) flush() {
	w.bufferMu.Lock()
	defer w.bufferMu.Unlock()
	w.flushLocked()
}

func (w *Writer) flushLocked() {
	if len(w.buffer) == 0 {
		return
	}

	batch := w.buffer
	w.buffer = make([]metricsRow, 0, w.batchSize)

	// Write in background to not block ingestion
	go func() {
		if err := w.writeBatch(batch); err != nil {
			log.Printf("metrics-writer: batch write failed (%d rows): %v", len(batch), err)
		}
	}()
}

func (w *Writer) writeBatch(rows []metricsRow) error {
	if w.db == nil {
		log.Printf("metrics-writer: no database connection, discarding %d rows", len(rows))
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	tx, err := w.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}

	stmt, err := tx.PrepareContext(ctx,
		`INSERT INTO qos_metrics (call_id, participant_id, ts, direction, rtt_ms, packet_loss_pct, jitter_ms, bitrate_kbps, framerate, resolution, network_tier) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
	if err != nil {
		tx.Rollback()
		return fmt.Errorf("prepare stmt: %w", err)
	}
	defer stmt.Close()

	for _, r := range rows {
		_, err := stmt.ExecContext(ctx,
			r.CallID, r.ParticipantID, r.Timestamp,
			r.Direction, r.RTTMs, r.LossPct, r.JitterMs,
			r.BitrateKbps, r.Framerate, r.Resolution, r.NetworkTier,
		)
		if err != nil {
			tx.Rollback()
			return fmt.Errorf("exec insert: %w", err)
		}
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit: %w", err)
	}

	log.Printf("metrics-writer: wrote %d rows to ClickHouse", len(rows))
	return nil
}

// BufferLen returns the current buffer length (for testing).
func (w *Writer) BufferLen() int {
	w.bufferMu.Lock()
	defer w.bufferMu.Unlock()
	return len(w.buffer)
}
