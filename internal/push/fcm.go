package push

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// FCMConfig holds Firebase Cloud Messaging settings.
type FCMConfig struct {
	ServerKey string // FCM server key (legacy API) or use OAuth2 for v1
	ProjectID string // Firebase project ID (for v1 API)
}

// fcmMessage is the FCM legacy HTTP API message format.
type fcmMessage struct {
	To       string            `json:"to"`
	Priority string            `json:"priority"`
	TTL      string            `json:"time_to_live,omitempty"`
	Data     map[string]string `json:"data"`
}

// fcmResponse is the FCM API response.
type fcmResponse struct {
	Success int         `json:"success"`
	Failure int         `json:"failure"`
	Results []fcmResult `json:"results"`
}

type fcmResult struct {
	MessageID string `json:"message_id,omitempty"`
	Error     string `json:"error,omitempty"`
}

const fcmEndpoint = "https://fcm.googleapis.com/fcm/send"

// FCMSender sends data messages via FCM HTTP API.
type FCMSender struct {
	cfg        FCMConfig
	httpClient *http.Client
}

// NewFCMSender creates a new FCM data message sender.
func NewFCMSender(cfg FCMConfig) *FCMSender {
	return &FCMSender{
		cfg:        cfg,
		httpClient: &http.Client{Timeout: 10 * time.Second},
	}
}

// Send delivers a data-only push notification to an Android device via FCM.
// Uses data messages only (NOT notification messages) to ensure
// onMessageReceived() is called when app is background/killed.
func (s *FCMSender) Send(ctx context.Context, fcmToken string, payload *IncomingCallPush) error {
	msg := fcmMessage{
		To:       fcmToken,
		Priority: "high",
		TTL:      fmt.Sprintf("%d", payload.TTL),
		Data: map[string]string{
			"type":        "incoming_call",
			"call_id":     payload.CallID,
			"caller_id":   payload.CallerID,
			"caller_name": payload.CallerName,
			"call_type":   payload.CallType,
			"timestamp":   fmt.Sprintf("%d", payload.Timestamp),
			"ttl":         fmt.Sprintf("%d", payload.TTL),
		},
	}

	if payload.CallerAvatarURL != "" {
		msg.Data["caller_avatar_url"] = payload.CallerAvatarURL
	}

	body, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("marshal FCM message: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, fcmEndpoint, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("create FCM request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "key="+s.cfg.ServerKey)

	resp, err := s.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("send FCM request: %w", err)
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("FCM error (status %d): %s", resp.StatusCode, string(respBody))
	}

	var fcmResp fcmResponse
	if err := json.Unmarshal(respBody, &fcmResp); err != nil {
		return fmt.Errorf("parse FCM response: %w", err)
	}

	if fcmResp.Failure > 0 && len(fcmResp.Results) > 0 {
		errMsg := fcmResp.Results[0].Error
		if errMsg == "NotRegistered" || errMsg == "InvalidRegistration" {
			return fmt.Errorf("FCM token invalid (%s)", errMsg)
		}
		return fmt.Errorf("FCM delivery failed: %s", errMsg)
	}

	return nil
}

// Platform returns PlatformAndroid.
func (s *FCMSender) Platform() Platform {
	return PlatformAndroid
}

// IsUnregisteredError returns true if the error indicates the FCM token is invalid.
func IsUnregisteredError(err error) bool {
	if err == nil {
		return false
	}
	errStr := err.Error()
	return contains(errStr, "NotRegistered") || contains(errStr, "InvalidRegistration")
}
