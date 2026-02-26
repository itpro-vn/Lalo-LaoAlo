package push

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"time"

	"github.com/minhgv/lalo/internal/auth"
)

// Server is the Push Gateway HTTP server.
type Server struct {
	handler    *Handler
	gateway    *Gateway
	httpServer *http.Server
	jwtService *auth.JWTService
}

// NewServer creates a new push gateway server.
func NewServer(handler *Handler, gateway *Gateway, jwtService *auth.JWTService, port int) *Server {
	mux := http.NewServeMux()
	s := &Server{
		handler:    handler,
		gateway:    gateway,
		jwtService: jwtService,
	}

	// Auth middleware
	authMiddleware := auth.JWTMiddleware(jwtService)

	// Routes
	mux.HandleFunc("/health", s.healthHandler)
	mux.Handle("/v1/push/register", authMiddleware(http.HandlerFunc(handler.RegisterToken)))
	mux.Handle("/v1/push/unregister", authMiddleware(http.HandlerFunc(handler.UnregisterToken)))

	s.httpServer = &http.Server{
		Addr:         fmt.Sprintf(":%d", port),
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	return s
}

// Start starts the HTTP server and NATS event subscription.
func (s *Server) Start(ctx context.Context) error {
	// Subscribe to call events for push delivery
	if err := s.gateway.SubscribeToCallEvents(ctx); err != nil {
		return fmt.Errorf("subscribe to call events: %w", err)
	}

	log.Printf("push gateway listening on %s", s.httpServer.Addr)
	if err := s.httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		return err
	}
	return nil
}

// Shutdown gracefully stops the server.
func (s *Server) Shutdown(ctx context.Context) error {
	return s.httpServer.Shutdown(ctx)
}

func (s *Server) healthHandler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(`{"status":"ok","service":"push-gateway"}`))
}
