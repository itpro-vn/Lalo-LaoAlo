package signaling

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/minhgv/lalo/internal/config"
	"github.com/minhgv/lalo/internal/events"
	"github.com/minhgv/lalo/internal/session"
)

// Hub maintains the set of active clients and routes messages.
type Hub struct {
	// Registered clients indexed by userID → deviceID → Client.
	// Supports multiple devices per user for multi-device ringing.
	clients   map[string]map[string]*Client
	clientsMu sync.RWMutex

	// Per-user outgoing sequence counter for message ordering.
	seqCounters   map[string]*atomic.Int64
	seqCountersMu sync.Mutex

	// Room membership: roomID → set of userIDs.
	rooms   map[string]map[string]bool
	roomsMu sync.RWMutex

	// Reconnection grace period tracking: userID → cancel func.
	// When a client disconnects during an active call, we start a grace timer.
	// If the client reconnects within the window, we cancel the timer.
	graceTimers   map[string]context.CancelFunc
	graceTimersMu sync.Mutex

	// Room grace period tracking: userID → cancel func.
	// When a client disconnects while in group rooms, we keep them in the room
	// briefly to avoid participant_left/joined churn on transient disconnects.
	roomGraceTimers   map[string]context.CancelFunc
	roomGraceTimersMu sync.Mutex

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
		clients:         make(map[string]map[string]*Client),
		seqCounters:     make(map[string]*atomic.Int64),
		rooms:           make(map[string]map[string]bool),
		graceTimers:     make(map[string]context.CancelFunc),
		roomGraceTimers: make(map[string]context.CancelFunc),
		iceBuf:          make(map[string][]ICECandidateMsg),
		register:        make(chan *Client),
		unregister:      make(chan *Client),
		incoming:        make(chan *ClientMessage, 256),
		sessions:        sessions,
		bus:             bus,
		cfg:             cfg,
		orchestrator:    orch,
		ctx:             ctx,
		cancel:          cancel,
	}
}

