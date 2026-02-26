package livekit

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"

	"github.com/livekit/protocol/auth"
	"github.com/livekit/protocol/webhook"
	"github.com/minhgv/lalo/internal/config"
	"github.com/minhgv/lalo/internal/events"
	livekit "github.com/livekit/protocol/livekit"
)

// WebhookHandler processes incoming LiveKit webhook events
// and publishes them to the NATS event bus.
type WebhookHandler struct {
	provider *auth.SimpleKeyProvider
	bus      *events.Bus
	cfg      config.LiveKitConfig
	notifier WebhookNotifier
}

// WebhookNotifier is an optional callback for webhook events.
// Used by the orchestrator to react to SFU events.
type WebhookNotifier interface {
	OnParticipantJoined(ctx context.Context, roomName, identity string)
	OnParticipantLeft(ctx context.Context, roomName, identity string)
	OnRoomFinished(ctx context.Context, roomName string)
	OnTrackPublished(ctx context.Context, roomName, identity string, track *livekit.TrackInfo)
}

// NewWebhookHandler creates a webhook handler with API key validation.
func NewWebhookHandler(cfg config.LiveKitConfig, bus *events.Bus, notifier WebhookNotifier) *WebhookHandler {
	provider := auth.NewSimpleKeyProvider(cfg.APIKey, cfg.APISecret)
	return &WebhookHandler{
		provider: provider,
		bus:      bus,
		cfg:      cfg,
		notifier: notifier,
	}
}

