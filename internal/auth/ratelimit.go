package auth

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

// RateLimiter checks request rates using Redis sliding window.
type RateLimiter struct {
	client *redis.Client
}

// NewRateLimiter creates a new Redis-backed rate limiter.
func NewRateLimiter(client *redis.Client) *RateLimiter {
	return &RateLimiter{client: client}
}

// RateLimit defines a rate limit rule.
type RateLimit struct {
	Key      string
	Limit    int
	Window   time.Duration
}

// ParseRateLimit parses a rate limit string like "10/min" or "60/min".
func ParseRateLimit(key, spec string) (*RateLimit, error) {
	parts := strings.SplitN(spec, "/", 2)
	if len(parts) != 2 {
		return nil, fmt.Errorf("invalid rate limit format: %s", spec)
	}

	limit, err := strconv.Atoi(parts[0])
	if err != nil {
		return nil, fmt.Errorf("invalid rate limit count: %s", parts[0])
	}

	var window time.Duration
	switch parts[1] {
	case "s", "sec", "second":
		window = time.Second
	case "m", "min", "minute":
		window = time.Minute
	case "h", "hr", "hour":
		window = time.Hour
	default:
		return nil, fmt.Errorf("invalid rate limit window: %s", parts[1])
	}

	return &RateLimit{Key: key, Limit: limit, Window: window}, nil
}

// Allow checks if a request is allowed under the rate limit.
// Uses Redis sorted set sliding window algorithm.
func (r *RateLimiter) Allow(ctx context.Context, rl *RateLimit, identifier string) (bool, error) {
	key := fmt.Sprintf("rl:%s:%s", rl.Key, identifier)
	now := time.Now()
	windowStart := now.Add(-rl.Window)

	pipe := r.client.Pipeline()

	// Remove expired entries
	pipe.ZRemRangeByScore(ctx, key, "-inf", fmt.Sprintf("%d", windowStart.UnixMicro()))

	// Count entries in window
	countCmd := pipe.ZCard(ctx, key)

	// Add current request
	pipe.ZAdd(ctx, key, redis.Z{
		Score:  float64(now.UnixMicro()),
		Member: fmt.Sprintf("%d", now.UnixNano()),
	})

	// Set TTL on the key
	pipe.Expire(ctx, key, rl.Window+time.Second)

	_, err := pipe.Exec(ctx)
	if err != nil {
		return false, fmt.Errorf("rate limit check: %w", err)
	}

	count := countCmd.Val()
	return count < int64(rl.Limit), nil
}

// Remaining returns how many requests are left in the current window.
func (r *RateLimiter) Remaining(ctx context.Context, rl *RateLimit, identifier string) (int, error) {
	key := fmt.Sprintf("rl:%s:%s", rl.Key, identifier)
	windowStart := time.Now().Add(-rl.Window)

	// Remove expired, then count
	pipe := r.client.Pipeline()
	pipe.ZRemRangeByScore(ctx, key, "-inf", fmt.Sprintf("%d", windowStart.UnixMicro()))
	countCmd := pipe.ZCard(ctx, key)
	_, err := pipe.Exec(ctx)
	if err != nil {
		return 0, fmt.Errorf("rate limit remaining: %w", err)
	}

	remaining := rl.Limit - int(countCmd.Val())
	if remaining < 0 {
		remaining = 0
	}
	return remaining, nil
}
