-- 006: Remove identity fields
DROP INDEX IF EXISTS idx_users_external_id;
DROP INDEX IF EXISTS idx_users_phone_number;

ALTER TABLE users
    DROP COLUMN IF EXISTS external_id,
    DROP COLUMN IF EXISTS phone_number;
