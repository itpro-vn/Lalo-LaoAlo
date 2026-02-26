package signaling

import (
	"context"
	"encoding/json"
	"log"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/minhgv/lalo/internal/config"
	"github.com/minhgv/lalo/internal/events"
	"github.com/minhgv/lalo/internal/session"
)

// Hub maintains the set of active clients and routes messages.
type Hub struct {
	// Registered clients indexed by userID.
	clients   map[string]*Client
	clientsMu sync.RWMutex

	// Room membership: roomID → set of userIDs.
	rooms   map[string]map[string]bool
	roomsMu sync.RWMutex

	// Reconnection grace period tracking: userID → cancel func.
	// When a client disconnects during an active call, we start a grace timer.
	// If the client reconnects within the window, we cancel the timer.
	graceTimers   map[string]context.CancelFunc
	graceTimersMu sync.Mutex

	// Buffered ICE candidates during reconnect: callID → []ICECandidateMsg.
	iceBuf   map[string][]ICECandidateMsg
	iceBufMu sync.Mutex

	// Channels for client lifecycle.
	register   chan *Client
	unregister chan *Client
	incoming   chan *ClientMessage

	// Dependencies.
	sessions     *SessionStore
	bus          *events.Bus
	cfg          *config.Config
	orchestrator *session.Orchestrator // optional, for group calls

	// Shutdown.
	ctx    context.Context
	cancel context.CancelFunc
}

// NewHub creates a new signaling hub.
func NewHub(sessions *SessionStore, bus *events.Bus, cfg *config.Config, orch *session.Orchestrator) *Hub {
	ctx, cancel := context.WithCancel(context.Background())
	return &Hub{
		clients:     make(map[string]*Client),
		rooms:       make(map[string]map[string]bool),
		graceTimers: make(map[string]context.CancelFunc),
		iceBuf:      make(map[string][]ICECandidateMsg),
		register:    make(chan *Client),
		unregister:  make(chan *Client),
		incoming:    make(chan *ClientMessage, 256),
		sessions:    sessions,
		bus:         bus,
		cfg:         cfg,
		orchestrator: orch,
		ctx:         ctx,
		cancel:      cancel,
	}
}

// Run starts the hub's main event loop.
func (h *Hub) Run() {
	for {
		select {
		case client := <-h.register:
			h.clientsMu.Lock()
			// Disconnect any existing connection for this user
			if old, ok := h.clients[client.userID]; ok {
				old.Close()
			}
			h.clients[client.userID] = client
			h.clientsMu.Unlock()
			log.Printf("client registered: user=%s", client.userID)

		case client := <-h.unregister:
			h.clientsMu.Lock()
			if existing, ok := h.clients[client.userID]; ok && existing == client {
				delete(h.clients, client.userID)
			}
			h.clientsMu.Unlock()

			// Check if user has an active call — if so, start grace period
			// instead of immediately cleaning up.
			if h.startGracePeriod(client.userID) {
				log.Printf("client disconnected (grace period started): user=%s", client.userID)
			} else {
				// No active call — clean up immediately
				h.removeFromAllRooms(client.userID)
				log.Printf("client unregistered: user=%s", client.userID)
			}

		case msg := <-h.incoming:
			h.handleMessage(msg)

		case <-h.ctx.Done():
			return
		}
	}
}

// Stop gracefully shuts down the hub.
func (h *Hub) Stop() {
	h.cancel()

	h.clientsMu.Lock()
	defer h.clientsMu.Unlock()
	for _, client := range h.clients {
		client.Close()
	}
	h.clients = make(map[string]*Client)
}

// getClient returns the client for a given userID.
func (h *Hub) getClient(userID string) *Client {
	h.clientsMu.RLock()
	defer h.clientsMu.RUnlock()
	return h.clients[userID]
}

