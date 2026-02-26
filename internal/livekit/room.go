// Package livekit provides LiveKit SFU integration for room management
// and webhook event handling.
package livekit

import (
	"context"
	"fmt"
	"time"

	lksdk "github.com/livekit/server-sdk-go/v2"
	"github.com/minhgv/lalo/internal/config"
	livekit "github.com/livekit/protocol/livekit"
)

// RoomService manages LiveKit rooms: creation, deletion, and querying.
type RoomService struct {
	client *lksdk.RoomServiceClient
	cfg    config.LiveKitConfig
}

// NewRoomService creates a new LiveKit room service.
func NewRoomService(cfg config.LiveKitConfig) *RoomService {
	client := lksdk.NewRoomServiceClient(cfg.Host, cfg.APIKey, cfg.APISecret)
	return &RoomService{
		client: client,
		cfg:    cfg,
	}
}

// CreateRoomRequest specifies parameters for room creation.
type CreateRoomRequest struct {
	// RoomName is typically the call ID.
	RoomName string
	// MaxParticipants defaults to 8 if not set.
	MaxParticipants uint32
	// EmptyTimeout is how long an empty room stays alive (seconds).
	// Defaults to 300 (5 min).
	EmptyTimeout uint32
	// Metadata is optional JSON metadata attached to the room.
	Metadata string
}

// CreateRoom provisions a new LiveKit room for a call session.
func (s *RoomService) CreateRoom(ctx context.Context, req CreateRoomRequest) (*livekit.Room, error) {
	maxP := req.MaxParticipants
	if maxP == 0 {
		maxP = 8
	}
	emptyTimeout := req.EmptyTimeout
	if emptyTimeout == 0 {
		emptyTimeout = 300 // 5 min
	}

	room, err := s.client.CreateRoom(ctx, &livekit.CreateRoomRequest{
		Name:            req.RoomName,
		MaxParticipants: maxP,
		EmptyTimeout:    emptyTimeout,
		Metadata:        req.Metadata,
	})
	if err != nil {
		return nil, fmt.Errorf("livekit create room %s: %w", req.RoomName, err)
	}

	return room, nil
}

// UpdateSubscriptionRequest specifies track subscription parameters.
type UpdateSubscriptionRequest struct {
	// RoomName is the target room.
	RoomName string
	// Identity is the subscriber's participant identity.
	Identity string
	// TrackSIDs is the list of track SIDs to subscribe/unsubscribe.
	TrackSIDs []string
	// Subscribe controls whether to subscribe (true) or unsubscribe (false).
	Subscribe bool
}

// UpdateSubscription controls per-subscriber track subscriptions.
// For simulcast, the SFU automatically selects the appropriate layer
// based on subscriber bandwidth. This controls which tracks are forwarded.
func (s *RoomService) UpdateSubscription(ctx context.Context, req UpdateSubscriptionRequest) error {
	if len(req.TrackSIDs) == 0 {
		return nil
	}

	_, err := s.client.UpdateSubscriptions(ctx, &livekit.UpdateSubscriptionsRequest{
		Room:      req.RoomName,
		Identity:  req.Identity,
		TrackSids: req.TrackSIDs,
		Subscribe: req.Subscribe,
	})
	if err != nil {
		return fmt.Errorf("livekit update subscription for %s: %w", req.Identity, err)
	}

	return nil
}

// SendDataRequest specifies parameters for sending data messages to participants.
type SendDataRequest struct {
	// RoomName is the target room.
	RoomName string
	// Payload is the data to send.
	Payload []byte
	// DestinationIdentities limits delivery to specific participants.
	// Empty means broadcast to all.
	DestinationIdentities []string
	// Reliable uses SCTP data channel (reliable, ordered).
	Reliable bool
}

