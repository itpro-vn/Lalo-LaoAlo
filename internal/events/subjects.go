// Package events provides the NATS JetStream event bus for internal
// service communication. It defines event subjects, message types,
// and a client wrapper with automatic reconnection.
package events

// NATS subject hierarchy for call system events.
const (
	// Call lifecycle events
	SubjectCallInitiated    = "call.initiated"
	SubjectCallAccepted     = "call.accepted"
	SubjectCallRejected     = "call.rejected"
	SubjectCallEnded        = "call.ended"
	SubjectCallStateChanged = "call.state_changed"

	// Quality events
	SubjectQualityTierChanged = "quality.tier_changed"
	SubjectQualityMetrics     = "quality.metrics"

	// Presence events
	SubjectPresenceUpdated = "presence.updated"

	// SFU events (from LiveKit webhooks)
	SubjectSFUParticipantJoined = "sfu.participant_joined"
	SubjectSFUParticipantLeft   = "sfu.participant_left"
	SubjectSFURoomFinished      = "sfu.room_finished"
	SubjectSFUTrackPublished    = "sfu.track_published"

	// Push notification events
	SubjectPushDelivery = "push.delivery"

	// Room/group call events
	SubjectRoomCreated           = "room.created"
	SubjectRoomClosed            = "room.closed"
	SubjectRoomParticipantJoined = "room.participant_joined"
	SubjectRoomParticipantLeft   = "room.participant_left"
)

// AllSubjects returns all defined event subjects.
func AllSubjects() []string {
	return []string{
		SubjectCallInitiated,
		SubjectCallAccepted,
		SubjectCallRejected,
		SubjectCallEnded,
		SubjectCallStateChanged,
		SubjectQualityTierChanged,
		SubjectQualityMetrics,
		SubjectPresenceUpdated,
		SubjectSFUParticipantJoined,
		SubjectSFUParticipantLeft,
		SubjectSFURoomFinished,
		SubjectSFUTrackPublished,
		SubjectPushDelivery,
		SubjectRoomCreated,
		SubjectRoomClosed,
		SubjectRoomParticipantJoined,
		SubjectRoomParticipantLeft,
	}
}

// JetStream stream configuration constants.
const (
	// StreamName is the JetStream stream name for call events.
	StreamName = "CALLS"

	// StreamMaxAge is the maximum age for messages in the stream (7 days).
	StreamMaxAge = 7 * 24 * 60 * 60 // seconds

	// StreamReplicas is the number of stream replicas for HA.
	StreamReplicas = 1 // increase to 3 in production cluster
)
