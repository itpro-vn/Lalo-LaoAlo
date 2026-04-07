package session

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/google/uuid"
	"github.com/minhgv/lalo/internal/auth"
	"github.com/minhgv/lalo/internal/events"
)

// CreateGroupRequest holds parameters for creating a group call room.
type CreateGroupRequest struct {
	InitiatorID  string
	Participants []string // user IDs to invite (excluding initiator)
	CallType     string   // "audio" or "video"
	Region       string
}

// CreateGroupResponse holds the result of group room creation.
type CreateGroupResponse struct {
	RoomID          string                `json:"room_id"`
	Topology        Topology              `json:"topology"`
	LiveKitToken    string                `json:"livekit_token"`
	LiveKitURL      string                `json:"livekit_url"`
	Participants    []string              `json:"participants"` // invited user IDs
	TurnCredentials *auth.TurnCredentials `json:"turn_credentials,omitempty"`
}

// InviteToRoomResponse holds the result of inviting users mid-call.
type InviteToRoomResponse struct {
	Invited []string `json:"invited"` // user IDs successfully invited
	Skipped []string `json:"skipped"` // user IDs skipped (busy, already in room)
}

// CreateGroupSession creates a new group call room. The initiator becomes
// the host, and all participants receive invitations. Group calls always
// use SFU topology via LiveKit.
func (o *Orchestrator) CreateGroupSession(ctx context.Context, req CreateGroupRequest) (*CreateGroupResponse, error) {
	// Resolve participant identities (phone/ext/UUID → UUID)
	if o.resolver != nil {
		resolved, err := o.resolver.ResolveAll(ctx, req.Participants)
		if err != nil {
			return nil, fmt.Errorf("resolve participants: %w", err)
		}
		req.Participants = resolved
	}

	maxP := o.cfg.Group.MaxParticipants
	if maxP == 0 {
		maxP = 8
	}

	// Validate participant count (initiator + invitees)
	totalCount := 1 + len(req.Participants)
	if totalCount > maxP {
		return nil, fmt.Errorf("too many participants: %d (max %d)", totalCount, maxP)
	}
	if len(req.Participants) == 0 {
		return nil, fmt.Errorf("at least one participant required")
	}

	roomID := uuid.NewString()
	now := time.Now()
	hasVideo := req.CallType == "video"

	// Group calls always use SFU
	topology := TopologySFU

	// Build initial participant list (only initiator is active initially)
	participants := []Participant{
		{
			UserID:     req.InitiatorID,
			Role:       RoleCaller, // host
			MediaState: MediaState{AudioEnabled: true, VideoEnabled: hasVideo},
			JoinedAt:   now,
		},
	}

	sess := &Session{
		CallID:       roomID,
		CallType:     "group",
		Topology:     topology,
		InitiatorID:  req.InitiatorID,
		Region:       req.Region,
		HasVideo:     hasVideo,
		Participants: participants,
		CreatedAt:    now,
	}

	// Store session (marks initiator as busy)
	if err := o.store.Create(ctx, sess); err != nil {
		return nil, fmt.Errorf("create group session: %w", err)
	}

	resp := &CreateGroupResponse{
		RoomID:       roomID,
		Topology:     topology,
		Participants: req.Participants,
	}

	// Generate LiveKit token for initiator
	token, err := o.lkSvc.GenerateRoomToken(auth.RoomPermissions{
		RoomName:       roomID,
		Identity:       req.InitiatorID,
		CanPublish:     true,
		CanSubscribe:   true,
		CanPublishData: true,
	}, 2*time.Hour)
	if err != nil {
		log.Printf("[group] failed to generate LiveKit token for initiator: %v", err)
	} else {
		resp.LiveKitToken = token
		resp.LiveKitURL = o.cfg.LiveKit.Host
	}

	// Publish room created event
	if err := o.bus.Publish(ctx, events.SubjectRoomCreated, events.RoomCreated{
		RoomID:       roomID,
		InitiatorID:  req.InitiatorID,
		CallType:     req.CallType,
		Participants: req.Participants,
	}); err != nil {
		log.Printf("[group] failed to publish room.created: %v", err)
	}

	return resp, nil
}

