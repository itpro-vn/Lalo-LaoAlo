// Package config provides configuration loading and validation
// for all Lalo services. Config is loaded from YAML files and
// environment variable overrides.
package config

import (
	"fmt"
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

// Config is the root configuration for all services.
type Config struct {
	Server       ServerConfig       `yaml:"server"`
	Auth         AuthConfig         `yaml:"auth"`
	Call         CallConfig         `yaml:"call"`
	Quality      QualityConfig      `yaml:"quality"`
	Group        GroupConfig        `yaml:"group"`
	Turn         TurnConfig         `yaml:"turn"`
	RateLimits   RateLimitConfig    `yaml:"rate_limits"`
	LiveKit      LiveKitConfig      `yaml:"livekit"`
	Push         PushCfg            `yaml:"push"`
	Orchestrator OrchestratorCfg    `yaml:"orchestrator"`
	Postgres     PostgresConfig     `yaml:"postgres"`
	Redis        RedisConfig        `yaml:"redis"`
	NATS         NATSConfig         `yaml:"nats"`
	ClickHouse   ClickHouseConfig   `yaml:"clickhouse"`
	PolicyEngine PolicyEngineConfig `yaml:"policy_engine"`
}

// AuthConfig holds JWT authentication settings.
type AuthConfig struct {
	JWTSecret              string `yaml:"jwt_secret"`
	AccessTokenExpiryMins  int    `yaml:"access_token_expiry_mins"`
	RefreshTokenExpiryDays int    `yaml:"refresh_token_expiry_days"`
	TurnSecret             string `yaml:"turn_secret"`
}

// LiveKitConfig holds LiveKit SFU connection settings.
type LiveKitConfig struct {
	Host      string `yaml:"host"`
	APIKey    string `yaml:"api_key"`
	APISecret string `yaml:"api_secret"`
}

// PushCfg holds push notification gateway settings.
type PushCfg struct {
	Port int     `yaml:"port"`
	APNs APNsCfg `yaml:"apns"`
	FCM  FCMCfg  `yaml:"fcm"`
}

// OrchestratorCfg holds orchestrator HTTP server settings.
type OrchestratorCfg struct {
	Port int `yaml:"port"`
}

// APNsCfg holds Apple Push Notification service settings.
type APNsCfg struct {
	TeamID     string `yaml:"team_id"`
	KeyID      string `yaml:"key_id"`
	KeyPath    string `yaml:"key_path"`
	BundleID   string `yaml:"bundle_id"`
	Production bool   `yaml:"production"`
}

// FCMCfg holds Firebase Cloud Messaging settings.
type FCMCfg struct {
	ServerKey string `yaml:"server_key"`
	ProjectID string `yaml:"project_id"`
}

// ServerConfig holds common server settings.
type ServerConfig struct {
	Port           int      `yaml:"port"`
	Host           string   `yaml:"host"`
	AllowedOrigins []string `yaml:"allowed_origins"`
}

// CallConfig holds call timing and reconnection parameters.
type CallConfig struct {
	RingTimeoutSeconds    int   `yaml:"ring_timeout_seconds"`
	ICETimeoutSeconds     int   `yaml:"ice_timeout_seconds"`
	CleanupTimeoutSeconds int   `yaml:"cleanup_timeout_seconds"`
	MaxReconnectAttempts  int   `yaml:"max_reconnect_attempts"`
	ReconnectBackoff      []int `yaml:"reconnect_backoff"`
}

// QualityConfig holds adaptive quality settings.
type QualityConfig struct {
	Tiers      QualityTiers     `yaml:"tiers"`
	Hysteresis HysteresisConfig `yaml:"hysteresis"`
	Audio      AudioConfig      `yaml:"audio"`
	Video      VideoConfig      `yaml:"video"`
	Bandwidth  BandwidthConfig  `yaml:"bandwidth"`
}

// QualityTiers defines thresholds for network quality classification.
type QualityTiers struct {
	Good QualityTier `yaml:"good"`
	Fair QualityTier `yaml:"fair"`
	Poor QualityTier `yaml:"poor"`
}

// QualityTier defines threshold values for a single quality tier.
type QualityTier struct {
	RTTMaxMs      int     `yaml:"rtt_max_ms,omitempty"`
	RTTAboveMs    int     `yaml:"rtt_above_ms,omitempty"`
	LossMaxPct    float64 `yaml:"loss_max_pct,omitempty"`
	LossAbovePct  float64 `yaml:"loss_above_pct,omitempty"`
	JitterMaxMs   int     `yaml:"jitter_max_ms,omitempty"`
	JitterAboveMs int     `yaml:"jitter_above_ms,omitempty"`
}

// HysteresisConfig controls quality tier transition timing.
type HysteresisConfig struct {
	UpgradeStableSeconds          int `yaml:"upgrade_stable_seconds"`
	DowngradeFairSeconds          int `yaml:"downgrade_fair_seconds"`
	DowngradePoorSeconds          int `yaml:"downgrade_poor_seconds"`
	MaxCodecChangeIntervalSeconds int `yaml:"max_codec_change_interval_seconds"`
}

// AudioConfig holds audio codec settings.
type AudioConfig struct {
	Codec               string `yaml:"codec"`
	DTX                 bool   `yaml:"dtx"`
	FECThresholdLossPct int    `yaml:"fec_threshold_loss_pct"`
	BitrateRangeKbps    []int  `yaml:"bitrate_range_kbps"`
}

// VideoConfig holds video codec and simulcast settings.
type VideoConfig struct {
	Codecs                  []string `yaml:"codecs"`
	SimulcastLayers         int      `yaml:"simulcast_layers"`
	MaxResolution           string   `yaml:"max_resolution"`
	MaxFramerate            int      `yaml:"max_framerate"`
	KeyframeIntervalSeconds int      `yaml:"keyframe_interval_seconds"`
}

// BandwidthConfig holds bandwidth thresholds for media adaptation.
type BandwidthConfig struct {
	AudioOnlyThresholdKbps   int `yaml:"audio_only_threshold_kbps"`
	VideoResumeThresholdKbps int `yaml:"video_resume_threshold_kbps"`
	VideoResumeStableSeconds int `yaml:"video_resume_stable_seconds"`
}

// GroupConfig holds group call settings.
type GroupConfig struct {
	MaxParticipants             int `yaml:"max_participants"`
	ActiveVideoSlots            int `yaml:"active_video_slots"`
	HQSlots                     int `yaml:"hq_slots"`
	MQSlots                     int `yaml:"mq_slots"`
	SpeakerDetectionThresholdDB int `yaml:"speaker_detection_threshold_db"`
	SpeakerHoldSeconds          int `yaml:"speaker_hold_seconds"`
}

// TurnConfig holds TURN server settings.
type TurnConfig struct {
	AllocationTTLSeconds  int      `yaml:"allocation_ttl_seconds"`
	MaxAllocationsPerUser int      `yaml:"max_allocations_per_user"`
	CredentialTTLSeconds  int      `yaml:"credential_ttl_seconds"`
	Servers               []string `yaml:"servers"`
	HealthCheckIntervalS  int      `yaml:"health_check_interval_seconds"`
	HealthCheckTimeoutS   int      `yaml:"health_check_timeout_seconds"`
}

// RateLimitConfig holds rate limiting settings.
type RateLimitConfig struct {
	CallInitiatePerUser            string `yaml:"call_initiate_per_user"`
	CallInitiateGlobalCPS          int    `yaml:"call_initiate_global_cps"`
	SignalingMessagesPerConnection string `yaml:"signaling_messages_per_connection"`
	TurnAllocationsPerUser         string `yaml:"turn_allocations_per_user"`
	APIRequestsPerUser             string `yaml:"api_requests_per_user"`
}

// PostgresConfig holds PostgreSQL connection settings.
type PostgresConfig struct {
	Host     string `yaml:"host"`
	Port     int    `yaml:"port"`
	User     string `yaml:"user"`
	Password string `yaml:"password"`
	DBName   string `yaml:"dbname"`
	SSLMode  string `yaml:"sslmode"`
}

// DSN returns the PostgreSQL connection string.
func (c PostgresConfig) DSN() string {
	return fmt.Sprintf(
		"host=%s port=%d user=%s password=%s dbname=%s sslmode=%s",
		c.Host, c.Port, c.User, c.Password, c.DBName, c.SSLMode,
	)
}

// RedisConfig holds Redis connection settings.
type RedisConfig struct {
	Addr     string `yaml:"addr"`
	Password string `yaml:"password"`
	DB       int    `yaml:"db"`
}

// NATSConfig holds NATS connection settings.
type NATSConfig struct {
	URL string `yaml:"url"`
}

// ClickHouseConfig holds ClickHouse connection settings.
type ClickHouseConfig struct {
	Addr     string `yaml:"addr"`
	Database string `yaml:"database"`
	User     string `yaml:"user"`
	Password string `yaml:"password"`
}

// PolicyEngineConfig holds ABR policy engine settings.
type PolicyEngineConfig struct {
	Enabled             bool               `yaml:"enabled"`
	EvalIntervalSeconds int                `yaml:"eval_interval_seconds"`
	MetricWindowSeconds int                `yaml:"metric_window_seconds"`
	Rules               []PolicyRuleConfig `yaml:"rules"`
}

// PolicyRuleConfig defines a single evaluable ABR rule.
type PolicyRuleConfig struct {
	Name        string  `yaml:"name"`
	Condition   string  `yaml:"condition"`
	Threshold   float64 `yaml:"threshold"`
	Action      string  `yaml:"action"`
	ActionValue string  `yaml:"action_value"`
}

// Load reads configuration from the default config path, with
// environment variable overrides where applicable.
func Load() (*Config, error) {
	return LoadFromFile("configs/call-config.yaml")
}

// LoadFromFile reads configuration from a specific YAML file.
func LoadFromFile(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config file: %w", err)
	}

	cfg := &Config{}
	if err := yaml.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("parse config file: %w", err)
	}

	cfg.applyDefaults()
	cfg.applyEnvOverrides()

	return cfg, nil
}

