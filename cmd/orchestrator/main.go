package main

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	_ "github.com/lib/pq"
	"github.com/minhgv/lalo/internal/auth"
	"github.com/minhgv/lalo/internal/config"
	"github.com/minhgv/lalo/internal/events"
	"github.com/minhgv/lalo/internal/session"
	"github.com/redis/go-redis/v9"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("failed to load config: %v", err)
	}

	// Redis client
	rdb := redis.NewClient(&redis.Options{
		Addr:     cfg.Redis.Addr,
		Password: cfg.Redis.Password,
		DB:       cfg.Redis.DB,
	})

	// NATS event bus
	bus, err := events.NewBus(events.BusConfig{
		URL:    cfg.NATS.URL,
		Source: "orchestrator",
	})
	if err != nil {
		log.Fatalf("failed to connect to NATS: %v", err)
	}
	defer bus.Close()

	// Postgres
	db, err := sql.Open("postgres", cfg.Postgres.DSN())
	if err != nil {
		log.Fatalf("failed to connect to postgres: %v", err)
	}
	defer db.Close()

	// Auth services
	turnSvc := auth.NewTurnService(
		cfg.Auth.TurnSecret,
		cfg.Turn.CredentialTTLSeconds,
		nil, // TURN URIs from config/env
	)
	lkSvc := auth.NewLiveKitTokenService(cfg.LiveKit.APIKey, cfg.LiveKit.APISecret)
	jwtSvc, err := auth.NewJWTService(
		cfg.Auth.JWTSecret,
		cfg.Auth.AccessTokenExpiryMins,
		cfg.Auth.RefreshTokenExpiryDays,
	)
	if err != nil {
		log.Fatalf("failed to create JWT service: %v", err)
	}

	// Create orchestrator
	orch := session.NewOrchestrator(rdb, bus, db, turnSvc, lkSvc, cfg)

	// REST API handler + server
	handler := session.NewHandler(orch, jwtSvc)
	server := session.NewServer(handler, jwtSvc, cfg.Orchestrator.Port)

	if err := server.Start(); err != nil {
		log.Fatalf("failed to start orchestrator HTTP server: %v", err)
	}

	log.Printf("orchestrator starting on :%d", cfg.Orchestrator.Port)

	// Block until shutdown signal
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	sig := <-quit

	fmt.Printf("received signal %s, shutting down...\n", sig)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		log.Printf("orchestrator HTTP server shutdown error: %v", err)
	}
}
