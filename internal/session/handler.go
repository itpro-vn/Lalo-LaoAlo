package session

import (
	"encoding/json"
	"log"
	"net/http"

	"github.com/minhgv/lalo/internal/auth"
)

// Handler provides REST API handlers for session management.
type Handler struct {
	orchestrator *Orchestrator
	jwtService   *auth.JWTService
}

// NewHandler creates a new session API handler.
func NewHandler(orch *Orchestrator, jwt *auth.JWTService) *Handler {
	return &Handler{
		orchestrator: orch,
		jwtService:   jwt,
	}
}

// createBody is the JSON body for POST /api/v1/sessions.
type createBody struct {
	CalleeID string `json:"callee_id"`
	CallType string `json:"call_type"` // "1:1" or "group"
	HasVideo bool   `json:"has_video"`
}

// joinBody is the JSON body for POST /api/v1/sessions/:id/join.
type joinBody struct {
	Role string `json:"role,omitempty"` // defaults to "participant"
}

// UpdateMediaRequest is the JSON body for PATCH /api/v1/sessions/:id/media.
type UpdateMediaRequest struct {
	AudioEnabled  *bool `json:"audio_enabled,omitempty"`
	VideoEnabled  *bool `json:"video_enabled,omitempty"`
	ScreenSharing *bool `json:"screen_sharing,omitempty"`
}

// EndSessionBody is the JSON body for POST /api/v1/sessions/:id/end.
type EndSessionBody struct {
	Reason string `json:"reason,omitempty"`
}

// ServeHTTP dispatches requests to the appropriate handler.
func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path

	switch {
	case path == "/api/v1/sessions" && r.Method == http.MethodPost:
		h.handleCreateSession(w, r)
	case path == "/api/v1/sessions" && r.Method == http.MethodGet:
		h.handleListSessions(w, r)
	case matchPath(path, "/api/v1/sessions/", "/join") && r.Method == http.MethodPost:
		h.handleJoinSession(w, r)
	case matchPath(path, "/api/v1/sessions/", "/leave") && r.Method == http.MethodPost:
		h.handleLeaveSession(w, r)
	case matchPath(path, "/api/v1/sessions/", "/end") && r.Method == http.MethodPost:
		h.handleEndSession(w, r)
	case matchPath(path, "/api/v1/sessions/", "/media") && r.Method == http.MethodPatch:
		h.handleUpdateMedia(w, r)
	case matchPath(path, "/api/v1/sessions/", "/turn-credentials") && r.Method == http.MethodGet:
		h.handleGetTurnCredentials(w, r)
	case matchPrefix(path, "/api/v1/sessions/") && r.Method == http.MethodGet:
		h.handleGetSession(w, r)

	// Group call (room) routes
	case path == "/api/v1/rooms" && r.Method == http.MethodPost:
		h.handleCreateRoom(w, r)
	case matchPath(path, "/api/v1/rooms/", "/invite") && r.Method == http.MethodPost:
		h.handleInviteToRoom(w, r)
	case matchPath(path, "/api/v1/rooms/", "/join") && r.Method == http.MethodPost:
		h.handleJoinRoom(w, r)
	case matchPath(path, "/api/v1/rooms/", "/leave") && r.Method == http.MethodPost:
		h.handleLeaveRoom(w, r)
	case matchPath(path, "/api/v1/rooms/", "/end") && r.Method == http.MethodPost:
		h.handleEndRoom(w, r)
	case matchPath(path, "/api/v1/rooms/", "/participants") && r.Method == http.MethodGet:
		h.handleGetRoomParticipants(w, r)
	case matchPrefix(path, "/api/v1/rooms/") && r.Method == http.MethodGet:
		h.handleGetSession(w, r) // reuse — rooms are sessions

	default:
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
	}
}

func (h *Handler) handleCreateSession(w http.ResponseWriter, r *http.Request) {
	claims, ok := auth.ClaimsFromContext(r.Context())
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	var body createBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_body"})
		return
	}

	if body.CalleeID == "" || body.CallType == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "callee_id and call_type required"})
		return
	}

	result, err := h.orchestrator.CreateSession(r.Context(), CreateSessionRequest{
		CallerID: claims.UserID,
		CalleeID: body.CalleeID,
		CallType: body.CallType,
		HasVideo: body.HasVideo,
		Region:   "default",
	})
	if err != nil {
		log.Printf("create session error: %v", err)
		status := http.StatusInternalServerError
		if err == ErrUserBusy || err == ErrAlreadyInCall {
			status = http.StatusConflict
		}
		writeJSON(w, status, map[string]string{"error": err.Error()})
		return
	}

	writeJSON(w, http.StatusCreated, result)
}