// applyDefaults sets reasonable defaults for unset values.
func (c *Config) applyDefaults() {
	if c.Server.Port == 0 {
		c.Server.Port = 8080
	}
	if c.Server.Host == "" {
		c.Server.Host = "0.0.0.0"
	}
	if c.Postgres.Host == "" {
		c.Postgres.Host = "localhost"
	}
	if c.Postgres.Port == 0 {
		c.Postgres.Port = 5432
	}
	if c.Postgres.User == "" {
		c.Postgres.User = "lalo"
	}
	if c.Postgres.Password == "" {
		c.Postgres.Password = "lalo_dev"
	}
	if c.Postgres.DBName == "" {
		c.Postgres.DBName = "lalo"
	}
	if c.Postgres.SSLMode == "" {
		c.Postgres.SSLMode = "disable"
	}
	if c.Redis.Addr == "" {
		c.Redis.Addr = "localhost:6379"
	}
	if c.NATS.URL == "" {
		c.NATS.URL = "nats://localhost:4222"
	}
	if c.ClickHouse.Addr == "" {
		c.ClickHouse.Addr = "localhost:9000"
	}
	if c.ClickHouse.Database == "" {
		c.ClickHouse.Database = "lalo"
	}
	if c.ClickHouse.User == "" {
		c.ClickHouse.User = "default"
	}
	if c.Auth.AccessTokenExpiryMins == 0 {
		c.Auth.AccessTokenExpiryMins = 15
	}
	if c.Auth.RefreshTokenExpiryDays == 0 {
		c.Auth.RefreshTokenExpiryDays = 7
	}
	if c.LiveKit.Host == "" {
		c.LiveKit.Host = "http://localhost:7880"
	}
	if len(c.Turn.Servers) == 0 {
		c.Turn.Servers = []string{"turn:localhost:3478"}
	}
	if c.Turn.HealthCheckIntervalS == 0 {
		c.Turn.HealthCheckIntervalS = 10
	}
	if c.Turn.HealthCheckTimeoutS == 0 {
		c.Turn.HealthCheckTimeoutS = 5
	}
	if c.Push.Port == 0 {
		c.Push.Port = 8082
	}
	if c.Push.APNs.BundleID == "" {
		c.Push.APNs.BundleID = "com.lalo.app"
	}
	if c.Orchestrator.Port == 0 {
		c.Orchestrator.Port = 8081
	}
}

