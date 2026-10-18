-- 005_session_remember.sql — "remember this device" (24h) sessions.
--
-- Opted in at login (login-step1 "remember": true). A remembered session keeps
-- minting long-lived access tokens and tolerates a long idle window until it is
-- revoked (logout, device revocation, admin action) or expires; ordinary
-- sessions keep the short ADMINNG_ACCESS_TTL / ADMINNG_REFRESH_IDLE_TTL.
-- The device-bound model is unchanged: destructive actions still require the
-- 30-second re-auth token regardless of remember.
ALTER TABLE session ADD COLUMN IF NOT EXISTS remember boolean NOT NULL DEFAULT false;
