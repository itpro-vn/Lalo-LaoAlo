package session

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"time"

	"github.com/google/uuid"
	"github.com/minhgv/lalo/internal/auth"
	"github.com/minhgv/lalo/internal/config"
	"github.com/minhgv/lalo/internal/events"
	"github.com/redis/go-redis/v9"
)

// Orchestrator manages call session lifecycle, topology decisions,
// participant management, and CDR generation.
type Orchestrator struct {
	store    *Store
	bus      *events.Bus
	cdr      *CDRWriter
	turnSvc  *auth.TurnService
	lkSvc    *auth.LiveKitTokenService
	cfg      *config.Config
	resolver *IdentityResolver
}

// NewOrchestrator creates a new session orchestrator.
func NewOrchestrator(
	rdb *redis.Client,
	bus *events.Bus,
	db *sql.DB,
	turnSvc *auth.TurnService,
	lkSvc *auth.LiveKitTokenService,
	cfg *config.Config,
) *Orchestrator {
	return &Orchestrator{
		store:    NewStore(rdb),
		bus:      bus,
		cdr:      NewCDRWriter(db, bus),
		turnSvc:  turnSvc,
		lkSvc:    lkSvc,
		cfg:      cfg,
		resolver: NewIdentityResolver(db),
	}
}

// CreateSessionRequest holds parameters for creating a new call session.
type CreateSessionRequest struct {
	CallerID string
	CalleeID string
	CallType string // "1:1" or "group"
	HasVideo bool
	Region   string
}

// CreateSessionResponse holds the result of session creation.
type CreateSessionResponse struct {
	CallID          string                `json:"call_id"`
	Topology        Topology              `json:"topology"`
	TurnCredentials *auth.TurnCredentials `json:"turn_credentials,omitempty"`
	LiveKitToken    string                `json:"livekit_token,omitempty"`
	LiveKitURL      string                `json:"livekit_url,omitempty"`
}

// CreateSession validates participants, decides topology, provisions
// credentials, and creates a new call session.
func (o *Orchestrator) CreateSession(ctx context.Context, req CreateSessionRequest) (*CreateSessionResponse, error) {
	// Resolve callee identity (phone/ext/UUID → UUID)
	if o.resolver != nil {
		resolved, err := o.resolver.Resolve(ctx, req.CalleeID)
		if err != nil {
			return nil, fmt.Errorf("resolve callee: %w", err)
		}
		req.CalleeID = resolved
	}

	callID := uuid.NewString()
	now := time.Now()

	// Decide topology based on initial participant count
	participantCount := 2 // 1:1 starts with 2
	topology := DecideTopology(participantCount)

	// Build initial participants
	participants := []Participant{
		{
			UserID:     req.CallerID,
			Role:       RoleCaller,
			MediaState: MediaState{AudioEnabled: true, VideoEnabled: req.HasVideo},
			JoinedAt:   now,
		},
		{
			UserID:     req.CalleeID,
			Role:       RoleCallee,
			MediaState: MediaState{AudioEnabled: true, VideoEnabled: req.HasVideo},
			JoinedAt:   now,
		},
	}

	sess := &Session{
		CallID:       callID,
		CallType:     req.CallType,
		Topology:     topology,
		InitiatorID:  req.CallerID,
		Region:       req.Region,
		HasVideo:     req.HasVideo,
		Participants: participants,
		CreatedAt:    now,
	}

	// Store session (checks busy state)
	if err := o.store.Create(ctx, sess); err != nil {
		return nil, fmt.Errorf("create session: %w", err)
	}

	resp := &CreateSessionResponse{
		CallID:   callID,
		Topology: topology,
	}

	// Provision TURN credentials for P2P/TURN topology
	if topology == TopologyP2P || topology == TopologyTURN {
		resp.TurnCredentials = o.turnSvc.GenerateCredentials(req.CallerID)
	}

	// For SFU topology, generate LiveKit room token
	if topology == TopologySFU {
		token, err := o.lkSvc.GenerateRoomToken(auth.RoomPermissions{
			RoomName:       callID,
			Identity:       req.CallerID,
			CanPublish:     true,
			CanSubscribe:   true,
			CanPublishData: true,
		}, 2*time.Hour)
		if err != nil {
			log.Printf("[orchestrator] failed to generate LiveKit token: %v", err)
		} else {
			resp.LiveKitToken = token
			resp.LiveKitURL = o.cfg.LiveKit.Host
		}
	}

	// Publish call initiated event
	if err := o.bus.Publish(ctx, events.SubjectCallInitiated, events.CallInitiated{
		CallID:   callID,
		CallerID: req.CallerID,
		CalleeID: req.CalleeID,
		CallType: req.CallType,
		HasVideo: req.HasVideo,
		Region:   req.Region,
	}); err != nil {
		log.Printf("[orchestrator] failed to publish call.initiated: %v", err)
	}

	return resp, nil
}