// handleMessage processes an incoming client message.
func (h *Hub) handleMessage(msg *ClientMessage) {
	var env Envelope
	if err := json.Unmarshal(msg.payload, &env); err != nil {
		msg.client.SendError(ErrCodeInvalidMessage, "invalid JSON", "")
		return
	}

	switch env.Type {
	case MsgCallInitiate:
		h.handleCallInitiate(msg.client, env.Data)
	case MsgCallAccept:
		h.handleCallAccept(msg.client, env.Data)
	case MsgCallReject:
		h.handleCallReject(msg.client, env.Data)
	case MsgCallEnd:
		h.handleCallEnd(msg.client, env.Data)
	case MsgCallCancel:
		h.handleCallCancel(msg.client, env.Data)
	case MsgICECandidate:
		h.handleICECandidate(msg.client, env.Data)
	case MsgQualityMetrics:
		h.handleQualityMetrics(msg.client, env.Data)
	case MsgReconnect:
		h.handleReconnect(msg.client, env.Data)
	case MsgPing:
		msg.client.SendJSON(MsgPong, nil)
	// Group call handlers
	case MsgRoomCreate:
		h.handleRoomCreate(msg.client, env.Data)
	case MsgRoomInvite:
		h.handleRoomInvite(msg.client, env.Data)
	case MsgRoomJoin:
		h.handleRoomJoin(msg.client, env.Data)
	case MsgRoomLeave:
		h.handleRoomLeave(msg.client, env.Data)
	default:
		msg.client.SendError(ErrCodeInvalidMessage, "unknown message type: "+env.Type, "")
	}
}

// --- Call flow handlers ---

func (h *Hub) handleCallInitiate(caller *Client, data json.RawMessage) {
	var msg CallInitiateMsg
	if err := json.Unmarshal(data, &msg); err != nil {
		caller.SendError(ErrCodeInvalidMessage, "invalid call_initiate payload", "")
		return
	}

	if msg.CalleeID == "" || msg.SDPOffer == "" || msg.CallType == "" {
		caller.SendError(ErrCodeInvalidMessage, "missing required fields", "")
		return
	}

	if msg.CallType != "audio" && msg.CallType != "video" {
		caller.SendError(ErrCodeInvalidMessage, "call_type must be audio or video", "")
		return
	}

	ctx := h.ctx
	callID := uuid.New().String()

	// Create session in Redis
	session := &CallSession{
		CallID:    callID,
		CallerID:  caller.userID,
		CalleeID:  msg.CalleeID,
		CallType:  msg.CallType,
		State:     StateRinging,
		SDPOffer:  msg.SDPOffer,
		StartedAt: time.Now(),
	}

	if err := h.sessions.Create(ctx, session); err != nil {
		if err == ErrUserBusy {
			caller.SendError(ErrCodeBusy, "user is busy", "")
			return
		}
		log.Printf("create session error: %v", err)
		caller.SendError(ErrCodeInternal, "failed to create call", "")
		return
	}

	// Publish event
	if h.bus != nil {
		h.bus.Publish(ctx, events.SubjectCallInitiated, events.CallInitiated{
			CallID:   callID,
			CallerID: caller.userID,
			CalleeID: msg.CalleeID,
			CallType: msg.CallType,
		})
	}

	// Route incoming_call to callee
	callee := h.getClient(msg.CalleeID)
	if callee != nil {
		callee.SendJSON(MsgIncomingCall, IncomingCallMsg{
			CallID:   callID,
			CallerID: caller.userID,
			SDPOffer: msg.SDPOffer,
			CallType: msg.CallType,
		})
	}
	// TODO: Send push notification if callee is offline

	// Start ring timeout
	go h.ringTimeout(callID)
}

func (h *Hub) handleCallAccept(callee *Client, data json.RawMessage) {
	var msg CallAcceptMsg
	if err := json.Unmarshal(data, &msg); err != nil {
		callee.SendError(ErrCodeInvalidMessage, "invalid call_accept payload", "")
		return
	}

	ctx := h.ctx

	session, err := h.sessions.Get(ctx, msg.CallID)
	if err != nil {
		callee.SendError(ErrCodeNotFound, "call not found", msg.CallID)
		return
	}

	if session.CalleeID != callee.userID {
		callee.SendError(ErrCodeUnauthorized, "not the callee", msg.CallID)
		return
	}

	// Transition RINGING → CONNECTING
	err = h.sessions.TransitionState(ctx, msg.CallID, StateConnecting, func(s *CallSession) {
		s.SDPAnswer = msg.SDPAnswer
		s.AnsweredAt = time.Now()
	})
	if err != nil {
		callee.SendError(ErrCodeInvalidState, err.Error(), msg.CallID)
		return
	}

	// Publish event
	if h.bus != nil {
		h.bus.Publish(ctx, events.SubjectCallAccepted, events.CallAccepted{
			CallID: msg.CallID,
			UserID: callee.userID,
		})
	}

	// Forward SDP answer to caller
	caller := h.getClient(session.CallerID)
	if caller != nil {
		caller.SendJSON(MsgCallAccepted, CallAcceptedMsg{
			CallID:    msg.CallID,
			SDPAnswer: msg.SDPAnswer,
		})
	}

	// Start ICE timeout
	go h.iceTimeout(msg.CallID)
}

