package metrics

import (
	"encoding/json"
	"fmt"

	"github.com/minhgv/lalo/internal/events"
)

// decodePayload decodes a raw NATS message body into a QualityMetrics struct.
func decodePayload(raw []byte, out *events.QualityMetrics) error {
	// The raw bytes are the full Envelope JSON; extract payload
	var env struct {
		Payload json.RawMessage `json:"payload"`
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		return fmt.Errorf("unmarshal envelope: %w", err)
	}
	if err := json.Unmarshal(env.Payload, out); err != nil {
		return fmt.Errorf("unmarshal payload: %w", err)
	}
	return nil
}
