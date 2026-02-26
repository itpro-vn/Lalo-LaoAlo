package signaling

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"time"

	"github.com/minhgv/lalo/internal/auth"
	"github.com/minhgv/lalo/internal/config"
	"github.com/minhgv/lalo/internal/events"
	"github.com/minhgv/lalo/internal/session"
	"github.com/redis/go-redis/v9"
)

// Server is the signaling HTTP/WS server.
type Server struct {
	httpServer *http.Server
	hub        *Hub
	handler    *Handler
	cfg        *config.Config
}

// NewServer creates a new signaling server. The orch parameter is optional
// and enables group call support when provided.
func NewServer(cfg *config.Config, rdb *redis.Client, bus *events.Bus, jwtService *auth.JWTService, orch *session.Orchestrator) *Server {
	sessions := NewSessionStore(rdb)
	hub := NewHub(sessions, bus, cfg, orch)
	handler := NewHandler(hub, jwtService, cfg.Server.AllowedOrigins)

	mux := http.NewServeMux()
	mux.HandleFunc("/ws", handler.ServeWS)
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"status":"ok"}`))
	})

	httpServer := &http.Server{
		Addr:         fmt.Sprintf(":%d", cfg.Server.Port),
		Handler:      mux,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	return &Server{
		httpServer: httpServer,
		hub:        hub,
		handler:    handler,
		cfg:        cfg,
	}
}

// Start begins serving and runs the hub event loop.
func (s *Server) Start() error {
	go s.hub.Run()
	log.Printf("signaling server listening on %s", s.httpServer.Addr)
	return s.httpServer.ListenAndServe()
}

// Shutdown gracefully stops the server.
func (s *Server) Shutdown(ctx context.Context) error {
	s.hub.Stop()
	return s.httpServer.Shutdown(ctx)
}
