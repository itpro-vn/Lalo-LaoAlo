-- 002_create_call_configs.up.sql
CREATE TABLE IF NOT EXISTS call_configs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    scope TEXT NOT NULL CHECK (scope IN ('global', 'user')),
    scope_id UUID,                -- NULL for global, user_id for user scope
    config JSONB NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_call_configs_scope ON call_configs (scope, scope_id);
CREATE INDEX idx_call_configs_scope_id ON call_configs (scope_id) WHERE scope_id IS NOT NULL;
