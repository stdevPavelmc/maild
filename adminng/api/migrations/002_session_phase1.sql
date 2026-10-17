-- 002_session_phase1.sql — Phase 1 sessions are not device-bound yet.
--
-- Phase 1 issues plain bearer tokens (opaque, DB-backed) so the catalogue API
-- can be exercised end to end; Phase 2 adds the device trust model and binds
-- every session to an approved device. Until then device_id stays NULL.
-- Also index the username so logout/delete/revoke can drop a user's sessions.
ALTER TABLE session ALTER COLUMN device_id DROP NOT NULL;

CREATE INDEX IF NOT EXISTS session_username_idx ON session (username);