func (h *Hub) handleCallReject(callee *Client, data json.RawMessage) {
	var msg CallRejectMsg
	if err := json.Unmarshal(data, &msg); err != nil {
		callee.SendError(ErrCodeInvalidMessage, "invalid call_reject payload", "")
		return
	}

	ctx := h.ctx

	session, err := h.sessions.Get(ctx, msg.CallID)
	if err != nil {
		callee.SendError(ErrCodeNotFound, "call not found", msg.CallID)
		return
	}

	if session.CalleeID != callee.userID {
		callee.SendError(ErrCodeUnauthorized, "not the callee", msg.CallID)
		return
	}

	reason := msg.Reason
	if reason == "" {
		reason = "declined"
	}

	if err := h.sessions.End(ctx, msg.CallID, reason); err != nil {
		log.Printf("end session error: %v", err)
		return
	}

	// Publish event
	if h.bus != nil {
		h.bus.Publish(ctx, events.SubjectCallRejected, events.CallRejected{
			CallID: msg.CallID,
			Reason: reason,
		})
	}

	// Notify caller
	caller := h.getClient(session.CallerID)
	if caller != nil {
		caller.SendJSON(MsgCallRejected, CallRejectedMsg{
			CallID: msg.CallID,
			Reason: reason,
		})
	}
}

func (h *Hub) handleCallEnd(client *Client, data json.RawMessage) {
	var msg CallEndMsg
	if err := json.Unmarshal(data, &msg); err != nil {
		client.SendError(ErrCodeInvalidMessage, "invalid call_end payload", "")
		return
	}

	ctx := h.ctx

	session, err := h.sessions.Get(ctx, msg.CallID)
	if err != nil {
		client.SendError(ErrCodeNotFound, "call not found", msg.CallID)
		return
	}

	// Either party can end the call
	if session.CallerID != client.userID && session.CalleeID != client.userID {
		client.SendError(ErrCodeUnauthorized, "not a participant", msg.CallID)
		return
	}

	if err := h.sessions.End(ctx, msg.CallID, "normal"); err != nil {
		log.Printf("end session error: %v", err)
		return
	}

	// Publish event
	if h.bus != nil {
		h.bus.Publish(ctx, events.SubjectCallEnded, events.CallEnded{
			CallID:    msg.CallID,
			EndReason: "normal",
		})
	}

	// Notify the other party
	peerID := session.CallerID
	if client.userID == session.CallerID {
		peerID = session.CalleeID
	}

	peer := h.getClient(peerID)
	if peer != nil {
		peer.SendJSON(MsgCallEnded, CallEndedMsg{
			CallID: msg.CallID,
			Reason: "normal",
		})
	}
}

func (h *Hub) handleCallCancel(caller *Client, data json.RawMessage) {
	var msg CallCancelMsg
	if err := json.Unmarshal(data, &msg); err != nil {
		caller.SendError(ErrCodeInvalidMessage, "invalid call_cancel payload", "")
		return
	}

	ctx := h.ctx

	session, err := h.sessions.Get(ctx, msg.CallID)
	if err != nil {
		caller.SendError(ErrCodeNotFound, "call not found", msg.CallID)
		return
	}

	if session.CallerID != caller.userID {
		caller.SendError(ErrCodeUnauthorized, "not the caller", msg.CallID)
		return
	}

	if err := h.sessions.End(ctx, msg.CallID, "cancelled"); err != nil {
		log.Printf("end session error: %v", err)
		return
	}

	// Notify callee
	callee := h.getClient(session.CalleeID)
	if callee != nil {
		callee.SendJSON(MsgCallCancelled, CallCancelledMsg{
			CallID: msg.CallID,
		})
	}
}