// ServeHTTP handles incoming LiveKit webhook POST requests.
// It validates the webhook signature using the API key/secret.
func (h *WebhookHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	event, err := webhook.ReceiveWebhookEvent(r, h.provider)
	if err != nil {
		log.Printf("webhook validation failed: %v", err)
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	ctx := r.Context()

	switch event.GetEvent() {
	case webhook.EventParticipantJoined:
		h.handleParticipantJoined(ctx, event)
	case webhook.EventParticipantLeft:
		h.handleParticipantLeft(ctx, event)
	case webhook.EventRoomFinished:
		h.handleRoomFinished(ctx, event)
	case webhook.EventTrackPublished:
		h.handleTrackPublished(ctx, event)
	default:
		log.Printf("unhandled webhook event: %s", event.GetEvent())
	}

	w.WriteHeader(http.StatusOK)
}

func (h *WebhookHandler) handleParticipantJoined(ctx context.Context, event *livekit.WebhookEvent) {
	room := event.GetRoom()
	participant := event.GetParticipant()
	if room == nil || participant == nil {
		return
	}

	log.Printf("participant joined: room=%s identity=%s", room.Name, participant.Identity)

	// Publish to NATS
	if h.bus != nil {
		payload := SFUParticipantEvent{
			RoomName:    room.Name,
			Identity:    participant.Identity,
			ParticipantSID: participant.Sid,
			JoinedAt:    participant.JoinedAt,
		}
		if err := h.bus.Publish(ctx, sfuParticipantJoined, payload); err != nil {
			log.Printf("failed to publish participant joined event: %v", err)
		}
	}

	// Notify orchestrator
	if h.notifier != nil {
		h.notifier.OnParticipantJoined(ctx, room.Name, participant.Identity)
	}
}

func (h *WebhookHandler) handleParticipantLeft(ctx context.Context, event *livekit.WebhookEvent) {
	room := event.GetRoom()
	participant := event.GetParticipant()
	if room == nil || participant == nil {
		return
	}

	log.Printf("participant left: room=%s identity=%s", room.Name, participant.Identity)

	if h.bus != nil {
		payload := SFUParticipantEvent{
			RoomName:    room.Name,
			Identity:    participant.Identity,
			ParticipantSID: participant.Sid,
		}
		if err := h.bus.Publish(ctx, sfuParticipantLeft, payload); err != nil {
			log.Printf("failed to publish participant left event: %v", err)
		}
	}

	if h.notifier != nil {
		h.notifier.OnParticipantLeft(ctx, room.Name, participant.Identity)
	}
}

func (h *WebhookHandler) handleRoomFinished(ctx context.Context, event *livekit.WebhookEvent) {
	room := event.GetRoom()
	if room == nil {
		return
	}

	log.Printf("room finished: room=%s", room.Name)

	if h.bus != nil {
		payload := SFURoomEvent{
			RoomName: room.Name,
			RoomSID:  room.Sid,
		}
		if err := h.bus.Publish(ctx, sfuRoomFinished, payload); err != nil {
			log.Printf("failed to publish room finished event: %v", err)
		}
	}

	if h.notifier != nil {
		h.notifier.OnRoomFinished(ctx, room.Name)
	}
}

func (h *WebhookHandler) handleTrackPublished(ctx context.Context, event *livekit.WebhookEvent) {
	room := event.GetRoom()
	participant := event.GetParticipant()
	track := event.GetTrack()
	if room == nil || participant == nil || track == nil {
		return
	}

	log.Printf("track published: room=%s identity=%s track=%s type=%s",
		room.Name, participant.Identity, track.Sid, track.Type.String())

	if h.bus != nil {
		payload := SFUTrackEvent{
			RoomName:  room.Name,
			Identity:  participant.Identity,
			TrackSID:  track.Sid,
			TrackType: track.Type.String(),
			Simulcast: track.Simulcast,
		}
		if err := h.bus.Publish(ctx, sfuTrackPublished, payload); err != nil {
			log.Printf("failed to publish track published event: %v", err)
		}
	}

	if h.notifier != nil {
		h.notifier.OnTrackPublished(ctx, room.Name, participant.Identity, track)
	}
}

// SFUParticipantEvent is published when a participant joins/leaves a LiveKit room.
type SFUParticipantEvent struct {
	RoomName       string `json:"room_name"`
	Identity       string `json:"identity"`
	ParticipantSID string `json:"participant_sid"`
	JoinedAt       int64  `json:"joined_at,omitempty"`
}

// SFURoomEvent is published when a LiveKit room is created or finished.
type SFURoomEvent struct {
	RoomName string `json:"room_name"`
	RoomSID  string `json:"room_sid"`
}

// SFUTrackEvent is published when a track is published in a LiveKit room.
type SFUTrackEvent struct {
	RoomName  string `json:"room_name"`
	Identity  string `json:"identity"`
	TrackSID  string `json:"track_sid"`
	TrackType string `json:"track_type"`
	Simulcast bool   `json:"simulcast"`
}

// marshalJSON is a helper for JSON serialization.
func marshalJSON(v interface{}) string {
	b, _ := json.Marshal(v)
	return string(b)
}

// NATS subjects for SFU events — defined in events/subjects.go.
// Re-exported here for convenience within this package.
var (
	sfuParticipantJoined = events.SubjectSFUParticipantJoined
	sfuParticipantLeft   = events.SubjectSFUParticipantLeft
	sfuRoomFinished      = events.SubjectSFURoomFinished
	sfuTrackPublished    = events.SubjectSFUTrackPublished
)

// MediaConfig holds the media codec configuration for LiveKit rooms.
type MediaConfig struct {
	AudioCodec     string   `json:"audio_codec"`
	VideoCodecs    []string `json:"video_codecs"`
	SimulcastLayers int     `json:"simulcast_layers"`
	MaxResolution  string   `json:"max_resolution"`
	MaxFramerate   int      `json:"max_framerate"`
}

// DefaultMediaConfig returns the Phase A media configuration.
func DefaultMediaConfig() MediaConfig {
	return MediaConfig{
		AudioCodec:      "opus",
		VideoCodecs:     []string{"vp8", "h264"},
		SimulcastLayers:  3,
		MaxResolution:   "720p",
		MaxFramerate:    30,
	}
}

// String returns a human-readable representation of the media config.
func (m MediaConfig) String() string {
	return fmt.Sprintf("audio=%s video=%v simulcast=%d max=%s@%dfps",
		m.AudioCodec, m.VideoCodecs, m.SimulcastLayers, m.MaxResolution, m.MaxFramerate)
}