// applyEnvOverrides applies environment variable overrides.
func (c *Config) applyEnvOverrides() {
	if v := os.Getenv("SERVER_PORT"); v != "" {
		fmt.Sscanf(v, "%d", &c.Server.Port)
	}
	if v := os.Getenv("POSTGRES_HOST"); v != "" {
		c.Postgres.Host = v
	}
	if v := os.Getenv("POSTGRES_PORT"); v != "" {
		fmt.Sscanf(v, "%d", &c.Postgres.Port)
	}
	if v := os.Getenv("POSTGRES_USER"); v != "" {
		c.Postgres.User = v
	}
	if v := os.Getenv("POSTGRES_PASSWORD"); v != "" {
		c.Postgres.Password = v
	}
	if v := os.Getenv("POSTGRES_DB"); v != "" {
		c.Postgres.DBName = v
	}
	if v := os.Getenv("REDIS_ADDR"); v != "" {
		c.Redis.Addr = v
	}
	if v := os.Getenv("REDIS_PASSWORD"); v != "" {
		c.Redis.Password = v
	}
	if v := os.Getenv("NATS_URL"); v != "" {
		c.NATS.URL = v
	}
	if v := os.Getenv("CLICKHOUSE_ADDR"); v != "" {
		c.ClickHouse.Addr = v
	}
	if v := os.Getenv("JWT_SECRET"); v != "" {
		c.Auth.JWTSecret = v
	}
	if v := os.Getenv("TURN_SECRET"); v != "" {
		c.Auth.TurnSecret = v
	}
	if v := os.Getenv("LIVEKIT_HOST"); v != "" {
		c.LiveKit.Host = v
	}
	if v := os.Getenv("LIVEKIT_API_KEY"); v != "" {
		c.LiveKit.APIKey = v
	}
	if v := os.Getenv("LIVEKIT_API_SECRET"); v != "" {
		c.LiveKit.APISecret = v
	}
	if v := os.Getenv("PUSH_PORT"); v != "" {
		fmt.Sscanf(v, "%d", &c.Push.Port)
	}
	if v := os.Getenv("APNS_TEAM_ID"); v != "" {
		c.Push.APNs.TeamID = v
	}
	if v := os.Getenv("APNS_KEY_ID"); v != "" {
		c.Push.APNs.KeyID = v
	}
	if v := os.Getenv("APNS_KEY_PATH"); v != "" {
		c.Push.APNs.KeyPath = v
	}
	if v := os.Getenv("APNS_BUNDLE_ID"); v != "" {
		c.Push.APNs.BundleID = v
	}
	if v := os.Getenv("FCM_SERVER_KEY"); v != "" {
		c.Push.FCM.ServerKey = v
	}
	if v := os.Getenv("FCM_PROJECT_ID"); v != "" {
		c.Push.FCM.ProjectID = v
	}
	if v := os.Getenv("ORCHESTRATOR_PORT"); v != "" {
		fmt.Sscanf(v, "%d", &c.Orchestrator.Port)
	}
	if v := os.Getenv("ALLOWED_ORIGINS"); v != "" {
		origins := splitCSV(v)
		if len(origins) > 0 {
			c.Server.AllowedOrigins = origins
		}
	}
}

// splitCSV splits a comma-separated string into trimmed, non-empty values.
func splitCSV(s string) []string {
	var result []string
	for _, part := range strings.Split(s, ",") {
		v := strings.TrimSpace(part)
		if v != "" {
			result = append(result, v)
		}
	}
	return result
}
