-- 003_create_call_history.up.sql
CREATE TABLE IF NOT EXISTS call_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    call_id UUID NOT NULL UNIQUE,
    call_type TEXT NOT NULL CHECK (call_type IN ('1:1', 'group')),
    initiator_id UUID NOT NULL REFERENCES users(id),
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    duration_seconds INT,
    topology TEXT CHECK (topology IN ('p2p', 'turn', 'sfu')),
    end_reason TEXT,
    region TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_call_history_initiator ON call_history (initiator_id);
CREATE INDEX idx_call_history_started_at ON call_history (started_at);
CREATE INDEX idx_call_history_call_type ON call_history (call_type);
