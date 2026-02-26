package main

import (
	"context"
	"database/sql"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	_ "github.com/lib/pq"
	"github.com/minhgv/lalo/internal/auth"
	"github.com/minhgv/lalo/internal/config"
	"github.com/minhgv/lalo/internal/events"
	"github.com/minhgv/lalo/internal/push"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("failed to load config: %v", err)
	}

	// Postgres
	db, err := sql.Open("postgres", cfg.Postgres.DSN())
	if err != nil {
		log.Fatalf("postgres connect failed: %v", err)
	}
	defer db.Close()
	db.SetMaxOpenConns(25)
	db.SetMaxIdleConns(5)

	if err := db.Ping(); err != nil {
		log.Fatalf("postgres ping failed: %v", err)
	}

	// NATS event bus
	bus, err := events.NewBus(events.BusConfig{
		URL:            cfg.NATS.URL,
		Source:         "push-gateway",
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

	// Push token store
	store := push.NewStore(db)

	// Platform senders
	var apnsSender push.Sender
	var fcmSender push.Sender

	if cfg.Push.APNs.KeyPath != "" {
		sender, err := push.NewAPNsSender(push.APNsConfig{
			TeamID:     cfg.Push.APNs.TeamID,
			KeyID:      cfg.Push.APNs.KeyID,
			KeyPath:    cfg.Push.APNs.KeyPath,
			BundleID:   cfg.Push.APNs.BundleID,
			Production: cfg.Push.APNs.Production,
		})
		if err != nil {
			log.Fatalf("apns sender init failed: %v", err)
		}
		apnsSender = sender
		log.Println("APNs sender configured")
	} else {
		log.Println("APNs sender not configured (no key_path)")
	}

	if cfg.Push.FCM.ServerKey != "" {
		fcmSender = push.NewFCMSender(push.FCMConfig{
			ServerKey: cfg.Push.FCM.ServerKey,
			ProjectID: cfg.Push.FCM.ProjectID,
		})
		log.Println("FCM sender configured")
	} else {
		log.Println("FCM sender not configured (no server_key)")
	}

	// Gateway
	gateway := push.NewGateway(store, apnsSender, fcmSender, bus, push.GatewayConfig{
		RingTimeoutSeconds: cfg.Call.RingTimeoutSeconds,
		OnAllFailed: func(callID, callerID string) {
			log.Printf("all push devices failed for call %s, caller %s", callID, callerID)
			// Publish callee_unreachable event
			ctx := context.Background()
			bus.Publish(ctx, events.SubjectPushDelivery, map[string]string{
				"call_id":   callID,
				"caller_id": callerID,
				"status":    "callee_unreachable",
			})
		},
	})

	// Handler + Server
	handler := push.NewHandler(store)
	port := cfg.Push.Port
	if port == 0 {
		port = 8082
	}
	server := push.NewServer(handler, gateway, jwtService, port)

	// Graceful shutdown
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go func() {
		if err := server.Start(ctx); err != nil {
			log.Printf("push server stopped: %v", err)
		}
	}()

	log.Printf("push gateway started on :%d", port)

	sig := <-quit
	log.Printf("received signal %s, shutting down...", sig)

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer shutdownCancel()

	if err := server.Shutdown(shutdownCtx); err != nil {
		log.Fatalf("push server forced shutdown: %v", err)
	}

	log.Println("push gateway stopped gracefully")
}
