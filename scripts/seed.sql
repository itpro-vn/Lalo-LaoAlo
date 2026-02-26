-- Seed data for local development
-- Run: psql -U lalo -d lalo -f scripts/seed.sql

-- Insert test users
INSERT INTO users (id, display_name, avatar_url) VALUES
    ('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'Alice Nguyen', 'https://example.com/avatars/alice.png'),
    ('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380a22', 'Bob Tran', 'https://example.com/avatars/bob.png'),
    ('c0eebc99-9c0b-4ef8-bb6d-6bb9bd380a33', 'Charlie Le', NULL),
    ('d0eebc99-9c0b-4ef8-bb6d-6bb9bd380a44', 'Diana Pham', 'https://example.com/avatars/diana.png')
ON CONFLICT (id) DO NOTHING;

-- Insert global call config
INSERT INTO call_configs (scope, scope_id, config) VALUES
    ('global', NULL, '{
        "ring_timeout_seconds": 45,
        "ice_timeout_seconds": 15,
        "max_reconnect_attempts": 3,
        "max_participants": 8
    }')
ON CONFLICT DO NOTHING;

-- Insert sample call history
INSERT INTO call_history (call_id, call_type, initiator_id, started_at, ended_at, duration_seconds, topology, end_reason, region) VALUES
    ('11111111-1111-1111-1111-111111111111', '1:1', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
     now() - INTERVAL '2 hours', now() - INTERVAL '1 hour 45 minutes', 900, 'p2p', 'normal_hangup', 'ap-southeast-1'),
    ('22222222-2222-2222-2222-222222222222', 'group', 'b0eebc99-9c0b-4ef8-bb6d-6bb9bd380a22',
     now() - INTERVAL '1 hour', now() - INTERVAL '30 minutes', 1800, 'sfu', 'normal_hangup', 'ap-southeast-1')
ON CONFLICT (call_id) DO NOTHING;

-- Insert sample call participants
INSERT INTO call_participants (call_id, user_id, role, joined_at, left_at) VALUES
    ('11111111-1111-1111-1111-111111111111', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'caller',
     now() - INTERVAL '2 hours', now() - INTERVAL '1 hour 45 minutes'),
    ('11111111-1111-1111-1111-111111111111', 'b0eebc99-9c0b-4ef8-bb6d-6bb9bd380a22', 'callee',
     now() - INTERVAL '1 hour 59 minutes', now() - INTERVAL '1 hour 45 minutes'),
    ('22222222-2222-2222-2222-222222222222', 'b0eebc99-9c0b-4ef8-bb6d-6bb9bd380a22', 'caller',
     now() - INTERVAL '1 hour', now() - INTERVAL '30 minutes'),
    ('22222222-2222-2222-2222-222222222222', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380a33', 'participant',
     now() - INTERVAL '55 minutes', now() - INTERVAL '30 minutes'),
    ('22222222-2222-2222-2222-222222222222', 'd0eebc99-9c0b-4ef8-bb6d-6bb9bd380a44', 'participant',
     now() - INTERVAL '50 minutes', now() - INTERVAL '35 minutes')
ON CONFLICT DO NOTHING;

-- Insert sample push tokens
INSERT INTO push_tokens (user_id, device_id, platform, push_token, voip_token, app_version, bundle_id) VALUES
    ('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'iphone-14-alice', 'ios',
     'apns-token-alice-001', 'voip-token-alice-001', '1.0.0', 'com.lalo.app'),
    ('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380a22', 'pixel-8-bob', 'android',
     'fcm-token-bob-001', NULL, '1.0.0', 'com.lalo.app')
ON CONFLICT (user_id, device_id) DO NOTHING;
