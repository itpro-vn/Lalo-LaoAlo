package turn

import (
	"context"
	"fmt"
	"net"
	"testing"
	"time"
)

func TestParseAddr(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"turn:example.com:3478", "example.com:3478"},
		{"turns:example.com:5349", "example.com:5349"},
		{"example.com:3478", "example.com:3478"},
		{"example.com", "example.com:3478"},
		{"turn:10.0.0.1:3478", "10.0.0.1:3478"},
	}
	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			got := parseAddr(tt.input)
			if got != tt.expected {
				t.Errorf("parseAddr(%q) = %q, want %q", tt.input, got, tt.expected)
			}
		})
	}
}

func TestHealthChecker_LocalTCP(t *testing.T) {
	// Start a local TCP listener to simulate a TURN server
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("failed to start test listener: %v", err)
	}
	defer ln.Close()

	// Accept connections in background
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			conn.Close()
		}
	}()

	addr := ln.Addr().String()
	uri := fmt.Sprintf("turn:%s", addr)

	hc := NewHealthChecker(
		[]string{uri},
		100*time.Millisecond,
		2*time.Second,
	)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	hc.Start(ctx)

	// Wait for initial check
	time.Sleep(200 * time.Millisecond)

	// Verify healthy
	if !hc.IsHealthy(uri) {
		t.Error("expected server to be healthy")
	}

	healthy := hc.HealthyServers()
	if len(healthy) != 1 {
		t.Errorf("expected 1 healthy server, got %d", len(healthy))
	}

	statuses := hc.AllStatuses()
	if len(statuses) != 1 {
		t.Fatalf("expected 1 status, got %d", len(statuses))
	}
	if statuses[0].Latency < 0 {
		t.Error("expected non-negative latency")
	}
	if statuses[0].Error != "" {
		t.Errorf("expected no error, got %s", statuses[0].Error)
	}

	// Stop listener and wait for unhealthy detection
	ln.Close()
	time.Sleep(300 * time.Millisecond)

	if hc.IsHealthy(uri) {
		t.Error("expected server to be unhealthy after listener closed")
	}

	hc.Stop()
}

func TestHealthChecker_UnreachableServer(t *testing.T) {
	// Use a port that definitely has nothing listening
	uri := "turn:127.0.0.1:59999"
	hc := NewHealthChecker(
		[]string{uri},
		100*time.Millisecond,
		500*time.Millisecond,
	)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	hc.Start(ctx)

	time.Sleep(200 * time.Millisecond)

	if hc.IsHealthy(uri) {
		t.Error("expected unreachable server to be unhealthy")
	}

	statuses := hc.AllStatuses()
	if len(statuses) != 1 {
		t.Fatalf("expected 1 status, got %d", len(statuses))
	}
	if statuses[0].Error == "" {
		t.Error("expected error message for unreachable server")
	}

	hc.Stop()
}

func TestHealthChecker_MultipleServers(t *testing.T) {
	// One healthy, one unhealthy
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			conn.Close()
		}
	}()

	healthyURI := fmt.Sprintf("turn:%s", ln.Addr().String())
	unhealthyURI := "turn:127.0.0.1:59998"

	hc := NewHealthChecker(
		[]string{healthyURI, unhealthyURI},
		100*time.Millisecond,
		500*time.Millisecond,
	)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	hc.Start(ctx)

	time.Sleep(300 * time.Millisecond)

	if !hc.IsHealthy(healthyURI) {
		t.Error("expected healthy server to be healthy")
	}
	if hc.IsHealthy(unhealthyURI) {
		t.Error("expected unreachable server to be unhealthy")
	}

	healthy := hc.HealthyServers()
	if len(healthy) != 1 {
		t.Errorf("expected 1 healthy server, got %d", len(healthy))
	}

	hc.Stop()
}

func TestHealthChecker_NonExistentURI(t *testing.T) {
	hc := NewHealthChecker(
		[]string{"turn:127.0.0.1:3478"},
		time.Hour, // won't tick in test
		time.Second,
	)
	// No Start — just check that IsHealthy returns false for unknown URI
	if hc.IsHealthy("turn:unknown:3478") {
		t.Error("expected false for untracked URI")
	}
}

func TestNewHealthChecker_Defaults(t *testing.T) {
	hc := NewHealthChecker([]string{"turn:a:3478"}, 0, 0)
	if hc.interval != 10*time.Second {
		t.Errorf("expected default interval 10s, got %v", hc.interval)
	}
	if hc.timeout != 5*time.Second {
		t.Errorf("expected default timeout 5s, got %v", hc.timeout)
	}
}