func (h *Hub) handleICECandidate(client *Client, data json.RawMessage) {
	var msg ICECandidateMsg
	if err := json.Unmarshal(data, &msg); err != nil {
		client.SendError(ErrCodeInvalidMessage, "invalid ice_candidate payload", "")
		return
	}

	session, err := h.sessions.Get(h.ctx, msg.CallID)
	if err != nil {
		client.SendError(ErrCodeNotFound, "call not found", msg.CallID)
		return
	}

	// Determine peer and forward
	peerID := session.CallerID
	if client.userID == session.CallerID {
		peerID = session.CalleeID
	}

	// If session is in RECONNECTING state, buffer candidates for later delivery
	if session.State == StateReconnecting {
		h.bufferICECandidate(msg.CallID, ICECandidateMsg{
			CallID:    msg.CallID,
			Candidate: msg.Candidate,
		})
		return
	}

	peer := h.getClient(peerID)
	if peer != nil {
		peer.SendJSON(MsgICECandidate, ICECandidateMsg{
			CallID:    msg.CallID,
			Candidate: msg.Candidate,
		})
	}
}

// --- Timeouts ---

func (h *Hub) ringTimeout(callID string) {
	timeout := 45 * time.Second
	if h.cfg != nil && h.cfg.Call.RingTimeoutSeconds > 0 {
		timeout = time.Duration(h.cfg.Call.RingTimeoutSeconds) * time.Second
	}

	select {
	case <-time.After(timeout):
	case <-h.ctx.Done():
		return
	}

	session, err := h.sessions.Get(h.ctx, callID)
	if err != nil {
		return
	}
	if session.State != StateRinging {
		return // Already transitioned
	}

	if err := h.sessions.End(h.ctx, callID, "ring_timeout"); err != nil {
		return
	}

	// Notify both parties
	caller := h.getClient(session.CallerID)
	if caller != nil {
		caller.SendJSON(MsgCallEnded, CallEndedMsg{CallID: callID, Reason: "timeout"})
	}
	callee := h.getClient(session.CalleeID)
	if callee != nil {
		callee.SendJSON(MsgCallEnded, CallEndedMsg{CallID: callID, Reason: "timeout"})
	}
}

func (h *Hub) iceTimeout(callID string) {
	timeout := 15 * time.Second
	if h.cfg != nil && h.cfg.Call.ICETimeoutSeconds > 0 {
		timeout = time.Duration(h.cfg.Call.ICETimeoutSeconds) * time.Second
	}

	select {
	case <-time.After(timeout):
	case <-h.ctx.Done():
		return
	}

	session, err := h.sessions.Get(h.ctx, callID)
	if err != nil {
		return
	}
	if session.State != StateConnecting {
		return // Already transitioned (e.g. to ACTIVE)
	}

	if err := h.sessions.End(h.ctx, callID, "ice_timeout"); err != nil {
		return
	}

	// Notify both parties
	caller := h.getClient(session.CallerID)
	if caller != nil {
		caller.SendJSON(MsgCallEnded, CallEndedMsg{CallID: callID, Reason: "ice_timeout"})
	}
	callee := h.getClient(session.CalleeID)
	if callee != nil {
		callee.SendJSON(MsgCallEnded, CallEndedMsg{CallID: callID, Reason: "ice_timeout"})
	}
}

// PromoteToActive transitions a call from CONNECTING to ACTIVE.
// Called externally when media flow is confirmed.
func (h *Hub) PromoteToActive(ctx context.Context, callID string) error {
	return h.sessions.TransitionState(ctx, callID, StateActive, nil)
}

// --- Reconnection handling ---

// reconnectGracePeriod returns the grace period duration for reconnection.
// Defaults to 30 seconds.
func (h *Hub) reconnectGracePeriod() time.Duration {
	if h.cfg != nil && h.cfg.Call.MaxReconnectAttempts > 0 {
		// Sum of backoff + buffer: typically 0+1+3 = 4s per attempt × max_attempts + margin
		// But spec says max 30s grace window
	}
	return 30 * time.Second
}

