package push

import (
	"encoding/json"
	"net/http"

	"github.com/minhgv/lalo/internal/auth"
)

// Handler provides HTTP endpoints for push token management.
type Handler struct {
	store *Store
}

// NewHandler creates a new push token HTTP handler.
func NewHandler(store *Store) *Handler {
	return &Handler{store: store}
}

// RegisterToken handles POST /v1/push/register.
func (h *Handler) RegisterToken(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
		return
	}

	claims, ok := auth.ClaimsFromContext(r.Context())
	if !ok {
		http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
		return
	}

	var req RegisterRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request body"}`, http.StatusBadRequest)
		return
	}

	if err := req.Validate(); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}

	token, err := h.store.Register(r.Context(), claims.UserID, &req)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to register token"})
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"status": "registered",
		"token":  token,
	})
}

// UnregisterToken handles DELETE /v1/push/unregister.
func (h *Handler) UnregisterToken(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
		return
	}

	claims, ok := auth.ClaimsFromContext(r.Context())
	if !ok {
		http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
		return
	}

	var req UnregisterRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request body"}`, http.StatusBadRequest)
		return
	}

	if req.DeviceID == "" {
		http.Error(w, `{"error":"device_id is required"}`, http.StatusBadRequest)
		return
	}

	err := h.store.Unregister(r.Context(), claims.UserID, req.DeviceID)
	if err != nil {
		if err == ErrTokenNotFound {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "token not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to unregister token"})
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "unregistered"})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}
