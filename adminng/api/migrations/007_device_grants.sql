-- 007_device_grants.sql — per-(browser, administrator) device approval.
--
-- 2026-10 audit F-11: the old device gate approved a *device id* alone. The id is
-- shown on the lock screen by design, so a leaked id could be polled and then
-- reused from another host (only TOTP remained). Two changes fix it:
--   * `device.secret_hash` binds a client-minted per-browser secret (the id is
--     useless without it), and
--   * approval moves from the device to a `device_grant` row keyed by
--     (device_id, username), so a shared browser needs one grant per admin.
--
-- Registration is no longer an anonymous handshake: a device/grant is only
-- created inside a login-step1 whose password verifies.

ALTER TABLE device ADD COLUMN IF NOT EXISTS secret_hash text;

CREATE TABLE IF NOT EXISTS device_grant (
  device_id   uuid NOT NULL REFERENCES device(device_id) ON DELETE CASCADE,
  username    text NOT NULL,
  state       text NOT NULL DEFAULT 'PENDING'
              CHECK (state IN ('PENDING','APPROVED','REVOKED')),
  first_seen  timestamptz NOT NULL DEFAULT now(),
  last_seen   timestamptz NOT NULL DEFAULT now(),
  approved_at timestamptz,
  approved_by text,
  last_ip     text,
  PRIMARY KEY (device_id, username)
);
CREATE INDEX IF NOT EXISTS device_grant_state_idx ON device_grant (state, first_seen DESC);
CREATE INDEX IF NOT EXISTS device_grant_user_idx  ON device_grant (username);

-- Backfill one grant per device that already had a verified user. Rows without a
-- user (anonymous handshake spam) are dropped below by the column removal.
INSERT INTO device_grant (device_id, username, state, first_seen, last_seen,
                          approved_at, approved_by, last_ip)
SELECT device_id, associated_user, state, first_seen, last_seen,
       approved_at, approved_by, last_ip
  FROM device
 WHERE associated_user IS NOT NULL
ON CONFLICT (device_id, username) DO NOTHING;

-- Hard cutover: Phase-2 sessions predate the secret and the per-user grant, so
-- every admin re-logs-in once (which binds the secret and creates their grant).
UPDATE session SET revoked_at = now() WHERE revoked_at IS NULL;

-- The device row is now the browser identity; user/approval live in device_grant.
ALTER TABLE device DROP COLUMN IF EXISTS state;          -- drops device_state_idx too
ALTER TABLE device DROP COLUMN IF EXISTS associated_user;
ALTER TABLE device DROP COLUMN IF EXISTS approved_at;
ALTER TABLE device DROP COLUMN IF EXISTS approved_by;