// startGracePeriod starts a reconnection grace timer for a disconnected user.
// Returns true if the user had an active call and a grace period was started.
func (h *Hub) startGracePeriod(userID string) bool {
	// Check if user has an active/connecting call
	callID, err := h.sessions.GetUserActiveCall(h.ctx, userID)
	if err != nil || callID == "" {
		return false
	}

	sess, err := h.sessions.Get(h.ctx, callID)
	if err != nil {
		return false
	}

	// Only start grace period for ACTIVE or CONNECTING calls
	if sess.State != StateActive && sess.State != StateConnecting {
		return false
	}

	// Transition to RECONNECTING
	if err := h.sessions.TransitionState(h.ctx, callID, StateReconnecting, nil); err != nil {
		log.Printf("[reconnect] failed to transition %s to RECONNECTING: %v", callID, err)
		return false
	}

	// Notify peer that this user is reconnecting
	peerID := sess.CallerID
	if userID == sess.CallerID {
		peerID = sess.CalleeID
	}
	if peer := h.getClient(peerID); peer != nil {
		peer.SendJSON(MsgPeerReconnecting, PeerReconnectingMsg{
			CallID: callID,
			PeerID: userID,
		})
	}

	// Start grace timer
	graceCtx, graceCancel := context.WithCancel(h.ctx)
	h.graceTimersMu.Lock()
	// Cancel any existing grace timer for this user
	if existing, ok := h.graceTimers[userID]; ok {
		existing()
	}
	h.graceTimers[userID] = graceCancel
	h.graceTimersMu.Unlock()

	go h.reconnectGraceTimeout(graceCtx, userID, callID, peerID)

	return true
}

// cancelGracePeriod cancels the reconnection grace timer for a user.
// Returns true if a grace timer was active and cancelled.
func (h *Hub) cancelGracePeriod(userID string) bool {
	h.graceTimersMu.Lock()
	cancelFn, ok := h.graceTimers[userID]
	if ok {
		delete(h.graceTimers, userID)
	}
	h.graceTimersMu.Unlock()

	if ok {
		cancelFn()
	}
	return ok
}

// reconnectGraceTimeout ends the call if the user doesn't reconnect within the grace period.
func (h *Hub) reconnectGraceTimeout(graceCtx context.Context, userID, callID, peerID string) {
	graceDuration := h.reconnectGracePeriod()

	select {
	case <-time.After(graceDuration):
		// Grace period expired — end the call
		log.Printf("[reconnect] grace period expired for user=%s call=%s", userID, callID)

		// Clean up grace timer
		h.graceTimersMu.Lock()
		delete(h.graceTimers, userID)
		h.graceTimersMu.Unlock()

		// Clean up buffered ICE candidates
		h.clearICEBuffer(callID)

		if err := h.sessions.End(h.ctx, callID, "reconnect_timeout"); err != nil {
			log.Printf("[reconnect] end session error: %v", err)
			return
		}

		// Publish event
		if h.bus != nil {
			h.bus.Publish(h.ctx, events.SubjectCallEnded, events.CallEnded{
				CallID:    callID,
				EndReason: "reconnect_timeout",
			})
		}

		// Notify peer
		if peer := h.getClient(peerID); peer != nil {
			peer.SendJSON(MsgCallEnded, CallEndedMsg{
				CallID: callID,
				Reason: "reconnect_timeout",
			})
		}

		// Clean up rooms
		h.removeFromAllRooms(userID)

	case <-graceCtx.Done():
		// Grace period cancelled (user reconnected or hub shut down)
		return
	}
}

// handleReconnect processes a reconnect request from a client.
func (h *Hub) handleReconnect(client *Client, data json.RawMessage) {
	var msg ReconnectMsg
	if err := json.Unmarshal(data, &msg); err != nil {
		client.SendError(ErrCodeInvalidMessage, "invalid reconnect payload", "")
		return
	}

	if msg.CallID == "" {
		client.SendError(ErrCodeInvalidMessage, "call_id required", "")
		return
	}

	ctx := h.ctx

	// Fetch the session
	sess, err := h.sessions.Get(ctx, msg.CallID)
	if err != nil {
		client.SendError(ErrCodeNotFound, "call not found", msg.CallID)
		return
	}

	// Validate the client is a participant
	if sess.CallerID != client.userID && sess.CalleeID != client.userID {
		client.SendError(ErrCodeUnauthorized, "not a participant", msg.CallID)
		return
	}

	// Only allow reconnect if in RECONNECTING state
	if sess.State != StateReconnecting {
		client.SendError(ErrCodeInvalidState, "call not in reconnecting state", msg.CallID)
		return
	}

	// Cancel the grace timer
	h.cancelGracePeriod(client.userID)

	// Transition back to ACTIVE
	if err := h.sessions.TransitionState(ctx, msg.CallID, StateActive, nil); err != nil {
		log.Printf("[reconnect] failed to transition %s to ACTIVE: %v", msg.CallID, err)
		client.SendError(ErrCodeInternal, "failed to resume session", msg.CallID)
		return
	}

	// Determine peer
	peerID := sess.CallerID
	if client.userID == sess.CallerID {
		peerID = sess.CalleeID
	}

	// Send session resumed to the reconnecting client
	client.SendJSON(MsgSessionResumed, SessionResumedMsg{
		CallID: msg.CallID,
		State:  StateActive,
		PeerID: peerID,
	})

	// Notify peer that the other side reconnected
	if peer := h.getClient(peerID); peer != nil {
		peer.SendJSON(MsgPeerReconnected, PeerReconnectedMsg{
			CallID: msg.CallID,
			PeerID: client.userID,
		})
	}

	// Flush any buffered ICE candidates to the reconnected client
	h.flushICEBuffer(msg.CallID, client)

	log.Printf("[reconnect] user=%s resumed call=%s", client.userID, msg.CallID)
}