// SendData sends a data message to participants in a room.
// Used for signaling layer requests and updates.
func (s *RoomService) SendData(ctx context.Context, req SendDataRequest) error {
	kind := livekit.DataPacket_LOSSY
	if req.Reliable {
		kind = livekit.DataPacket_RELIABLE
	}

	_, err := s.client.SendData(ctx, &livekit.SendDataRequest{
		Room:                  req.RoomName,
		Data:                  req.Payload,
		Kind:                  kind,
		DestinationIdentities: req.DestinationIdentities,
	})
	if err != nil {
		return fmt.Errorf("livekit send data to %s: %w", req.RoomName, err)
	}

	return nil
}

// DeleteRoom removes a LiveKit room and disconnects all participants.
func (s *RoomService) DeleteRoom(ctx context.Context, roomName string) error {
	_, err := s.client.DeleteRoom(ctx, &livekit.DeleteRoomRequest{
		Room: roomName,
	})
	if err != nil {
		return fmt.Errorf("livekit delete room %s: %w", roomName, err)
	}
	return nil
}

// ListRooms returns all active LiveKit rooms, optionally filtered by names.
func (s *RoomService) ListRooms(ctx context.Context, names ...string) ([]*livekit.Room, error) {
	resp, err := s.client.ListRooms(ctx, &livekit.ListRoomsRequest{
		Names: names,
	})
	if err != nil {
		return nil, fmt.Errorf("livekit list rooms: %w", err)
	}
	return resp.GetRooms(), nil
}

// GetRoom fetches a specific room by name. Returns nil if not found.
func (s *RoomService) GetRoom(ctx context.Context, roomName string) (*livekit.Room, error) {
	rooms, err := s.ListRooms(ctx, roomName)
	if err != nil {
		return nil, err
	}
	if len(rooms) == 0 {
		return nil, nil
	}
	return rooms[0], nil
}

// ListParticipants returns all participants in a room.
func (s *RoomService) ListParticipants(ctx context.Context, roomName string) ([]*livekit.ParticipantInfo, error) {
	resp, err := s.client.ListParticipants(ctx, &livekit.ListParticipantsRequest{
		Room: roomName,
	})
	if err != nil {
		return nil, fmt.Errorf("livekit list participants %s: %w", roomName, err)
	}
	return resp.GetParticipants(), nil
}

// RemoveParticipant forces a participant to leave a room.
func (s *RoomService) RemoveParticipant(ctx context.Context, roomName, identity string) error {
	_, err := s.client.RemoveParticipant(ctx, &livekit.RoomParticipantIdentity{
		Room:     roomName,
		Identity: identity,
	})
	if err != nil {
		return fmt.Errorf("livekit remove participant %s from %s: %w", identity, roomName, err)
	}
	return nil
}

// MuteTrack mutes or unmutes a participant's published track.
func (s *RoomService) MuteTrack(ctx context.Context, roomName, identity, trackSID string, muted bool) error {
	_, err := s.client.MutePublishedTrack(ctx, &livekit.MuteRoomTrackRequest{
		Room:     roomName,
		Identity: identity,
		TrackSid: trackSID,
		Muted:    muted,
	})
	if err != nil {
		return fmt.Errorf("livekit mute track %s: %w", trackSID, err)
	}
	return nil
}

// RoomStats holds basic room metrics.
type RoomStats struct {
	Name            string
	NumParticipants int
	CreatedAt       time.Time
	Metadata        string
}

// GetRoomStats returns basic stats about a room.
func (s *RoomService) GetRoomStats(ctx context.Context, roomName string) (*RoomStats, error) {
	room, err := s.GetRoom(ctx, roomName)
	if err != nil {
		return nil, err
	}
	if room == nil {
		return nil, fmt.Errorf("room %s not found", roomName)
	}

	return &RoomStats{
		Name:            room.Name,
		NumParticipants: int(room.NumParticipants),
		CreatedAt:       time.Unix(room.CreationTime, 0),
		Metadata:        room.Metadata,
	}, nil
}