// JoinGroupSession adds a participant to a group call room. Returns
// LiveKit credentials for the SFU.
func (o *Orchestrator) JoinGroupSession(ctx context.Context, roomID, userID string) (*JoinSessionResponse, error) {
	sess, err := o.store.Get(ctx, roomID)
	if err != nil {
		return nil, fmt.Errorf("room not found: %w", err)
	}

	if sess.CallType != "group" {
		return nil, fmt.Errorf("session %s is not a group call", roomID)
	}

	// Check if already in the room
	if p := sess.FindParticipant(userID); p != nil && p.LeftAt.IsZero() {
		return nil, fmt.Errorf("user %s already in room %s", userID, roomID)
	}

	p := Participant{
		UserID:     userID,
		Role:       RoleParticipant,
		MediaState: MediaState{AudioEnabled: true, VideoEnabled: sess.HasVideo},
		JoinedAt:   time.Now(),
	}

	maxP := o.cfg.Group.MaxParticipants
	if maxP == 0 {
		maxP = 8
	}

	if err := o.store.AddParticipant(ctx, roomID, p, maxP); err != nil {
		return nil, fmt.Errorf("join group session: %w", err)
	}

	resp := &JoinSessionResponse{
		Topology: TopologySFU,
	}

	// Generate LiveKit token
	token, err := o.lkSvc.GenerateRoomToken(auth.RoomPermissions{
		RoomName:       roomID,
		Identity:       userID,
		CanPublish:     true,
		CanSubscribe:   true,
		CanPublishData: true,
	}, 2*time.Hour)
	if err != nil {
		log.Printf("[group] failed to generate LiveKit token: %v", err)
	} else {
		resp.LiveKitToken = token
		resp.LiveKitURL = o.cfg.LiveKit.Host
	}

	// Publish participant joined event
	if err := o.bus.Publish(ctx, events.SubjectRoomParticipantJoined, events.RoomParticipantJoined{
		RoomID: roomID,
		UserID: userID,
		Role:   string(RoleParticipant),
	}); err != nil {
		log.Printf("[group] failed to publish room.participant_joined: %v", err)
	}

	return resp, nil
}

// LeaveGroupSession removes a participant from a group call room.
// If the host leaves, the room is closed. If no participants remain,
// the room is also closed.
func (o *Orchestrator) LeaveGroupSession(ctx context.Context, roomID, userID string) error {
	sess, err := o.store.Get(ctx, roomID)
	if err != nil {
		return fmt.Errorf("room not found: %w", err)
	}

	if sess.CallType != "group" {
		return fmt.Errorf("session %s is not a group call", roomID)
	}

	sess, err = o.store.RemoveParticipant(ctx, roomID, userID)
	if err != nil {
		return fmt.Errorf("leave group session: %w", err)
	}

	// Publish participant left event
	if err := o.bus.Publish(ctx, events.SubjectRoomParticipantLeft, events.RoomParticipantLeft{
		RoomID: roomID,
		UserID: userID,
	}); err != nil {
		log.Printf("[group] failed to publish room.participant_left: %v", err)
	}

	// Auto-close: no active participants remain
	active := sess.ActiveParticipants()
	if len(active) == 0 {
		return o.CloseRoom(ctx, roomID, "all_left")
	}

	return nil
}

// InviteToRoom invites additional participants to an existing group call.
// Only the host (initiator) can invite.
func (o *Orchestrator) InviteToRoom(ctx context.Context, roomID, inviterID string, inviteeIDs []string) (*InviteToRoomResponse, error) {
	// Resolve invitee identities (phone/ext/UUID → UUID)
	if o.resolver != nil {
		resolved, err := o.resolver.ResolveAll(ctx, inviteeIDs)
		if err != nil {
			return nil, fmt.Errorf("resolve invitees: %w", err)
		}
		inviteeIDs = resolved
	}

	sess, err := o.store.Get(ctx, roomID)
	if err != nil {
		return nil, fmt.Errorf("room not found: %w", err)
	}

	if sess.CallType != "group" {
		return nil, fmt.Errorf("session %s is not a group call", roomID)
	}

	// Verify inviter is the host (initiator / RoleCaller)
	inviter := sess.FindParticipant(inviterID)
	if inviter == nil || inviter.LeftAt.IsZero() == false {
		return nil, fmt.Errorf("inviter %s is not an active participant", inviterID)
	}
	if inviter.Role != RoleCaller {
		return nil, fmt.Errorf("only the host can invite participants")
	}

	maxP := o.cfg.Group.MaxParticipants
	if maxP == 0 {
		maxP = 8
	}

	currentCount := len(sess.ActiveParticipants())
	resp := &InviteToRoomResponse{}

	for _, inviteeID := range inviteeIDs {
		// Check room capacity
		if currentCount >= maxP {
			resp.Skipped = append(resp.Skipped, inviteeID)
			continue
		}

		// Check if already in room
		if p := sess.FindParticipant(inviteeID); p != nil && p.LeftAt.IsZero() {
			resp.Skipped = append(resp.Skipped, inviteeID)
			continue
		}

		resp.Invited = append(resp.Invited, inviteeID)
		currentCount++
	}

	return resp, nil
}