// JoinSessionRequest holds parameters for joining an existing session.
type JoinSessionRequest struct {
	CallID   string
	UserID   string
	Role     Role
	HasVideo bool
}

// JoinSessionResponse holds the result of joining a session.
type JoinSessionResponse struct {
	Topology        Topology              `json:"topology"`
	TurnCredentials *auth.TurnCredentials `json:"turn_credentials,omitempty"`
	LiveKitToken    string                `json:"livekit_token,omitempty"`
	LiveKitURL      string                `json:"livekit_url,omitempty"`
	Escalated       bool                  `json:"escalated"` // true if topology changed
}

// JoinSession adds a participant to an active session. If the new
// participant count exceeds 2, the topology escalates to SFU.
func (o *Orchestrator) JoinSession(ctx context.Context, req JoinSessionRequest) (*JoinSessionResponse, error) {
	// Check permission
	if err := CheckPermission(req.Role, PermAcceptCall); err != nil {
		return nil, err
	}

	p := Participant{
		UserID:     req.UserID,
		Role:       req.Role,
		MediaState: MediaState{AudioEnabled: true, VideoEnabled: req.HasVideo},
		JoinedAt:   time.Now(),
	}

	maxP := o.cfg.Group.MaxParticipants
	if maxP == 0 {
		maxP = 8
	}

	if err := o.store.AddParticipant(ctx, req.CallID, p, maxP); err != nil {
		return nil, fmt.Errorf("join session: %w", err)
	}

	// Re-fetch session for topology check
	sess, err := o.store.Get(ctx, req.CallID)
	if err != nil {
		return nil, err
	}

	resp := &JoinSessionResponse{
		Topology: sess.Topology,
	}

	// Check if topology needs escalation
	activeCount := len(sess.ActiveParticipants())
	if ShouldEscalateToSFU(sess.Topology, activeCount) {
		sess.Topology = TopologySFU
		if err := o.store.Update(ctx, sess); err != nil {
			return nil, fmt.Errorf("update topology: %w", err)
		}
		resp.Topology = TopologySFU
		resp.Escalated = true
	}

	// Provision credentials based on topology
	if resp.Topology == TopologyP2P || resp.Topology == TopologyTURN {
		resp.TurnCredentials = o.turnSvc.GenerateCredentials(req.UserID)
	}

	if resp.Topology == TopologySFU {
		token, err := o.lkSvc.GenerateRoomToken(auth.RoomPermissions{
			RoomName:       req.CallID,
			Identity:       req.UserID,
			CanPublish:     true,
			CanSubscribe:   true,
			CanPublishData: true,
		}, 2*time.Hour)
		if err != nil {
			log.Printf("[orchestrator] failed to generate LiveKit token: %v", err)
		} else {
			resp.LiveKitToken = token
			resp.LiveKitURL = o.cfg.LiveKit.Host
		}
	}

	// Publish acceptance event
	if err := o.bus.Publish(ctx, events.SubjectCallAccepted, events.CallAccepted{
		CallID:   req.CallID,
		UserID:   req.UserID,
		Topology: string(resp.Topology),
	}); err != nil {
		log.Printf("[orchestrator] failed to publish call.accepted: %v", err)
	}

	return resp, nil
}