// --- ICE candidate buffering ---

// bufferICECandidate stores an ICE candidate for later delivery after reconnection.
func (h *Hub) bufferICECandidate(callID string, msg ICECandidateMsg) {
	h.iceBufMu.Lock()
	defer h.iceBufMu.Unlock()
	h.iceBuf[callID] = append(h.iceBuf[callID], msg)
	// Cap buffer at 50 candidates to prevent memory bloat
	if len(h.iceBuf[callID]) > 50 {
		h.iceBuf[callID] = h.iceBuf[callID][len(h.iceBuf[callID])-50:]
	}
}

// flushICEBuffer sends all buffered ICE candidates to a client and clears the buffer.
func (h *Hub) flushICEBuffer(callID string, client *Client) {
	h.iceBufMu.Lock()
	candidates := h.iceBuf[callID]
	delete(h.iceBuf, callID)
	h.iceBufMu.Unlock()

	for _, c := range candidates {
		client.SendJSON(MsgICECandidate, c)
	}
}

// clearICEBuffer discards all buffered ICE candidates for a call.
func (h *Hub) clearICEBuffer(callID string) {
	h.iceBufMu.Lock()
	delete(h.iceBuf, callID)
	h.iceBufMu.Unlock()
}

func (h *Hub) handleQualityMetrics(client *Client, data json.RawMessage) {
	var msg QualityMetricsMsg
	if err := json.Unmarshal(data, &msg); err != nil {
		client.SendError(ErrCodeInvalidMessage, "invalid quality_metrics payload", "")
		return
	}

	if msg.CallID == "" || len(msg.Samples) == 0 {
		return // silently drop empty metrics
	}

	// Convert to event samples and publish to NATS
	if h.bus != nil {
		samples := make([]events.QualityMetricsSample, len(msg.Samples))
		for i, s := range msg.Samples {
			samples[i] = events.QualityMetricsSample{
				ParticipantID: client.userID,
				Timestamp:     s.Timestamp,
				Direction:     s.Direction,
				RTTMs:         s.RTTMs,
				LossPct:       s.LossPct,
				JitterMs:      s.JitterMs,
				BitrateKbps:   s.BitrateKbps,
				Framerate:     s.Framerate,
				Resolution:    s.Resolution,
				NetworkTier:   s.NetworkTier,
			}
		}

		h.bus.Publish(h.ctx, events.SubjectQualityMetrics, events.QualityMetrics{
			CallID:  msg.CallID,
			Samples: samples,
		})
	}
}

// --- Group call handlers ---

