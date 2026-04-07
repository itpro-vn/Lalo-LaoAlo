-- 006: Add identity fields for phone/external_id → UUID resolution
ALTER TABLE users
    ADD COLUMN phone_number TEXT,
    ADD COLUMN external_id  TEXT;

-- Unique indexes for identity lookups
CREATE UNIQUE INDEX idx_users_phone_number ON users (phone_number) WHERE phone_number IS NOT NULL;
CREATE UNIQUE INDEX idx_users_external_id  ON users (external_id)  WHERE external_id  IS NOT NULL;