// Run starts the hub's main event loop.
func (h *Hub) Run() {
	for {
		select {
		case client := <-h.register:
			h.clientsMu.Lock()
			if h.clients[client.userID] == nil {
				h.clients[client.userID] = make(map[string]*Client)
			}
			// If same device reconnects, close old connection
			if old, ok := h.clients[client.userID][client.deviceID]; ok {
				old.Close()
			}
			h.clients[client.userID][client.deviceID] = client
			h.clientsMu.Unlock()

			// Cancel room grace timer if user is reconnecting while in rooms
			if h.cancelRoomGracePeriod(client.userID) {
				log.Printf("client re-registered (room grace cancelled): user=%s device=%s", client.userID, client.deviceID)
			} else {
				log.Printf("client registered: user=%s device=%s", client.userID, client.deviceID)
			}

			// State sync: send active call state to reconnecting client
			h.sendStateSync(client)

		case client := <-h.unregister:
			h.clientsMu.Lock()
			if devices, ok := h.clients[client.userID]; ok {
				if existing, hasDevice := devices[client.deviceID]; hasDevice && existing == client {
					delete(devices, client.deviceID)
					// If no more devices for this user, remove user entry
					if len(devices) == 0 {
						delete(h.clients, client.userID)
					}
				}
			}
			// Check if user still has connected devices
			hasDevices := len(h.clients[client.userID]) > 0
			h.clientsMu.Unlock()

			if hasDevices {
				log.Printf("device disconnected (other devices still connected): user=%s device=%s", client.userID, client.deviceID)
				continue
			}

			// No devices left — handle grace periods or cleanup
			if h.startGracePeriod(client.userID) {
				log.Printf("client disconnected (grace period started): user=%s", client.userID)
			} else if h.startRoomGracePeriod(client.userID) {
				log.Printf("client disconnected (room grace period started): user=%s", client.userID)
			} else {
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
	for _, devices := range h.clients {
		for _, client := range devices {
			client.Close()
		}
	}
	h.clients = make(map[string]map[string]*Client)
}

// getClient returns any connected client for a given userID (first device found).
// For sending to specific device, use getClientDevice. For broadcast, use sendToUser.
func (h *Hub) getClient(userID string) *Client {
	h.clientsMu.RLock()
	defer h.clientsMu.RUnlock()
	for _, client := range h.clients[userID] {
		return client // return first device
	}
	return nil
}

// getClientDevice returns the client for a specific user+device combo.
func (h *Hub) getClientDevice(userID, deviceID string) *Client {
	h.clientsMu.RLock()
	defer h.clientsMu.RUnlock()
	if devices, ok := h.clients[userID]; ok {
		return devices[deviceID]
	}
	return nil
}

// sendToUser sends a message to ALL connected devices of a user.
// Returns true if at least one device was reached.
func (h *Hub) sendToUser(userID, msgType string, payload interface{}) bool {
	h.clientsMu.RLock()
	devices := h.clients[userID]
	clients := make([]*Client, 0, len(devices))
	for _, c := range devices {
		clients = append(clients, c)
	}
	h.clientsMu.RUnlock()

	if len(clients) == 0 {
		return false
	}

	// Assign sequence number
	seq := h.nextSeq(userID)
	for _, c := range clients {
		c.SendJSONWithSeq(msgType, payload, seq)
	}
	return true
}

// sendToUserExcept sends to all devices of a user except the specified device.
func (h *Hub) sendToUserExcept(userID, excludeDeviceID, msgType string, payload interface{}) {
	h.clientsMu.RLock()
	devices := h.clients[userID]
	clients := make([]*Client, 0, len(devices))
	for did, c := range devices {
		if did != excludeDeviceID {
			clients = append(clients, c)
		}
	}
	h.clientsMu.RUnlock()

	if len(clients) == 0 {
		return
	}

	seq := h.nextSeq(userID)
	for _, c := range clients {
		c.SendJSONWithSeq(msgType, payload, seq)
	}
}

// nextSeq returns the next sequence number for a user.
func (h *Hub) nextSeq(userID string) int64 {
	h.seqCountersMu.Lock()
	counter, ok := h.seqCounters[userID]
	if !ok {
		counter = &atomic.Int64{}
		h.seqCounters[userID] = counter
	}
	h.seqCountersMu.Unlock()
	return counter.Add(1)
}

// isUserOnline checks if a user has at least one connected device.
func (h *Hub) isUserOnline(userID string) bool {
	h.clientsMu.RLock()
	defer h.clientsMu.RUnlock()
	return len(h.clients[userID]) > 0
}

// handleMessage processes an incoming client message.
func (h *Hub) handleMessage(msg *ClientMessage) {
	var env Envelope
	if err := json.Unmarshal(msg.payload, &env); err != nil {
		msg.client.SendError(ErrCodeInvalidMessage, "invalid JSON", "")
		return
	}

	// Message deduplication: if client sent a msg_id, check for duplicates
	if env.MsgID != "" {
		dup, err := h.sessions.CheckMsgDedup(h.ctx, env.MsgID)
		if err != nil {
			log.Printf("dedup check error: %v", err)
		} else if dup {
			msg.client.SendError(ErrCodeDuplicate, "duplicate message", "")
			return
		}
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
	case MsgRoomEndAll:
		h.handleRoomEndAll(msg.client, env.Data)
	case MsgMediaChange:
		h.handleMediaChange(msg.client, env.Data)
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

	// SDP validation: basic format check
	if !isValidSDP(msg.SDPOffer) {
		caller.SendError(ErrCodeInvalidSDP, "invalid SDP format", "")
		return
	}

	ctx := h.ctx
	callID := uuid.New().String()

	// Create session in Redis
	sess := &CallSession{
		CallID:    callID,
		CallerID:  caller.userID,
		CalleeID:  msg.CalleeID,
		CallType:  msg.CallType,
		State:     StateRinging,
		SDPOffer:  msg.SDPOffer,
		StartedAt: time.Now(),
	}

	if err := h.sessions.Create(ctx, sess); err != nil {
		if err == ErrUserBusy {
			// Check for glare: is the callee calling us back?
			glareSess, glareErr := h.sessions.FindGlareCall(ctx, caller.userID, msg.CalleeID)
			if glareErr == nil && glareSess != nil {
				// Glare detected! Resolve by lower user_id wins
				h.resolveGlare(ctx, caller, glareSess, msg)
				return
			}
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

	// Route incoming_call to ALL devices of callee (multi-device ringing)
	reached := h.sendToUser(msg.CalleeID, MsgIncomingCall, IncomingCallMsg{
		CallID:   callID,
		CallerID: caller.userID,
		SDPOffer: msg.SDPOffer,
		CallType: msg.CallType,
	})
	if !reached {
		// Callee is offline — push notification is handled by the Push Gateway
		// which subscribes to call.initiated events via NATS (published above).
		log.Printf("callee offline, call_id=%s callee=%s (push via gateway)", callID, msg.CalleeID)
	}

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

	sess, err := h.sessions.Get(ctx, msg.CallID)
	if err != nil {
		callee.SendError(ErrCodeNotFound, "call not found", msg.CallID)
		return
	}

	if sess.CalleeID != callee.userID {
		callee.SendError(ErrCodeUnauthorized, "not the callee", msg.CallID)
		return
	}

	// Cancel-wins: if session was already ended/cancelled, report it
	if sess.State == StateEnded || sess.State == StateCleanup {
		callee.SendError(ErrCodeCallCancelled, "call was cancelled", msg.CallID)
		return
	}

	// SDP validation for answer
	if msg.SDPAnswer != "" && !isValidSDP(msg.SDPAnswer) {
		callee.SendError(ErrCodeInvalidSDP, "invalid SDP answer format", msg.CallID)
		return
	}

	// Transition RINGING → CONNECTING
	err = h.sessions.TransitionState(ctx, msg.CallID, StateConnecting, func(s *CallSession) {
		s.SDPAnswer = msg.SDPAnswer
		s.AnsweredAt = time.Now()
	})
	if err != nil {
		// If transition fails because state changed (e.g. cancelled), check for cancel-wins
		currentSess, getErr := h.sessions.Get(ctx, msg.CallID)
		if getErr == nil && (currentSess.State == StateEnded || currentSess.State == StateCleanup) {
			callee.SendError(ErrCodeCallCancelled, "call was cancelled", msg.CallID)
			return
		}
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

	// Forward SDP answer to caller (all devices)
	h.sendToUser(sess.CallerID, MsgCallAccepted, CallAcceptedMsg{
		CallID:    msg.CallID,
		SDPAnswer: msg.SDPAnswer,
	})

	// Multi-device: notify other devices of callee that call was accepted elsewhere
	h.sendToUserExcept(callee.userID, callee.deviceID, MsgCallAcceptedElsewhere, CallAcceptedElsewhereMsg{
		CallID:   msg.CallID,
		DeviceID: callee.deviceID,
	})

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

	// Notify caller (all devices)
	h.sendToUser(session.CallerID, MsgCallRejected, CallRejectedMsg{
		CallID: msg.CallID,
		Reason: reason,
	})
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

	// Notify the other party (all devices)
	peerID := session.CallerID
	if client.userID == session.CallerID {
		peerID = session.CalleeID
	}

	h.sendToUser(peerID, MsgCallEnded, CallEndedMsg{
		CallID: msg.CallID,
		Reason: "normal",
	})
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

	// Notify callee (all devices)
	h.sendToUser(session.CalleeID, MsgCallCancelled, CallCancelledMsg{
		CallID: msg.CallID,
	})
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

	// Notify both parties (all devices)
	h.sendToUser(session.CallerID, MsgCallEnded, CallEndedMsg{CallID: callID, Reason: "timeout"})
	h.sendToUser(session.CalleeID, MsgCallEnded, CallEndedMsg{CallID: callID, Reason: "timeout"})
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

	// Notify both parties (all devices)
	h.sendToUser(session.CallerID, MsgCallEnded, CallEndedMsg{CallID: callID, Reason: "ice_timeout"})
	h.sendToUser(session.CalleeID, MsgCallEnded, CallEndedMsg{CallID: callID, Reason: "ice_timeout"})
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

	// Notify peer that this user is reconnecting (all devices)
	peerID := sess.CallerID
	if userID == sess.CallerID {
		peerID = sess.CalleeID
	}
	h.sendToUser(peerID, MsgPeerReconnecting, PeerReconnectingMsg{
		CallID: callID,
		PeerID: userID,
	})

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

// getUserRooms returns all room IDs a user is currently in.
func (h *Hub) getUserRooms(userID string) []string {
	h.roomsMu.RLock()
	defer h.roomsMu.RUnlock()
	var rooms []string
	for roomID, members := range h.rooms {
		if members[userID] {
			rooms = append(rooms, roomID)
		}
	}
	return rooms
}

// startRoomGracePeriod starts a grace timer for a user in group rooms.
// During the grace period, the user remains "in room" so other participants
// don't see participant_left/joined churn on transient disconnects.
// Returns true if the user is in at least one room and grace was started.
func (h *Hub) startRoomGracePeriod(userID string) bool {
	rooms := h.getUserRooms(userID)
	if len(rooms) == 0 {
		return false
	}

	graceDuration := h.reconnectGracePeriod()
	graceCtx, graceCancel := context.WithCancel(h.ctx)

	h.roomGraceTimersMu.Lock()
	if existing, ok := h.roomGraceTimers[userID]; ok {
		existing()
	}
	h.roomGraceTimers[userID] = graceCancel
	h.roomGraceTimersMu.Unlock()

	log.Printf("[room-grace] started for user=%s rooms=%v duration=%v", userID, rooms, graceDuration)

	go h.roomGraceTimeout(graceCtx, userID, rooms, graceDuration)

	return true
}

// cancelRoomGracePeriod cancels the room grace timer for a user.
// Returns true if a timer was active and cancelled.
func (h *Hub) cancelRoomGracePeriod(userID string) bool {
	h.roomGraceTimersMu.Lock()
	cancelFn, ok := h.roomGraceTimers[userID]
	if ok {
		delete(h.roomGraceTimers, userID)
	}
	h.roomGraceTimersMu.Unlock()

	if ok {
		cancelFn()
	}
	return ok
}

// roomGraceTimeout removes the user from all rooms if they don't reconnect
// within the grace period.
func (h *Hub) roomGraceTimeout(graceCtx context.Context, userID string, rooms []string, graceDuration time.Duration) {
	select {
	case <-time.After(graceDuration):
		log.Printf("[room-grace] expired for user=%s rooms=%v", userID, rooms)

		h.roomGraceTimersMu.Lock()
		delete(h.roomGraceTimers, userID)
		h.roomGraceTimersMu.Unlock()

		h.removeFromAllRooms(userID)

	case <-graceCtx.Done():
		// Cancelled — user reconnected or hub shut down
		return
	}
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

		// Notify peer (all devices)
		h.sendToUser(peerID, MsgCallEnded, CallEndedMsg{
			CallID: callID,
			Reason: "reconnect_timeout",
		})

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

	// Notify peer that the other side reconnected (all devices)
	h.sendToUser(peerID, MsgPeerReconnected, PeerReconnectedMsg{
		CallID: msg.CallID,
		PeerID: client.userID,
	})

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

	// Rate limit room creation: max 5 rooms per minute per user
	if limited, err := h.sessions.CheckRateLimit(h.ctx, "room_create:"+client.userID, 5, 60); err != nil {
		log.Printf("[hub] rate limit check error: %v", err)
	} else if limited {
		client.SendError(ErrCodeRateLimit, "room creation rate limited", "")
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
		} else if isUserBusyError(err) {
			client.SendError(ErrCodeBusy, "already in a call", "")
		} else {
			client.SendError(ErrCodeInternal, "failed to create room", "")
		}
		return
	}

	// Track room membership and host locally
	h.addToRoom(resp.RoomID, client.userID)
	h.setRoomHost(resp.RoomID, client.userID)

	// Notify creator
	client.SendJSON(MsgRoomCreated, RoomCreatedMsg{
		RoomID:       resp.RoomID,
		LiveKitToken: resp.LiveKitToken,
		LiveKitURL:   resp.LiveKitURL,
	})

	// Send invitations to participants (all devices)
	for _, inviteeID := range msg.Participants {
		h.sendToUser(inviteeID, MsgRoomInvitation, RoomInvitationMsg{
			RoomID:       resp.RoomID,
			InviterID:    client.userID,
			CallType:     msg.CallType,
			Participants: msg.Participants,
		})
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

	// Send invitations to newly invited users (all devices)
	for _, inviteeID := range resp.Invited {
		h.sendToUser(inviteeID, MsgRoomInvitation, RoomInvitationMsg{
			RoomID:       msg.RoomID,
			InviterID:    client.userID,
			CallType:     "", // existing room, callee will get type from join
			Participants: participants,
		})
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

	// Handle re-join during room grace period (transient disconnect).
	// Instead of erroring, refresh LiveKit credentials and return.
	if h.isInRoom(msg.RoomID, client.userID) {
		// Cancel room grace timer if active
		h.cancelRoomGracePeriod(client.userID)

		resp, err := h.orchestrator.JoinGroupSession(h.ctx, msg.RoomID, client.userID)
		if err != nil {
			log.Printf("[hub] room re-join error: %v", err)
			client.SendError(ErrCodeInternal, err.Error(), msg.RoomID)
			return
		}

		log.Printf("[hub] room re-join for user=%s room=%s", client.userID, msg.RoomID)

		client.SendJSON(MsgRoomCreated, RoomCreatedMsg{
			RoomID:       msg.RoomID,
			LiveKitToken: resp.LiveKitToken,
			LiveKitURL:   resp.LiveKitURL,
		})
		return
	}

	resp, err := h.orchestrator.JoinGroupSession(h.ctx, msg.RoomID, client.userID)
	if err != nil {
		log.Printf("[hub] room join error: %v", err)
		if isMaxParticipantsError(err) {
			client.SendError(ErrCodeRoomFull, err.Error(), msg.RoomID)
		} else if isUserBusyError(err) {
			client.SendError(ErrCodeBusy, "already in a call", msg.RoomID)
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

	// Check if leaving user is the host — if so, attempt host transfer
	isHost := h.isRoomHost(msg.RoomID, client.userID)

	if err := h.orchestrator.LeaveGroupSession(h.ctx, msg.RoomID, client.userID); err != nil {
		log.Printf("[hub] room leave error: %v", err)
	}

	// Remove from local tracking
	h.removeFromRoom(msg.RoomID, client.userID)

	// Get remaining members
	members := h.getRoomMembers(msg.RoomID)

	if isHost && len(members) > 0 {
		// Host transfer: promote the first remaining member to host
		newHostID := members[0]
		if err := h.orchestrator.TransferHost(h.ctx, msg.RoomID, newHostID); err != nil {
			log.Printf("[hub] host transfer error: %v", err)
		} else {
			// Notify all remaining members about host change
			h.broadcastToRoom(msg.RoomID, "", MsgParticipantJoined, ParticipantJoinedMsg{
				RoomID: msg.RoomID,
				UserID: newHostID,
				Role:   "host",
			})
			log.Printf("[hub] host transferred from %s to %s in room %s", client.userID, newHostID, msg.RoomID)
		}
	}

	// Broadcast participant_left to remaining members
	h.broadcastToRoom(msg.RoomID, "", MsgParticipantLeft, ParticipantLeftMsg{
		RoomID: msg.RoomID,
		UserID: client.userID,
	})

	// If room is empty, clean up local tracking
	if len(members) == 0 {
		h.roomsMu.Lock()
		delete(h.rooms, msg.RoomID)
		h.roomsMu.Unlock()
		h.clearRoomHost(msg.RoomID)
	}
}

// handleRoomEndAll handles a host request to end the room for all participants.
func (h *Hub) handleRoomEndAll(client *Client, data json.RawMessage) {
	if h.orchestrator == nil {
		client.SendError(ErrCodeInternal, "group calls not available", "")
		return
	}

	var msg RoomEndAllMsg
	if err := json.Unmarshal(data, &msg); err != nil {
		client.SendError(ErrCodeInvalidMessage, "invalid room_end_all payload", "")
		return
	}

	if msg.RoomID == "" {
		client.SendError(ErrCodeInvalidMessage, "room_id required", "")
		return
	}

	// Verify the sender is in the room
	if !h.isInRoom(msg.RoomID, client.userID) {
		client.SendError(ErrCodeNotFound, "not in room", msg.RoomID)
		return
	}

	// Verify the sender is the host
	if !h.isRoomHost(msg.RoomID, client.userID) {
		client.SendError(ErrCodeUnauthorized, "only the host can end the room for all", msg.RoomID)
		return
	}

	// Get all members before closing
	members := h.getRoomMembers(msg.RoomID)

	// Close the room via orchestrator (generates CDR, publishes events)
	if err := h.orchestrator.CloseRoom(h.ctx, msg.RoomID, "host_ended"); err != nil {
		log.Printf("[hub] room end_all error: %v", err)
		client.SendError(ErrCodeInternal, "failed to end room", msg.RoomID)
		return
	}

	// Notify all members that the room is closed
	for _, uid := range members {
		h.sendToUser(uid, MsgRoomClosed, RoomClosedMsg{
			RoomID: msg.RoomID,
			Reason: "host_ended",
		})
	}

	// Clean up local room tracking
	h.roomsMu.Lock()
	delete(h.rooms, msg.RoomID)
	h.roomsMu.Unlock()
	h.clearRoomHost(msg.RoomID)

	log.Printf("[hub] room %s ended by host %s for all participants", msg.RoomID, client.userID)
}

// handleMediaChange handles a participant changing their media state.
func (h *Hub) handleMediaChange(client *Client, data json.RawMessage) {
	if h.orchestrator == nil {
		client.SendError(ErrCodeInternal, "group calls not available", "")
		return
	}

	var msg MediaChangeMsg
	if err := json.Unmarshal(data, &msg); err != nil {
		client.SendError(ErrCodeInvalidMessage, "invalid media_change payload", "")
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

	// Update media state via orchestrator
	if err := h.orchestrator.UpdateMediaState(h.ctx, msg.RoomID, client.userID, session.MediaState{
		AudioEnabled: msg.Audio,
		VideoEnabled: msg.Video,
	}); err != nil {
		log.Printf("[hub] media change error: %v", err)
		// Don't fail the broadcast even if store update fails
	}

	// Broadcast media change to all room members except sender
	h.broadcastToRoom(msg.RoomID, client.userID, MsgParticipantMediaChanged, ParticipantMediaChangedMsg{
		RoomID: msg.RoomID,
		UserID: client.userID,
		Audio:  msg.Audio,
		Video:  msg.Video,
	})
}

// --- Room membership helpers ---

// roomHosts tracks which user is the host of each room: roomID → userID.
// The hub maintains this locally for quick lookups.
var roomHosts = struct {
	sync.RWMutex
	m map[string]string
}{m: make(map[string]string)}

func (h *Hub) addToRoom(roomID, userID string) {
	h.roomsMu.Lock()
	defer h.roomsMu.Unlock()
	if h.rooms[roomID] == nil {
		h.rooms[roomID] = make(map[string]bool)
	}
	h.rooms[roomID][userID] = true
}

func (h *Hub) setRoomHost(roomID, userID string) {
	roomHosts.Lock()
	roomHosts.m[roomID] = userID
	roomHosts.Unlock()
}

func (h *Hub) getRoomHost(roomID string) string {
	roomHosts.RLock()
	defer roomHosts.RUnlock()
	return roomHosts.m[roomID]
}

func (h *Hub) isRoomHost(roomID, userID string) bool {
	return h.getRoomHost(roomID) == userID
}

func (h *Hub) clearRoomHost(roomID string) {
	roomHosts.Lock()
	delete(roomHosts.m, roomID)
	roomHosts.Unlock()
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
				h.clearRoomHost(roomID)
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
		h.sendToUser(uid, msgType, payload)
	}
}

func isMaxParticipantsError(err error) bool {
	return err != nil && (err.Error() == "too many participants" ||
		err == session.ErrMaxParticipants)
}

func isUserBusyError(err error) bool {
	return err != nil && (errors.Is(err, session.ErrUserBusy) ||
		strings.Contains(err.Error(), "user already in active call"))
}

// --- Glare resolution ---

// resolveGlare handles the case where two users call each other simultaneously.
// Lower user_id wins. The losing call is cancelled.
func (h *Hub) resolveGlare(ctx context.Context, losingCaller *Client, glareSess *CallSession, initiateMsg CallInitiateMsg) {
	callerID := losingCaller.userID
	calleeID := initiateMsg.CalleeID

	// Determine winner: lower user_id wins
	winnerCallerID := callerID
	loserCallerID := calleeID
	winningCallID := "" // will be created
	losingCallID := glareSess.CallID

	if strings.Compare(callerID, calleeID) > 0 {
		// calleeID is lower → the existing call (glareSess) wins
		winnerCallerID = calleeID
		loserCallerID = callerID
		winningCallID = glareSess.CallID
		losingCallID = "" // the new call never gets created
	} else {
		// callerID is lower → this new call should win, cancel the existing call
		winnerCallerID = callerID
		loserCallerID = calleeID
		losingCallID = glareSess.CallID

		// End the existing (losing) call
		if err := h.sessions.End(ctx, glareSess.CallID, "glare"); err != nil {
			log.Printf("end glare session error: %v", err)
		}

		// Create the new (winning) call
		newCallID := uuid.New().String()
		sess := &CallSession{
			CallID:    newCallID,
			CallerID:  callerID,
			CalleeID:  calleeID,
			CallType:  initiateMsg.CallType,
			State:     StateRinging,
			SDPOffer:  initiateMsg.SDPOffer,
			StartedAt: time.Now(),
		}
		if err := h.sessions.Create(ctx, sess); err != nil {
			log.Printf("create winning glare session error: %v", err)
			losingCaller.SendError(ErrCodeInternal, "glare resolution failed", "")
			return
		}
		winningCallID = newCallID

		// Send incoming_call to the callee (all devices)
		h.sendToUser(calleeID, MsgIncomingCall, IncomingCallMsg{
			CallID:   newCallID,
			CallerID: callerID,
			SDPOffer: initiateMsg.SDPOffer,
			CallType: initiateMsg.CallType,
		})

		go h.ringTimeout(newCallID)
	}

	// If the existing call wins, end nothing (it's already ringing).
	// But the new call should not be created (we didn't create it above).
	if winnerCallerID == calleeID {
		// Existing call wins. Cancel is implicit (new call was never created).
		// Notify the losing caller (callerID) about glare
		h.sendToUser(loserCallerID, MsgCallGlare, CallGlareMsg{
			CancelledCallID: "", // new call was never created
			WinningCallID:   winningCallID,
			PeerID:          winnerCallerID,
		})
	} else {
		// New call wins — notify loser (calleeID) that their outgoing call was cancelled
		h.sendToUser(loserCallerID, MsgCallGlare, CallGlareMsg{
			CancelledCallID: losingCallID,
			WinningCallID:   winningCallID,
			PeerID:          winnerCallerID,
		})
	}

	log.Printf("glare resolved: winner=%s (call=%s), loser=%s (call=%s)",
		winnerCallerID, winningCallID, loserCallerID, losingCallID)
}

// --- SDP Validation ---

// isValidSDP performs basic validation of an SDP string.
func isValidSDP(sdp string) bool {
	if len(sdp) < 10 || len(sdp) > 65536 {
		return false
	}
	// SDP must contain required fields
	return strings.Contains(sdp, "v=0") && strings.Contains(sdp, "o=")
}

// --- State Sync ---

// sendStateSync sends the current call state to a newly connected/reconnected client.
func (h *Hub) sendStateSync(client *Client) {
	ctx := h.ctx
	callID, err := h.sessions.GetUserActiveCall(ctx, client.userID)
	if err != nil || callID == "" {
		return // no active call
	}

	sess, err := h.sessions.Get(ctx, callID)
	if err != nil {
		return
	}

	role := "callee"
	peerID := sess.CallerID
	if sess.CallerID == client.userID {
		role = "caller"
		peerID = sess.CalleeID
	}

	syncMsg := StateSyncMsg{
		ActiveCalls: []StateSyncCall{
			{
				CallID:   callID,
				PeerID:   peerID,
				CallType: sess.CallType,
				State:    sess.State,
				Role:     role,
			},
		},
	}

	client.SendJSON(MsgStateSync, syncMsg)
}

// --- State Recovery ---

// RecoverSessions scans Redis for active sessions on server startup
// and cleans up orphans (sessions where neither participant is connected).
func (h *Hub) RecoverSessions() {
	ctx := h.ctx

	// Recover 1:1 call sessions
	sessions, err := h.sessions.ScanActiveSessions(ctx)
	if err != nil {
		log.Printf("session recovery error: %v", err)
		return
	}

	recovered := 0
	cleaned := 0
	for _, sess := range sessions {
		callerOnline := h.isUserOnline(sess.CallerID)
		calleeOnline := h.isUserOnline(sess.CalleeID)

		if !callerOnline && !calleeOnline {
			// Orphan — clean up
			if err := h.sessions.Delete(ctx, sess.CallID); err != nil {
				log.Printf("cleanup orphan session %s error: %v", sess.CallID, err)
			}
			cleaned++
		} else {
			recovered++
		}
	}

	if recovered > 0 || cleaned > 0 {
		log.Printf("session recovery: %d recovered, %d orphans cleaned", recovered, cleaned)
	}

	// Recover group room sessions
	if h.orchestrator == nil {
		return
	}

	groupSessions, err := h.orchestrator.RecoverGroupSessions(ctx)
	if err != nil {
		log.Printf("group session recovery error: %v", err)
		return
	}

	roomRecovered := 0
	roomCleaned := 0
	for _, sess := range groupSessions {
		activeParticipants := sess.ActiveParticipants()

		if len(activeParticipants) == 0 {
			// No active participants — orphaned room, clean up
			if err := h.orchestrator.CloseRoom(ctx, sess.CallID, "orphan_cleanup"); err != nil {
				log.Printf("cleanup orphan room %s error: %v", sess.CallID, err)
			}
			roomCleaned++
			continue
		}

		// Rebuild local room membership
		hasOnlineParticipant := false
		for _, p := range activeParticipants {
			if h.isUserOnline(p.UserID) {
				h.addToRoom(sess.CallID, p.UserID)
				hasOnlineParticipant = true
			}
		}

		// Track the host
		if sess.InitiatorID != "" {
			h.setRoomHost(sess.CallID, sess.InitiatorID)
		}

		if hasOnlineParticipant {
			roomRecovered++
		} else {
			// All participants offline — start grace timer
			roomRecovered++
			log.Printf("room %s recovered but no participants online, waiting for reconnect", sess.CallID)
		}
	}

	if roomRecovered > 0 || roomCleaned > 0 {
		log.Printf("room recovery: %d recovered, %d orphans cleaned", roomRecovered, roomCleaned)
	}
}
