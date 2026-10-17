-- 003_phase2.sql — device trust, TOTP replay protection, retry metadata.
--
-- Phase 2 binds sessions to approved devices and adds TOTP. Existing Phase-1
-- sessions (device_id NULL) are retired: they were plain bearer tokens minted
-- before the device gate existed.

ALTER TABLE device ADD COLUMN IF NOT EXISTS last_ip text;

-- Replay protection: a TOTP step can only be used once per credential.
ALTER TABLE totp_credential ADD COLUMN IF NOT EXISTS last_used_step bigint;

-- Phase-1 rows are not device-bound; revoke them so only Phase-2 sessions live.
UPDATE session SET revoked_at = now() WHERE device_id IS NULL AND revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS device_state_idx ON device (state, first_seen DESC);
CREATE INDEX IF NOT EXISTS audit_event_entity_idx ON audit_event (entity_type, entity_id);
