package events

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

// Bus is the NATS JetStream event bus wrapper.
type Bus struct {
	nc     *nats.Conn
	js     jetstream.JetStream
	source string // service name for Envelope.Source

	mu   sync.Mutex
	subs []jetstream.ConsumeContext
}

// BusConfig holds NATS connection settings.
type BusConfig struct {
	URL            string
	Source         string        // service name (e.g. "signaling", "orchestrator")
	MaxReconnects  int
	ReconnectWait  time.Duration
	ConnectTimeout time.Duration
}

// DefaultBusConfig returns a config with sensible defaults.
func DefaultBusConfig(source string) BusConfig {
	return BusConfig{
		URL:            nats.DefaultURL,
		Source:         source,
		MaxReconnects:  -1, // unlimited reconnects
		ReconnectWait:  2 * time.Second,
		ConnectTimeout: 10 * time.Second,
	}
}

// NewBus connects to NATS, creates JetStream context, and ensures
// the CALLS stream exists.
func NewBus(cfg BusConfig) (*Bus, error) {
	opts := []nats.Option{
		nats.MaxReconnects(cfg.MaxReconnects),
		nats.ReconnectWait(cfg.ReconnectWait),
		nats.Timeout(cfg.ConnectTimeout),
		nats.DisconnectErrHandler(func(_ *nats.Conn, err error) {
			log.Printf("[events] NATS disconnected: %v", err)
		}),
		nats.ReconnectHandler(func(nc *nats.Conn) {
			log.Printf("[events] NATS reconnected to %s", nc.ConnectedUrl())
		}),
		nats.ClosedHandler(func(nc *nats.Conn) {
			log.Printf("[events] NATS connection closed: %v", nc.LastError())
		}),
	}

	nc, err := nats.Connect(cfg.URL, opts...)
	if err != nil {
		return nil, fmt.Errorf("nats connect: %w", err)
	}

	js, err := jetstream.New(nc)
	if err != nil {
		nc.Close()
		return nil, fmt.Errorf("jetstream init: %w", err)
	}

	bus := &Bus{
		nc:     nc,
		js:     js,
		source: cfg.Source,
	}

	if err := bus.ensureStream(context.Background()); err != nil {
		nc.Close()
		return nil, fmt.Errorf("ensure stream: %w", err)
	}

	return bus, nil
}

// ensureStream creates or updates the CALLS JetStream stream.
func (b *Bus) ensureStream(ctx context.Context) error {
	subjects := make([]string, 0, len(AllSubjects()))
	for _, s := range AllSubjects() {
		subjects = append(subjects, s)
	}

	_, err := b.js.CreateOrUpdateStream(ctx, jetstream.StreamConfig{
		Name:      StreamName,
		Subjects:  subjects,
		Retention: jetstream.InterestPolicy,
		MaxAge:    time.Duration(StreamMaxAge) * time.Second,
		Replicas:  StreamReplicas,
		Storage:   jetstream.FileStorage,
	})
	return err
}

// Publish serializes and publishes an event to the given subject.
func (b *Bus) Publish(ctx context.Context, subject string, payload any) error {
	env := Envelope{
		ID:        uuid.NewString(),
		Type:      subject,
		Timestamp: time.Now().UTC(),
		Source:    b.source,
		Payload:   payload,
	}

	data, err := json.Marshal(env)
	if err != nil {
		return fmt.Errorf("marshal event: %w", err)
	}

	_, err = b.js.Publish(ctx, subject, data)
	if err != nil {
		return fmt.Errorf("publish %s: %w", subject, err)
	}

	return nil
}

// Handler is a callback for received events. The raw envelope is
// provided for metadata; the caller is responsible for unmarshaling
// Payload to the correct type.
type Handler func(env Envelope, raw []byte) error

// Subscribe creates a durable JetStream consumer for the given
// subject pattern. consumerName must be unique per subscriber.
func (b *Bus) Subscribe(ctx context.Context, subject, consumerName string, handler Handler) error {
	cons, err := b.js.CreateOrUpdateConsumer(ctx, StreamName, jetstream.ConsumerConfig{
		Durable:       consumerName,
		FilterSubject: subject,
		AckPolicy:     jetstream.AckExplicitPolicy,
		DeliverPolicy: jetstream.DeliverNewPolicy,
		AckWait:       30 * time.Second,
		MaxDeliver:    5,
	})
	if err != nil {
		return fmt.Errorf("create consumer %s: %w", consumerName, err)
	}

	cc, err := cons.Consume(func(msg jetstream.Msg) {
		var env Envelope
		if err := json.Unmarshal(msg.Data(), &env); err != nil {
			log.Printf("[events] unmarshal error on %s: %v", subject, err)
			// Terminate — don't redeliver malformed messages
			_ = msg.Term()
			return
		}

		if err := handler(env, msg.Data()); err != nil {
			log.Printf("[events] handler error on %s: %v", subject, err)
			_ = msg.Nak()
			return
		}

		_ = msg.Ack()
	})
	if err != nil {
		return fmt.Errorf("consume %s: %w", subject, err)
	}

	b.mu.Lock()
	b.subs = append(b.subs, cc)
	b.mu.Unlock()

	return nil
}

// Close drains all subscriptions and closes the NATS connection.
func (b *Bus) Close() {
	b.mu.Lock()
	for _, cc := range b.subs {
		cc.Stop()
	}
	b.subs = nil
	b.mu.Unlock()

	if b.nc != nil {
		b.nc.Drain()
	}
}

// IsConnected returns true if the NATS connection is active.
func (b *Bus) IsConnected() bool {
	return b.nc != nil && b.nc.IsConnected()
}