func (h *Hub) handleRoomCreate(client *Client, data json.RawMessage) {
	if h.orchestrator == nil {
		client.SendError(ErrCodeInternal, "group calls not available", "")
		return
	}

	var msg RoomCreateMsg
	if err := json.Unmarshal(data, &msg); err != nil {
		client.SendError(ErrCodeInvalidMessage, "invalid room_create payload", "")
		return
	}

	if len(msg.Participants) == 0 {
		client.SendError(ErrCodeInvalidMessage, "at least one participant required", "")
		return
	}
	if msg.CallType != "audio" && msg.CallType != "video" {
		client.SendError(ErrCodeInvalidMessage, "call_type must be audio or video", "")
		return
	}

	resp, err := h.orchestrator.CreateGroupSession(h.ctx, session.CreateGroupRequest{
		InitiatorID:  client.userID,
		Participants: msg.Participants,
		CallType:     msg.CallType,
	})
	if err != nil {
		log.Printf("[hub] room create error: %v", err)
		if isMaxParticipantsError(err) {
			client.SendError(ErrCodeRoomFull, err.Error(), "")
		} else {
			client.SendError(ErrCodeInternal, "failed to create room", "")
		}
		return
	}

	// Track room membership locally
	h.addToRoom(resp.RoomID, client.userID)

	// Notify creator
	client.SendJSON(MsgRoomCreated, RoomCreatedMsg{
		RoomID:       resp.RoomID,
		LiveKitToken: resp.LiveKitToken,
		LiveKitURL:   resp.LiveKitURL,
	})

	// Send invitations to participants
	for _, inviteeID := range msg.Participants {
		invitee := h.getClient(inviteeID)
		if invitee != nil {
			invitee.SendJSON(MsgRoomInvitation, RoomInvitationMsg{
				RoomID:       resp.RoomID,
				InviterID:    client.userID,
				CallType:     msg.CallType,
				Participants: msg.Participants,
			})
		}
		// Push notification for offline users handled by orchestrator event subscriber
	}
}

func (h *Hub) handleRoomInvite(client *Client, data json.RawMessage) {
	if h.orchestrator == nil {
		client.SendError(ErrCodeInternal, "group calls not available", "")
		return
	}

	var msg RoomInviteMsg
	if err := json.Unmarshal(data, &msg); err != nil {
		client.SendError(ErrCodeInvalidMessage, "invalid room_invite payload", "")
		return
	}

	if msg.RoomID == "" || len(msg.Invitees) == 0 {
		client.SendError(ErrCodeInvalidMessage, "room_id and invitees required", "")
		return
	}

	// Check that the inviter is in the room
	if !h.isInRoom(msg.RoomID, client.userID) {
		client.SendError(ErrCodeUnauthorized, "not in room", msg.RoomID)
		return
	}

	resp, err := h.orchestrator.InviteToRoom(h.ctx, msg.RoomID, client.userID, msg.Invitees)
	if err != nil {
		log.Printf("[hub] room invite error: %v", err)
		client.SendError(ErrCodeInternal, err.Error(), msg.RoomID)
		return
	}

	// Get current participant list for invitation message
	participants := h.getRoomMembers(msg.RoomID)

	// Send invitations to newly invited users
	for _, inviteeID := range resp.Invited {
		invitee := h.getClient(inviteeID)
		if invitee != nil {
			invitee.SendJSON(MsgRoomInvitation, RoomInvitationMsg{
				RoomID:       msg.RoomID,
				InviterID:    client.userID,
				CallType:     "", // existing room, callee will get type from join
				Participants: participants,
			})
		}
	}
}

func (h *Hub) handleRoomJoin(client *Client, data json.RawMessage) {
	if h.orchestrator == nil {
		client.SendError(ErrCodeInternal, "group calls not available", "")
		return
	}

	var msg RoomJoinMsg
	if err := json.Unmarshal(data, &msg); err != nil {
		client.SendError(ErrCodeInvalidMessage, "invalid room_join payload", "")
		return
	}

	if msg.RoomID == "" {
		client.SendError(ErrCodeInvalidMessage, "room_id required", "")
		return
	}

	// Check if already in room locally
	if h.isInRoom(msg.RoomID, client.userID) {
		client.SendError(ErrCodeInvalidState, "already in room", msg.RoomID)
		return
	}

	resp, err := h.orchestrator.JoinGroupSession(h.ctx, msg.RoomID, client.userID)
	if err != nil {
		log.Printf("[hub] room join error: %v", err)
		if isMaxParticipantsError(err) {
			client.SendError(ErrCodeRoomFull, err.Error(), msg.RoomID)
		} else {
			client.SendError(ErrCodeInternal, err.Error(), msg.RoomID)
		}
		return
	}

	// Track room membership
	h.addToRoom(msg.RoomID, client.userID)

	// Send join response with LiveKit credentials
	client.SendJSON(MsgRoomCreated, RoomCreatedMsg{
		RoomID:       msg.RoomID,
		LiveKitToken: resp.LiveKitToken,
		LiveKitURL:   resp.LiveKitURL,
	})

	// Broadcast participant_joined to all room members (except the joiner)
	h.broadcastToRoom(msg.RoomID, client.userID, MsgParticipantJoined, ParticipantJoinedMsg{
		RoomID: msg.RoomID,
		UserID: client.userID,
		Role:   "participant",
	})
}

