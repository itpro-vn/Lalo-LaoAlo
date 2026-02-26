package push

import "context"

// Sender is the interface for platform-specific push notification delivery.
type Sender interface {
	// Send delivers a push notification to a single device.
	// Returns the delivery status and any error.
	Send(ctx context.Context, token string, payload *IncomingCallPush) error

	// Platform returns the platform this sender handles.
	Platform() Platform
}
