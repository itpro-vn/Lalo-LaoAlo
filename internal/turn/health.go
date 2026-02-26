package turn

import (
	"context"
	"fmt"
	"net"
	"sync"
	"time"
)

// ServerStatus represents the health status of a TURN server.
type ServerStatus struct {
	URI       string `json:"uri"`
	Healthy   bool   `json:"healthy"`
	Latency   int64  `json:"latency_ms"`
	LastCheck time.Time `json:"last_check"`
	Error     string `json:"error,omitempty"`
}

// HealthChecker monitors TURN server availability.
type HealthChecker struct {
	servers  []string
	interval time.Duration
	timeout  time.Duration

	mu       sync.RWMutex
	statuses map[string]*ServerStatus
	cancel   context.CancelFunc
}

// NewHealthChecker creates a health checker for the given TURN server URIs.
// URIs should be in format "turn:host:port" or "host:port".
func NewHealthChecker(serverURIs []string, interval, timeout time.Duration) *HealthChecker {
	if interval <= 0 {
		interval = 10 * time.Second
	}
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	statuses := make(map[string]*ServerStatus, len(serverURIs))
	for _, uri := range serverURIs {
		statuses[uri] = &ServerStatus{URI: uri}
	}
	return &HealthChecker{
		servers:  serverURIs,
		interval: interval,
		timeout:  timeout,
		statuses: statuses,
	}
}

// Start begins periodic health checks.
func (h *HealthChecker) Start(ctx context.Context) {
	ctx, h.cancel = context.WithCancel(ctx)

	// Initial check
	h.checkAll()

	go func() {
		ticker := time.NewTicker(h.interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				h.checkAll()
			}
		}
	}()
}

// Stop stops periodic health checks.
func (h *HealthChecker) Stop() {
	if h.cancel != nil {
		h.cancel()
	}
}

// checkAll runs a health check against all servers.
func (h *HealthChecker) checkAll() {
	var wg sync.WaitGroup
	for _, uri := range h.servers {
		wg.Add(1)
		go func(uri string) {
			defer wg.Done()
			h.check(uri)
		}(uri)
	}
	wg.Wait()
}

// check tests TCP connectivity to a single TURN server.
func (h *HealthChecker) check(uri string) {
	addr := parseAddr(uri)
	start := time.Now()

	conn, err := net.DialTimeout("tcp", addr, h.timeout)
	latency := time.Since(start).Milliseconds()

	h.mu.Lock()
	defer h.mu.Unlock()

	status := h.statuses[uri]
	status.LastCheck = time.Now()
	status.Latency = latency

	if err != nil {
		status.Healthy = false
		status.Error = err.Error()
	} else {
		status.Healthy = true
		status.Error = ""
		conn.Close()
	}
}

// HealthyServers returns URIs of all currently healthy TURN servers.
func (h *HealthChecker) HealthyServers() []string {
	h.mu.RLock()
	defer h.mu.RUnlock()

	var healthy []string
	for _, s := range h.statuses {
		if s.Healthy {
			healthy = append(healthy, s.URI)
		}
	}
	return healthy
}

// AllStatuses returns the current status of all servers.
func (h *HealthChecker) AllStatuses() []ServerStatus {
	h.mu.RLock()
	defer h.mu.RUnlock()

	result := make([]ServerStatus, 0, len(h.statuses))
	for _, s := range h.statuses {
		result = append(result, *s)
	}
	return result
}

// IsHealthy returns whether a specific server URI is healthy.
func (h *HealthChecker) IsHealthy(uri string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()

	if s, ok := h.statuses[uri]; ok {
		return s.Healthy
	}
	return false
}

// parseAddr extracts host:port from a TURN URI.
// Supports "turn:host:port", "turns:host:port", or plain "host:port".
func parseAddr(uri string) string {
	// Strip turn: or turns: prefix
	for _, prefix := range []string{"turns:", "turn:"} {
		if len(uri) > len(prefix) && uri[:len(prefix)] == prefix {
			uri = uri[len(prefix):]
			break
		}
	}
	// Default port if missing
	_, _, err := net.SplitHostPort(uri)
	if err != nil {
		return fmt.Sprintf("%s:3478", uri)
	}
	return uri
}
