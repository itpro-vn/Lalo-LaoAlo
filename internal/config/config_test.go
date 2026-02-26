package config

import (
	"os"
	"testing"
)

func TestLoadFromFile(t *testing.T) {
	cfg, err := LoadFromFile("../../configs/call-config.yaml")
	if err != nil {
		t.Fatalf("failed to load config: %v", err)
	}

	// Verify call config parsed correctly
	if cfg.Call.RingTimeoutSeconds != 45 {
		t.Errorf("expected ring_timeout_seconds=45, got %d", cfg.Call.RingTimeoutSeconds)
	}
	if cfg.Call.ICETimeoutSeconds != 15 {
		t.Errorf("expected ice_timeout_seconds=15, got %d", cfg.Call.ICETimeoutSeconds)
	}
	if cfg.Call.MaxReconnectAttempts != 3 {
		t.Errorf("expected max_reconnect_attempts=3, got %d", cfg.Call.MaxReconnectAttempts)
	}
	if len(cfg.Call.ReconnectBackoff) != 3 {
		t.Errorf("expected 3 reconnect_backoff values, got %d", len(cfg.Call.ReconnectBackoff))
	}

	// Verify quality tiers
	if cfg.Quality.Tiers.Good.RTTMaxMs != 120 {
		t.Errorf("expected good.rtt_max_ms=120, got %d", cfg.Quality.Tiers.Good.RTTMaxMs)
	}
	if cfg.Quality.Tiers.Fair.LossMaxPct != 6 {
		t.Errorf("expected fair.loss_max_pct=6, got %f", cfg.Quality.Tiers.Fair.LossMaxPct)
	}

	// Verify audio config
	if cfg.Quality.Audio.Codec != "opus" {
		t.Errorf("expected audio codec=opus, got %s", cfg.Quality.Audio.Codec)
	}
	if !cfg.Quality.Audio.DTX {
		t.Error("expected audio dtx=true")
	}

	// Verify group config
	if cfg.Group.MaxParticipants != 8 {
		t.Errorf("expected max_participants=8, got %d", cfg.Group.MaxParticipants)
	}

	// Verify defaults applied
	if cfg.Server.Port != 8080 {
		t.Errorf("expected default server port=8080, got %d", cfg.Server.Port)
	}
	if cfg.Postgres.Host != "localhost" {
		t.Errorf("expected default postgres host=localhost, got %s", cfg.Postgres.Host)
	}
}

func TestEnvOverrides(t *testing.T) {
	os.Setenv("SERVER_PORT", "9090")
	os.Setenv("POSTGRES_HOST", "db.example.com")
	defer func() {
		os.Unsetenv("SERVER_PORT")
		os.Unsetenv("POSTGRES_HOST")
	}()

	cfg, err := LoadFromFile("../../configs/call-config.yaml")
	if err != nil {
		t.Fatalf("failed to load config: %v", err)
	}

	if cfg.Server.Port != 9090 {
		t.Errorf("expected SERVER_PORT override to 9090, got %d", cfg.Server.Port)
	}
	if cfg.Postgres.Host != "db.example.com" {
		t.Errorf("expected POSTGRES_HOST override, got %s", cfg.Postgres.Host)
	}
}

func TestLoadFromFile_NotFound(t *testing.T) {
	_, err := LoadFromFile("nonexistent.yaml")
	if err == nil {
		t.Error("expected error for missing config file")
	}
}

func TestLoadFromFile_InvalidYAML(t *testing.T) {
	tmpFile, err := os.CreateTemp("", "bad-config-*.yaml")
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(tmpFile.Name())

	tmpFile.WriteString("{{invalid yaml")
	tmpFile.Close()

	_, err = LoadFromFile(tmpFile.Name())
	if err == nil {
		t.Error("expected error for invalid YAML")
	}
}
