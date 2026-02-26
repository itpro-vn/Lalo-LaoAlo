-- 004_create_call_participants.up.sql
CREATE TABLE IF NOT EXISTS call_participants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    call_id UUID NOT NULL REFERENCES call_history(call_id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id),
    role TEXT NOT NULL CHECK (role IN ('caller', 'callee', 'participant')),
    joined_at TIMESTAMPTZ,
    left_at TIMESTAMPTZ,
    end_reason TEXT
);

CREATE INDEX idx_call_participants_call_id ON call_participants (call_id);
CREATE INDEX idx_call_participants_user_id ON call_participants (user_id);
CREATE UNIQUE INDEX idx_call_participants_call_user ON call_participants (call_id, user_id);
