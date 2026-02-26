package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/minhgv/lalo/internal/abr"
	"github.com/minhgv/lalo/internal/config"
	"github.com/minhgv/lalo/internal/events"
	lk "github.com/minhgv/lalo/internal/livekit"
	"github.com/redis/go-redis/v9"
)

type metricsRequest struct {
	SessionID string             `json:"session_id"`
	UserID    string             `json:"user_id"`
	Samples   []abr.MetricSample `json:"samples"`
}

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("failed to load config: %v", err)
	}

	ctx := context.Background()

	// Redis client
	rdb := redis.NewClient(&redis.Options{
		Addr:     cfg.Redis.Addr,
		Password: cfg.Redis.Password,
		DB:       cfg.Redis.DB,
	})
	defer rdb.Close()

	if err := rdb.Ping(ctx).Err(); err != nil {
		log.Fatalf("failed to connect to redis: %v", err)
	}

	// NATS event bus
	bus, err := events.NewBus(events.BusConfig{
		URL:            cfg.NATS.URL,
		Source:         "policy-engine",
		MaxReconnects:  -1,
		ReconnectWait:  2 * time.Second,
		ConnectTimeout: 10 * time.Second,
	})
	if err != nil {
		log.Fatalf("failed to connect to NATS: %v", err)
	}
	defer bus.Close()

	// LiveKit room service
	roomService := lk.NewRoomService(cfg.LiveKit)

	// Policy engine
	policyCfg := abr.DefaultPolicyConfig()
	if cfg.PolicyEngine.EvalIntervalSeconds > 0 {
		policyCfg.EvalIntervalSeconds = cfg.PolicyEngine.EvalIntervalSeconds
	}
	if cfg.PolicyEngine.MetricWindowSeconds > 0 {
		policyCfg.MetricWindowSeconds = cfg.PolicyEngine.MetricWindowSeconds
	}
	if len(cfg.PolicyEngine.Rules) > 0 {
		policyCfg.Rules = make([]abr.PolicyRule, 0, len(cfg.PolicyEngine.Rules))
		for _, rule := range cfg.PolicyEngine.Rules {
			policyCfg.Rules = append(policyCfg.Rules, abr.PolicyRule{
				Name:        rule.Name,
				Condition:   rule.Condition,
				Threshold:   rule.Threshold,
				Action:      rule.Action,
				ActionValue: rule.ActionValue,
			})
		}
	}

	engine := abr.NewPolicyEngine(policyCfg, cfg.Quality, roomService)
	engine.Start()
	defer engine.Stop()

	mux := http.NewServeMux()

	mux.HandleFunc("/v1/policy/metrics", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method_not_allowed"})
			return
		}

		var req metricsRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_body"})
			return
		}

		if req.SessionID == "" || req.UserID == "" || len(req.Samples) == 0 {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "session_id, user_id and samples are required"})
			return
		}

		now := time.Now()
		for i := range req.Samples {
			if req.Samples[i].Timestamp.IsZero() {
				req.Samples[i].Timestamp = now
			}
		}

		engine.IngestMetrics(req.SessionID, req.UserID, req.Samples)
		writeJSON(w, http.StatusAccepted, map[string]string{"status": "ingested"})
	})

	mux.HandleFunc("/v1/policy/health", func(w http.ResponseWriter, _ *http.Request) {
		redisConnected := rdb.Ping(context.Background()).Err() == nil

		status := http.StatusOK
		if !redisConnected || !bus.IsConnected() {
			status = http.StatusServiceUnavailable
		}

		writeJSON(w, status, map[string]interface{}{
			"status":          map[bool]string{true: "ok", false: "degraded"}[status == http.StatusOK],
			"service":         "policy-engine",
			"redis_connected": redisConnected,
			"nats_connected":  bus.IsConnected(),
		})
	})

	mux.HandleFunc("/v1/policy/participant/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method_not_allowed"})
			return
		}

		path := strings.TrimPrefix(r.URL.Path, "/v1/policy/participant/")
		parts := strings.Split(path, "/")
		if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid participant path"})
			return
		}

		sessionID := parts[0]
		userID := parts[1]

		decision := engine.GetParticipantPolicy(sessionID, userID)
		if decision == nil {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "policy_not_found"})
			return
		}

		writeJSON(w, http.StatusOK, decision)
	})

	server := &http.Server{
		Addr:         fmt.Sprintf(":%d", cfg.Server.Port),
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	go func() {
		log.Printf("policy engine HTTP server listening on :%d", cfg.Server.Port)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Printf("policy engine HTTP server error: %v", err)
		}
	}()

	// Block until shutdown signal
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	sig := <-quit

	log.Printf("received signal %s, shutting down...", sig)

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	engine.Stop()

	if err := server.Shutdown(shutdownCtx); err != nil {
		log.Printf("policy engine HTTP server shutdown error: %v", err)
	}

	log.Println("policy engine stopped gracefully")
}

func writeJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(data)
}