// LeaveSession removes a participant from a session. If no active
// participants remain, the session ends automatically.
func (o *Orchestrator) LeaveSession(ctx context.Context, callID, userID string) error {
	sess, err := o.store.RemoveParticipant(ctx, callID, userID)
	if err != nil {
		return fmt.Errorf("leave session: %w", err)
	}

	// Check if call should end (no active participants, or 1:1 and one left)
	active := sess.ActiveParticipants()
	shouldEnd := len(active) == 0 || (sess.CallType == "1:1" && len(active) <= 1)

	if shouldEnd {
		return o.EndSession(ctx, callID, "normal")
	}

	return nil
}

// EndSession terminates a call session, generates CDR, and notifies.
func (o *Orchestrator) EndSession(ctx context.Context, callID, reason string) error {
	sess, err := o.store.EndSession(ctx, callID, reason)
	if err != nil {
		return fmt.Errorf("end session: %w", err)
	}

	// Generate and write CDR (sync to Postgres, async to ClickHouse)
	o.cdr.WriteFull(ctx, sess)

	// Publish call ended event
	cdr := GenerateCDR(sess)
	if err := o.bus.Publish(ctx, events.SubjectCallEnded, events.CallEnded{
		CallID:    callID,
		EndReason: reason,
		Duration:  cdr.DurationSeconds,
	}); err != nil {
		log.Printf("[orchestrator] failed to publish call.ended: %v", err)
	}

	return nil
}

// GetSession retrieves the current session state.
func (o *Orchestrator) GetSession(ctx context.Context, callID string) (*Session, error) {
	return o.store.Get(ctx, callID)
}

// UpdateMediaState updates a participant's media state.
func (o *Orchestrator) UpdateMediaState(ctx context.Context, callID, userID string, state MediaState) error {
	sess, err := o.store.Get(ctx, callID)
	if err != nil {
		return err
	}

	p := sess.FindParticipant(userID)
	if p == nil {
		return fmt.Errorf("participant %s not found in call %s", userID, callID)
	}

	p.MediaState = state
	return o.store.Update(ctx, sess)
}

// FallbackToTURN switches a P2P call to TURN relay.
func (o *Orchestrator) FallbackToTURN(ctx context.Context, callID string) (*auth.TurnCredentials, error) {
	sess, err := o.store.Get(ctx, callID)
	if err != nil {
		return nil, err
	}

	if !ShouldFallbackToTURN(sess.Topology, true) {
		return nil, fmt.Errorf("cannot fallback to TURN from topology %s", sess.Topology)
	}

	sess.Topology = TopologyTURN
	if err := o.store.Update(ctx, sess); err != nil {
		return nil, fmt.Errorf("update topology: %w", err)
	}

	// Publish state change
	if err := o.bus.Publish(ctx, events.SubjectCallStateChanged, events.CallStateChanged{
		CallID:    callID,
		FromState: string(TopologyP2P),
		ToState:   string(TopologyTURN),
		Trigger:   "ice_failed",
	}); err != nil {
		log.Printf("[orchestrator] failed to publish state change: %v", err)
	}

	return o.turnSvc.GenerateCredentials(sess.InitiatorID), nil
}

// GetTurnCredentials generates TURN credentials for a participant.
func (o *Orchestrator) GetTurnCredentials(ctx context.Context, userID string) *auth.TurnCredentials {
	return o.turnSvc.GenerateCredentials(userID)
}

// RecoverGroupSessions returns all active group sessions from Redis.
// Used by the signaling hub to rebuild local room state after restart.
func (o *Orchestrator) RecoverGroupSessions(ctx context.Context) ([]Session, error) {
	return o.store.ScanGroupSessions(ctx)
}
