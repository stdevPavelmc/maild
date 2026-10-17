-- 001_adminng_core.sql — AdminNG's own state (the MailD-owned `adminng` database).
--
-- The PostfixAdmin catalogue (mailddb) is NEVER touched here: AdminNG reads and
-- writes domain/mailbox/alias/admin rows exactly like PostfixAdmin does, but all
-- of its *own* state (device trust, sessions, TOTP credentials, audit trail)
-- lives in this database, which the db container creates on every boot from
-- ADMINNG_DB (db/ensure_databases.sh).
--
-- Applied by the api container's entrypoint (python -m app.bootstrap) on every
-- boot; every statement is idempotent so re-runs are no-ops. The migration
-- runner also maintains schema_version, which is what it uses to know which
-- files have already run — the table is created here as well for clarity.
CREATE TABLE IF NOT EXISTS schema_version (
  version    int PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);

-- Device trust: every client (browser/PWA/APK) carries an X-Device-ID; nothing
-- operational works until a device is APPROVED (CLI or the superadmin panel).
CREATE TABLE IF NOT EXISTS device (
  device_id       uuid PRIMARY KEY,
  client_type     text NOT NULL DEFAULT 'web',   -- 'web' | 'android_pwa' | ...
  device_name     text,
  associated_user text,                          -- last verified username
  state           text NOT NULL DEFAULT 'PENDING'
                  CHECK (state IN ('PENDING','APPROVED','REVOKED')),
  first_seen      timestamptz NOT NULL DEFAULT now(),
  last_seen       timestamptz NOT NULL DEFAULT now(),
  approved_at     timestamptz,
  approved_by     text                           -- username | 'cli' | 'auto-first'
);

-- Refresh-token registry. Access tokens are short-lived JWTs and are not stored;
-- the opaque refresh jti is, so logout/revoke/idle-purge can destroy sessions.
CREATE TABLE IF NOT EXISTS session (
  jti          text PRIMARY KEY,          -- refresh-token id (rotated on refresh)
  username     text NOT NULL,
  device_id    uuid NOT NULL REFERENCES device(device_id) ON DELETE CASCADE,
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz NOT NULL DEFAULT now(),
  revoked_at   timestamptz
);

-- TOTP enrollment (RFC 6238). Secrets are encrypted at rest with ADMINNG_SECRET_KEY
-- (operator file, mandatory from Phase 2 on).
CREATE TABLE IF NOT EXISTS totp_credential (
  username    text PRIMARY KEY,
  secret      text NOT NULL,
  confirmed   boolean NOT NULL DEFAULT false,
  enrolled_at timestamptz NOT NULL DEFAULT now()
);

-- Functional audit trail read by the Logs UI (who did what, on which entity,
-- from which device/IP, with which result).
CREATE TABLE IF NOT EXISTS audit_event (
  id          bigserial PRIMARY KEY,
  ts          timestamptz NOT NULL DEFAULT now(),
  actor       text NOT NULL,             -- username | 'cli' | 'system'
  device_id   uuid,
  action      text NOT NULL,             -- LOGIN_OK, LOGIN_FAIL, TOTP_FAIL,
                                         -- LOCKOUT, DEVICE_APPROVE, ...
  entity_type text,                      -- 'mailbox'|'domain'|'alias'|'admin'|'device'
  entity_id   text,
  domain      text,                      -- tenant tag (NULL = global)
  ip          text,
  endpoint    text,
  result      text NOT NULL,             -- 'ok' | 'denied' | 'error'
  details     jsonb
);

CREATE INDEX IF NOT EXISTS audit_event_ts_idx     ON audit_event (ts DESC);
CREATE INDEX IF NOT EXISTS audit_event_actor_idx  ON audit_event (actor);
CREATE INDEX IF NOT EXISTS audit_event_domain_idx ON audit_event (domain);
CREATE INDEX IF NOT EXISTS session_device_idx     ON session (device_id);
