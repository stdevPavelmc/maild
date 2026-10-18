-- 006_webauthn.sql — device-scoped WebAuthn credentials and short-lived ceremonies.

CREATE TABLE IF NOT EXISTS webauthn_credential (
  credential_id   text PRIMARY KEY,
  username        text NOT NULL,
  device_id       uuid NOT NULL REFERENCES device(device_id) ON DELETE CASCADE,
  public_key      bytea NOT NULL,
  sign_count      bigint NOT NULL DEFAULT 0,
  transports      text[] NOT NULL DEFAULT ARRAY[]::text[],
  created_at      timestamptz NOT NULL DEFAULT now(),
  last_used_at    timestamptz,
  UNIQUE (username, device_id)
);

CREATE TABLE IF NOT EXISTS webauthn_challenge (
  challenge_id uuid PRIMARY KEY,
  challenge    text NOT NULL,
  username     text NOT NULL,
  device_id    uuid NOT NULL REFERENCES device(device_id) ON DELETE CASCADE,
  purpose      text NOT NULL CHECK (purpose IN ('register', 'login', 'reauth')),
  expected_origin text NOT NULL,
  rp_id        text NOT NULL,
  remember     boolean NOT NULL DEFAULT false,
  expires_at   timestamptz NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS webauthn_challenge_expiry_idx
  ON webauthn_challenge (expires_at);