func (h *Hub) handleRoomLeave(client *Client, data json.RawMessage) {
	if h.orchestrator == nil {
		client.SendError(ErrCodeInternal, "group calls not available", "")
		return
	}

	var msg RoomLeaveMsg
	if err := json.Unmarshal(data, &msg); err != nil {
		client.SendError(ErrCodeInvalidMessage, "invalid room_leave payload", "")
		return
	}

	if msg.RoomID == "" {
		client.SendError(ErrCodeInvalidMessage, "room_id required", "")
		return
	}

	if !h.isInRoom(msg.RoomID, client.userID) {
		client.SendError(ErrCodeNotFound, "not in room", msg.RoomID)
		return
	}

	if err := h.orchestrator.LeaveGroupSession(h.ctx, msg.RoomID, client.userID); err != nil {
		log.Printf("[hub] room leave error: %v", err)
	}

	// Remove from local tracking
	h.removeFromRoom(msg.RoomID, client.userID)

	// Broadcast participant_left to remaining members
	h.broadcastToRoom(msg.RoomID, "", MsgParticipantLeft, ParticipantLeftMsg{
		RoomID: msg.RoomID,
		UserID: client.userID,
	})

	// If room is empty, clean up local tracking
	members := h.getRoomMembers(msg.RoomID)
	if len(members) == 0 {
		h.roomsMu.Lock()
		delete(h.rooms, msg.RoomID)
		h.roomsMu.Unlock()
	}
}

// --- Room membership helpers ---

func (h *Hub) addToRoom(roomID, userID string) {
	h.roomsMu.Lock()
	defer h.roomsMu.Unlock()
	if h.rooms[roomID] == nil {
		h.rooms[roomID] = make(map[string]bool)
	}
	h.rooms[roomID][userID] = true
}

func (h *Hub) removeFromRoom(roomID, userID string) {
	h.roomsMu.Lock()
	defer h.roomsMu.Unlock()
	if h.rooms[roomID] != nil {
		delete(h.rooms[roomID], userID)
	}
}

func (h *Hub) isInRoom(roomID, userID string) bool {
	h.roomsMu.RLock()
	defer h.roomsMu.RUnlock()
	return h.rooms[roomID] != nil && h.rooms[roomID][userID]
}

func (h *Hub) getRoomMembers(roomID string) []string {
	h.roomsMu.RLock()
	defer h.roomsMu.RUnlock()
	members := make([]string, 0)
	for uid := range h.rooms[roomID] {
		members = append(members, uid)
	}
	return members
}

// removeFromAllRooms removes a user from all rooms they're in (on disconnect).
func (h *Hub) removeFromAllRooms(userID string) {
	h.roomsMu.Lock()
	roomsToLeave := make([]string, 0)
	for roomID, members := range h.rooms {
		if members[userID] {
			delete(members, userID)
			roomsToLeave = append(roomsToLeave, roomID)
			if len(members) == 0 {
				delete(h.rooms, roomID)
			}
		}
	}
	h.roomsMu.Unlock()

	// Notify orchestrator and broadcast for each room
	for _, roomID := range roomsToLeave {
		if h.orchestrator != nil {
			if err := h.orchestrator.LeaveGroupSession(h.ctx, roomID, userID); err != nil {
				log.Printf("[hub] auto-leave room %s for user %s error: %v", roomID, userID, err)
			}
		}

		h.broadcastToRoom(roomID, "", MsgParticipantLeft, ParticipantLeftMsg{
			RoomID: roomID,
			UserID: userID,
		})
	}
}

// broadcastToRoom sends a message to all connected clients in a room,
// optionally excluding one user (e.g. the sender).
func (h *Hub) broadcastToRoom(roomID, excludeUserID, msgType string, payload interface{}) {
	members := h.getRoomMembers(roomID)
	for _, uid := range members {
		if uid == excludeUserID {
			continue
		}
		if c := h.getClient(uid); c != nil {
			c.SendJSON(msgType, payload)
		}
	}
}

func isMaxParticipantsError(err error) bool {
	return err != nil && (err.Error() == "too many participants" ||
		err == session.ErrMaxParticipants)
}
