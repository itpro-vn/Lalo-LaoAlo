package push

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"time"

	"github.com/minhgv/lalo/internal/events"
)

// Gateway is the push notification gateway that routes incoming call
// notifications to the appropriate platform sender (APNs/FCM).
type Gateway struct {
	store     *Store
	apns      Sender
	fcm       Sender
	bus       *events.Bus
	ringTTL   int // seconds, from call config ring_timeout_seconds

	// For tracking delivery results
	onAllFailed func(callID, callerID string) // callback when all devices fail
}

// GatewayConfig holds gateway configuration.
type GatewayConfig struct {
	RingTimeoutSeconds int
	OnAllFailed        func(callID, callerID string)
}

// NewGateway creates a new push gateway.
func NewGateway(store *Store, apns Sender, fcm Sender, bus *events.Bus, cfg GatewayConfig) *Gateway {
	ttl := cfg.RingTimeoutSeconds
	if ttl == 0 {
		ttl = 45
	}
	return &Gateway{
		store:       store,
		apns:        apns,
		fcm:         fcm,
		bus:         bus,
		ringTTL:     ttl,
		onAllFailed: cfg.OnAllFailed,
	}
}

// SendIncomingCallPush sends push notifications to all active devices of the callee.
// It sends to ALL devices concurrently; first device to accept wins (handled by signaling).
func (g *Gateway) SendIncomingCallPush(ctx context.Context, push *IncomingCallPush, calleeID string) (*PushResult, error) {
	tokens, err := g.store.GetActiveTokens(ctx, calleeID)
	if err != nil {
		return nil, fmt.Errorf("get active tokens: %w", err)
	}

	if len(tokens) == 0 {
		return &PushResult{
			UserID:    calleeID,
			CallID:    push.CallID,
			AllFailed: true,
		}, ErrNoActiveTokens
	}

	// Set TTL if not provided
	if push.TTL == 0 {
		push.TTL = g.ringTTL
	}
	if push.Timestamp == 0 {
		push.Timestamp = time.Now().Unix()
	}

	result := &PushResult{
		UserID: calleeID,
		CallID: push.CallID,
	}

	// Send to all devices concurrently
	type deliveryMsg struct {
		result DeliveryResult
		token  string // for invalidation
	}

	ch := make(chan deliveryMsg, len(tokens))

	for _, t := range tokens {
		go func(tok PushToken) {
			dr := DeliveryResult{
				DeviceID: tok.DeviceID,
				Platform: tok.Platform,
				SentAt:   time.Now(),
			}

			var sendErr error
			switch tok.Platform {
			case PlatformIOS:
				// Use VoIP token for iOS if available, otherwise push token
				pushToken := tok.VoIPToken
				if pushToken == "" {
					pushToken = tok.PushToken
				}
				if g.apns != nil {
					sendErr = g.sendWithRetry(ctx, g.apns, pushToken, push, 0) // No retry for APNs
				} else {
					sendErr = fmt.Errorf("APNs sender not configured")
				}
			case PlatformAndroid:
				if g.fcm != nil {
					sendErr = g.sendWithRetry(ctx, g.fcm, tok.PushToken, push, 1) // 1 retry for FCM
				} else {
					sendErr = fmt.Errorf("FCM sender not configured")
				}
			default:
				sendErr = fmt.Errorf("unsupported platform: %s", tok.Platform)
			}

			if sendErr != nil {
				dr.Status = DeliveryStatusFailed
				dr.Error = sendErr.Error()
			} else {
				dr.Status = DeliveryStatusSent
			}

			ch <- deliveryMsg{result: dr, token: tok.PushToken}
		}(t)
	}

	// Collect results
	allFailed := true
	for range tokens {
		msg := <-ch
		result.Devices = append(result.Devices, msg.result)

		if msg.result.Status == DeliveryStatusSent {
			allFailed = false
		}

		// Auto-invalidate tokens that are gone/unregistered
		if msg.result.Status == DeliveryStatusFailed {
			if IsGoneError(fmt.Errorf("%s", msg.result.Error)) || IsUnregisteredError(fmt.Errorf("%s", msg.result.Error)) {
				if err := g.store.InvalidateToken(ctx, msg.token); err != nil {
					log.Printf("failed to invalidate token: %v", err)
				}
			}
		}
	}

	result.AllFailed = allFailed

	// Publish delivery event
	g.publishDeliveryResult(ctx, result)

	// Notify caller if all devices failed
	if allFailed && g.onAllFailed != nil {
		g.onAllFailed(push.CallID, push.CallerID)
	}

	return result, nil
}

// sendWithRetry attempts to send a push with the specified number of retries.
// APNs: maxRetries=0 (no retry per spec), FCM: maxRetries=1 (1 retry after 2s).
func (g *Gateway) sendWithRetry(ctx context.Context, sender Sender, token string, payload *IncomingCallPush, maxRetries int) error {
	var lastErr error
	for attempt := 0; attempt <= maxRetries; attempt++ {
		if attempt > 0 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(2 * time.Second): // 2s backoff before retry
			}
		}

		lastErr = sender.Send(ctx, token, payload)
		if lastErr == nil {
			return nil
		}

		// Don't retry if token is invalid
		if IsGoneError(lastErr) || IsUnregisteredError(lastErr) {
			return lastErr
		}
	}
	return lastErr
}

// SubscribeToCallEvents subscribes to NATS call.initiated events
// and sends push notifications when callee may be offline.
func (g *Gateway) SubscribeToCallEvents(ctx context.Context) error {
	return g.bus.Subscribe(ctx, events.SubjectCallInitiated, "push-gateway", func(env events.Envelope, raw []byte) error {
		payloadBytes, err := json.Marshal(env.Payload)
		if err != nil {
			log.Printf("push: failed to marshal payload: %v", err)
			return nil
		}

		var callEvent events.CallInitiated
		if err := json.Unmarshal(payloadBytes, &callEvent); err != nil {
			log.Printf("push: failed to unmarshal call initiated: %v", err)
			return nil
		}

		callType := "audio"
		if callEvent.HasVideo {
			callType = "video"
		}

		push := &IncomingCallPush{
			CallID:    callEvent.CallID,
			CallerID:  callEvent.CallerID,
			CallType:  callType,
			Timestamp: time.Now().Unix(),
			TTL:       g.ringTTL,
		}

		// TODO: lookup caller name/avatar from user service
		push.CallerName = callEvent.CallerID // fallback to ID

		result, err := g.SendIncomingCallPush(ctx, push, callEvent.CalleeID)
		if err != nil {
			log.Printf("push: send failed for call %s to user %s: %v", callEvent.CallID, callEvent.CalleeID, err)
		} else {
			log.Printf("push: sent for call %s to %d devices (all_failed=%v)", callEvent.CallID, len(result.Devices), result.AllFailed)
		}

		return nil // always ack
	})
}

// publishDeliveryResult publishes a push delivery event to NATS.
func (g *Gateway) publishDeliveryResult(ctx context.Context, result *PushResult) {
	if g.bus == nil {
		return
	}

	if err := g.bus.Publish(ctx, events.SubjectPushDelivery, result); err != nil {
		log.Printf("push: failed to publish delivery result: %v", err)
	}
}