func (h *Handler) handleGetSession(w http.ResponseWriter, r *http.Request) {
	_, ok := auth.ClaimsFromContext(r.Context())
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	callID := extractID(r.URL.Path, "/api/v1/sessions/")
	if callID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing call_id"})
		return
	}

	sess, err := h.orchestrator.GetSession(r.Context(), callID)
	if err != nil {
		if err == ErrSessionNotFound {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "session_not_found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal_error"})
		return
	}

	writeJSON(w, http.StatusOK, sess)
}

func (h *Handler) handleListSessions(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, []interface{}{}) // Placeholder
}

func (h *Handler) handleJoinSession(w http.ResponseWriter, r *http.Request) {
	claims, ok := auth.ClaimsFromContext(r.Context())
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	callID := extractSegment(r.URL.Path, "/api/v1/sessions/", "/join")
	if callID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing call_id"})
		return
	}

	var body joinBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		body.Role = string(RoleParticipant)
	}
	if body.Role == "" {
		body.Role = string(RoleParticipant)
	}

	result, err := h.orchestrator.JoinSession(r.Context(), JoinSessionRequest{
		CallID: callID,
		UserID: claims.UserID,
		Role:   Role(body.Role),
	})
	if err != nil {
		log.Printf("join session error: %v", err)
		status := http.StatusInternalServerError
		switch err {
		case ErrSessionNotFound:
			status = http.StatusNotFound
		case ErrUserBusy, ErrAlreadyInCall:
			status = http.StatusConflict
		case ErrMaxParticipants:
			status = http.StatusForbidden
		}
		writeJSON(w, status, map[string]string{"error": err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, result)
}

func (h *Handler) handleLeaveSession(w http.ResponseWriter, r *http.Request) {
	claims, ok := auth.ClaimsFromContext(r.Context())
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	callID := extractSegment(r.URL.Path, "/api/v1/sessions/", "/leave")
	if callID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing call_id"})
		return
	}

	if err := h.orchestrator.LeaveSession(r.Context(), callID, claims.UserID); err != nil {
		log.Printf("leave session error: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "left"})
}

func (h *Handler) handleEndSession(w http.ResponseWriter, r *http.Request) {
	_, ok := auth.ClaimsFromContext(r.Context())
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	callID := extractSegment(r.URL.Path, "/api/v1/sessions/", "/end")
	if callID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing call_id"})
		return
	}

	var body EndSessionBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		body.Reason = "user_ended"
	}
	if body.Reason == "" {
		body.Reason = "user_ended"
	}

	if err := h.orchestrator.EndSession(r.Context(), callID, body.Reason); err != nil {
		log.Printf("end session error: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "ended"})
}

func (h *Handler) handleUpdateMedia(w http.ResponseWriter, r *http.Request) {
	claims, ok := auth.ClaimsFromContext(r.Context())
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	callID := extractSegment(r.URL.Path, "/api/v1/sessions/", "/media")
	if callID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing call_id"})
		return
	}

	var req UpdateMediaRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_body"})
		return
	}

	media := MediaState{}
	if req.AudioEnabled != nil {
		media.AudioEnabled = *req.AudioEnabled
	}
	if req.VideoEnabled != nil {
		media.VideoEnabled = *req.VideoEnabled
	}
	if req.ScreenSharing != nil {
		media.ScreenSharing = *req.ScreenSharing
	}

	if err := h.orchestrator.UpdateMediaState(r.Context(), callID, claims.UserID, media); err != nil {
		log.Printf("update media error: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "updated"})
}

func (h *Handler) handleGetTurnCredentials(w http.ResponseWriter, r *http.Request) {
	claims, ok := auth.ClaimsFromContext(r.Context())
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	creds := h.orchestrator.GetTurnCredentials(r.Context(), claims.UserID)

	writeJSON(w, http.StatusOK, creds)
}

// --- Group call (room) handlers ---

// createRoomBody is the JSON body for POST /api/v1/rooms.
type createRoomBody struct {
	Participants []string `json:"participants"` // user IDs to invite
	CallType     string   `json:"call_type"`    // "audio" or "video"
}

// inviteBody is the JSON body for POST /api/v1/rooms/:id/invite.
type inviteBody struct {
	Invitees []string `json:"invitees"`
}

func (h *Handler) handleCreateRoom(w http.ResponseWriter, r *http.Request) {
	claims, ok := auth.ClaimsFromContext(r.Context())
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	var body createRoomBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_body"})
		return
	}

	if len(body.Participants) == 0 || body.CallType == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "participants and call_type required"})
		return
	}

	result, err := h.orchestrator.CreateGroupSession(r.Context(), CreateGroupRequest{
		InitiatorID:  claims.UserID,
		Participants: body.Participants,
		CallType:     body.CallType,
	})
	if err != nil {
		log.Printf("create room error: %v", err)
		status := http.StatusInternalServerError
		if err == ErrUserBusy || err == ErrAlreadyInCall {
			status = http.StatusConflict
		}
		writeJSON(w, status, map[string]string{"error": err.Error()})
		return
	}

	writeJSON(w, http.StatusCreated, result)
}

