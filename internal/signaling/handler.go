package signaling

import (
	"log"
	"net/http"

	"github.com/gorilla/websocket"
	"github.com/minhgv/lalo/internal/auth"
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	CheckOrigin: func(r *http.Request) bool {
		// TODO: restrict origins in production
		return true
	},
}

// Handler handles WebSocket upgrade and JWT authentication.
type Handler struct {
	hub        *Hub
	jwtService *auth.JWTService
}

// NewHandler creates a new signaling handler.
func NewHandler(hub *Hub, jwtService *auth.JWTService) *Handler {
	return &Handler{
		hub:        hub,
		jwtService: jwtService,
	}
}

// ServeWS handles WebSocket upgrade requests.
// JWT token is extracted from Authorization header or ?token= query param.
func (h *Handler) ServeWS(w http.ResponseWriter, r *http.Request) {
	// Extract and validate JWT
	token := r.URL.Query().Get("token")
	if token == "" {
		authHeader := r.Header.Get("Authorization")
		if len(authHeader) > 7 && authHeader[:7] == "Bearer " {
			token = authHeader[7:]
		}
	}

	if token == "" {
		http.Error(w, "missing authentication token", http.StatusUnauthorized)
		return
	}

	claims, err := h.jwtService.Validate(token)
	if err != nil {
		http.Error(w, "invalid token", http.StatusUnauthorized)
		return
	}

	if claims.TokenType != "access" {
		http.Error(w, "access token required", http.StatusUnauthorized)
		return
	}

	// Upgrade to WebSocket
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("ws upgrade error: %v", err)
		return
	}

	client := NewClient(h.hub, conn, claims.UserID, claims.DeviceID)
	h.hub.register <- client

	// Start read/write pumps
	go client.WritePump()
	go client.ReadPump()
}
