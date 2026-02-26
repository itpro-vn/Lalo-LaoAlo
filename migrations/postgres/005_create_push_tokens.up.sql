-- 005_create_push_tokens.up.sql
CREATE TABLE IF NOT EXISTS push_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id),
    device_id TEXT NOT NULL,
    platform TEXT NOT NULL CHECK (platform IN ('ios', 'android')),
    push_token TEXT NOT NULL,
    voip_token TEXT,                -- iOS PushKit VoIP token (iOS only)
    app_version TEXT,
    bundle_id TEXT,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(user_id, device_id)
);

CREATE INDEX idx_push_tokens_user ON push_tokens (user_id) WHERE is_active = true;