func (h *Handler) handleInviteToRoom(w http.ResponseWriter, r *http.Request) {
	claims, ok := auth.ClaimsFromContext(r.Context())
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	roomID := extractSegment(r.URL.Path, "/api/v1/rooms/", "/invite")
	if roomID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing room_id"})
		return
	}

	var body inviteBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_body"})
		return
	}

	if len(body.Invitees) == 0 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invitees required"})
		return
	}

	result, err := h.orchestrator.InviteToRoom(r.Context(), roomID, claims.UserID, body.Invitees)
	if err != nil {
		log.Printf("invite to room error: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, result)
}

func (h *Handler) handleJoinRoom(w http.ResponseWriter, r *http.Request) {
	claims, ok := auth.ClaimsFromContext(r.Context())
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	roomID := extractSegment(r.URL.Path, "/api/v1/rooms/", "/join")
	if roomID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing room_id"})
		return
	}

	result, err := h.orchestrator.JoinGroupSession(r.Context(), roomID, claims.UserID)
	if err != nil {
		log.Printf("join room error: %v", err)
		status := http.StatusInternalServerError
		if err == ErrMaxParticipants {
			status = http.StatusForbidden
		}
		writeJSON(w, status, map[string]string{"error": err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, result)
}

func (h *Handler) handleLeaveRoom(w http.ResponseWriter, r *http.Request) {
	claims, ok := auth.ClaimsFromContext(r.Context())
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	roomID := extractSegment(r.URL.Path, "/api/v1/rooms/", "/leave")
	if roomID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing room_id"})
		return
	}

	if err := h.orchestrator.LeaveGroupSession(r.Context(), roomID, claims.UserID); err != nil {
		log.Printf("leave room error: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "left"})
}

func (h *Handler) handleEndRoom(w http.ResponseWriter, r *http.Request) {
	claims, ok := auth.ClaimsFromContext(r.Context())
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	roomID := extractSegment(r.URL.Path, "/api/v1/rooms/", "/end")
	if roomID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing room_id"})
		return
	}

	// Use EndRoomForAll which verifies the caller is the host
	if err := h.orchestrator.EndRoomForAll(r.Context(), roomID, claims.UserID); err != nil {
		log.Printf("end room error: %v", err)
		if err.Error() == "only the host can end the room for all" {
			writeJSON(w, http.StatusForbidden, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "closed"})
}

func (h *Handler) handleGetRoomParticipants(w http.ResponseWriter, r *http.Request) {
	_, ok := auth.ClaimsFromContext(r.Context())
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	roomID := extractSegment(r.URL.Path, "/api/v1/rooms/", "/participants")
	if roomID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing room_id"})
		return
	}

	participants, err := h.orchestrator.GetRoomParticipants(r.Context(), roomID)
	if err != nil {
		if err == ErrSessionNotFound {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "room_not_found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal_error"})
		return
	}

	writeJSON(w, http.StatusOK, participants)
}

// --- Helpers ---

func writeJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data) //nolint:errcheck
}

// matchPath checks if path matches prefix + ID + suffix pattern.
func matchPath(path, prefix, suffix string) bool {
	if len(path) <= len(prefix)+len(suffix) {
		return false
	}
	return path[:len(prefix)] == prefix && path[len(path)-len(suffix):] == suffix
}

// matchPrefix checks if path starts with prefix and has an ID after it.
func matchPrefix(path, prefix string) bool {
	if len(path) <= len(prefix) {
		return false
	}
	rest := path[len(prefix):]
	for _, c := range rest {
		if c == '/' {
			return false
		}
	}
	return path[:len(prefix)] == prefix
}

// extractID extracts the ID segment after a prefix.
func extractID(path, prefix string) string {
	if len(path) <= len(prefix) {
		return ""
	}
	id := path[len(prefix):]
	if len(id) > 0 && id[len(id)-1] == '/' {
		id = id[:len(id)-1]
	}
	return id
}

// extractSegment extracts the ID between prefix and suffix.
func extractSegment(path, prefix, suffix string) string {
	if len(path) <= len(prefix)+len(suffix) {
		return ""
	}
	return path[len(prefix) : len(path)-len(suffix)]
}
