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

	"github.com/minhgv/lalo/internal/auth"
	"github.com/minhgv/lalo/internal/config"
	"github.com/minhgv/lalo/internal/events"
	"github.com/minhgv/lalo/internal/session"
	"github.com/minhgv/lalo/internal/signaling"
	_ "github.com/lib/pq"
	"github.com/redis/go-redis/v9"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("failed to load config: %v", err)
	}

	// Redis
	rdb := redis.NewClient(&redis.Options{
		Addr:     cfg.Redis.Addr,
		Password: cfg.Redis.Password,
		DB:       cfg.Redis.DB,
	})
	defer rdb.Close()

	ctx := context.Background()
	if err := rdb.Ping(ctx).Err(); err != nil {
		log.Fatalf("redis connect failed: %v", err)
	}

	// NATS event bus
	bus, err := events.NewBus(events.BusConfig{
		URL:            cfg.NATS.URL,
		Source:         "signaling",
		MaxReconnects:  -1,
		ReconnectWait:  2 * time.Second,
		ConnectTimeout: 10 * time.Second,
	})
	if err != nil {
		log.Fatalf("nats connect failed: %v", err)
	}
	defer bus.Close()

	// Auth
	jwtService, err := auth.NewJWTService(
		cfg.Auth.JWTSecret,
		cfg.Auth.AccessTokenExpiryMins,
		cfg.Auth.RefreshTokenExpiryDays,
	)
	if err != nil {
		log.Fatalf("jwt service init failed: %v", err)
	}

	// Signaling server (with optional group call orchestrator)
	var orch *session.Orchestrator
	if cfg.Postgres.Host != "" {
		dsn := "host=" + cfg.Postgres.Host +
			" port=" + fmt.Sprintf("%d", cfg.Postgres.Port) +
			" user=" + cfg.Postgres.User +
			" password=" + cfg.Postgres.Password +
			" dbname=" + cfg.Postgres.DBName +
			" sslmode=" + cfg.Postgres.SSLMode
		db, dbErr := sql.Open("postgres", dsn)
		if dbErr != nil {
			log.Printf("postgres unavailable, group calls disabled: %v", dbErr)
		} else {
			defer db.Close()
			turnSvc := auth.NewTurnService(cfg.Auth.TurnSecret, cfg.Turn.AllocationTTLSeconds, cfg.Turn.Servers)
			lkSvc := auth.NewLiveKitTokenService(cfg.LiveKit.APIKey, cfg.LiveKit.APISecret)
			orch = session.NewOrchestrator(rdb, bus, db, turnSvc, lkSvc, cfg)
			log.Println("group call orchestrator initialized")
		}
	}

	server := signaling.NewServer(cfg, rdb, bus, jwtService, orch)

	// Graceful shutdown
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		if err := server.Start(); err != nil {
			log.Printf("server stopped: %v", err)
		}
	}()

	log.Printf("signaling server started on :%d", cfg.Server.Port)

	sig := <-quit
	log.Printf("received signal %s, shutting down...", sig)

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := server.Shutdown(shutdownCtx); err != nil {
		log.Fatalf("server forced shutdown: %v", err)
	}

	log.Println("server stopped gracefully")
}
