package session

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"

	"github.com/minhgv/lalo/internal/auth"
)

// Server is the HTTP server for the session orchestrator REST API.
type Server struct {
	httpServer *http.Server
	handler    *Handler
	auth       *auth.HTTPHandler
	jwtService *auth.JWTService
	port       int
}

// NewServer creates a new orchestrator HTTP server.
func NewServer(handler *Handler, jwtService *auth.JWTService, port int) *Server {
	return &Server{
		handler:    handler,
		auth:       auth.NewHTTPHandler(jwtService),
		jwtService: jwtService,
		port:       port,
	}
}

// Start begins listening for HTTP requests.
func (s *Server) Start() error {
	mux := http.NewServeMux()

	// Health check — no auth required
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{ //nolint:errcheck
			"status":  "ok",
			"service": "orchestrator",
		})
	})

	// LiveKit webhook endpoint — no JWT auth (has its own signature validation)
	// Placeholder for PA-08 webhook handler integration
	mux.HandleFunc("/webhook/livekit", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	// Session API — JWT protected
	mux.Handle("/api/v1/sessions", auth.JWTMiddleware(s.jwtService)(s.handler))
	mux.Handle("/api/v1/sessions/", auth.JWTMiddleware(s.jwtService)(s.handler))

	// Room (group call) API — JWT protected
	mux.Handle("/api/v1/rooms", auth.JWTMiddleware(s.jwtService)(s.handler))
	mux.Handle("/api/v1/rooms/", auth.JWTMiddleware(s.jwtService)(s.handler))

	// Auth API
	mux.Handle("/api/v1/auth/login", s.auth)
	mux.Handle("/api/v1/auth/refresh", s.auth)
	mux.Handle("/api/v1/auth/me", auth.JWTMiddleware(s.jwtService)(s.auth))
	mux.Handle("/v1/auth/login", s.auth)
	mux.Handle("/v1/auth/refresh", s.auth)
	mux.Handle("/v1/auth/me", auth.JWTMiddleware(s.jwtService)(s.auth))

	s.httpServer = &http.Server{
		Addr:    fmt.Sprintf(":%d", s.port),
		Handler: mux,
	}

	ln, err := net.Listen("tcp", s.httpServer.Addr)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", s.httpServer.Addr, err)
	}

	go func() {
		log.Printf("orchestrator HTTP server listening on :%d", s.port)
		if err := s.httpServer.Serve(ln); err != nil && err != http.ErrServerClosed {
			log.Printf("orchestrator HTTP server error: %v", err)
		}
	}()

	return nil
}

// Shutdown gracefully shuts down the HTTP server.
func (s *Server) Shutdown(ctx context.Context) error {
	if s.httpServer != nil {
		return s.httpServer.Shutdown(ctx)
	}
	return nil
}