// CloseRoom terminates a group call room, generates CDR, and publishes events.
func (o *Orchestrator) CloseRoom(ctx context.Context, roomID, reason string) error {
	sess, err := o.store.EndSession(ctx, roomID, reason)
	if err != nil {
		return fmt.Errorf("close room: %w", err)
	}

	// Generate CDR
	o.cdr.WriteFull(ctx, sess)

	// Compute duration
	cdr := GenerateCDR(sess)

	// Publish room closed event
	if err := o.bus.Publish(ctx, events.SubjectRoomClosed, events.RoomClosed{
		RoomID:   roomID,
		Reason:   reason,
		Duration: cdr.DurationSeconds,
	}); err != nil {
		log.Printf("[group] failed to publish room.closed: %v", err)
	}

	// Also publish call.ended for general subscribers
	if err := o.bus.Publish(ctx, events.SubjectCallEnded, events.CallEnded{
		CallID:    roomID,
		EndReason: reason,
		Duration:  cdr.DurationSeconds,
	}); err != nil {
		log.Printf("[group] failed to publish call.ended: %v", err)
	}

	return nil
}

// GetRoomParticipants returns the list of active participants in a room.
func (o *Orchestrator) GetRoomParticipants(ctx context.Context, roomID string) ([]Participant, error) {
	sess, err := o.store.Get(ctx, roomID)
	if err != nil {
		return nil, err
	}
	return sess.ActiveParticipants(), nil
}

// TransferHost changes the host of a group call room to a new user.
// The new host must be an active participant in the room.
func (o *Orchestrator) TransferHost(ctx context.Context, roomID, newHostID string) error {
	sess, err := o.store.Get(ctx, roomID)
	if err != nil {
		return fmt.Errorf("room not found: %w", err)
	}

	if sess.CallType != "group" {
		return fmt.Errorf("session %s is not a group call", roomID)
	}

	newHost := sess.FindParticipant(newHostID)
	if newHost == nil || !newHost.LeftAt.IsZero() {
		return fmt.Errorf("user %s is not an active participant", newHostID)
	}

	// Update the participant role to caller (host)
	if err := o.store.UpdateParticipantRole(ctx, roomID, newHostID, RoleCaller); err != nil {
		return fmt.Errorf("transfer host: %w", err)
	}

	// Update initiator ID to reflect new host
	if err := o.store.UpdateInitiator(ctx, roomID, newHostID); err != nil {
		log.Printf("[group] failed to update initiator for room %s: %v", roomID, err)
	}

	log.Printf("[group] host transferred to %s in room %s", newHostID, roomID)
	return nil
}

// EndRoomForAll allows the host to end the room for all participants.
// Verifies the caller is the host before proceeding.
func (o *Orchestrator) EndRoomForAll(ctx context.Context, roomID, hostID string) error {
	sess, err := o.store.Get(ctx, roomID)
	if err != nil {
		return fmt.Errorf("room not found: %w", err)
	}

	if sess.CallType != "group" {
		return fmt.Errorf("session %s is not a group call", roomID)
	}

	// Verify the caller is the host
	host := sess.FindParticipant(hostID)
	if host == nil || host.Role != RoleCaller {
		return fmt.Errorf("only the host can end the room for all")
	}

	return o.CloseRoom(ctx, roomID, "host_ended")
}
