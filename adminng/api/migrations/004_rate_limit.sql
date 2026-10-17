-- 004_rate_limit.sql — persistent login rate limiting.
--
-- The counter lives in the database (not in the API process memory) so:
--   * it survives api restarts,
--   * it is shared by every api replica,
--   * the operator can clear it from another process with
--     `adminng.py --reset-ratelimit <username>` (a testing/ops aid).
-- Keyed by username + IP: one noisy source cannot lock an admin out from a
-- different network.

CREATE TABLE IF NOT EXISTS rate_limit (
  username     text        NOT NULL,
  ip           text        NOT NULL DEFAULT '-',
  failures     int         NOT NULL DEFAULT 0,
  locked_until timestamptz,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (username, ip)
);

CREATE INDEX IF NOT EXISTS rate_limit_locked_idx  ON rate_limit (locked_until);
CREATE INDEX IF NOT EXISTS rate_limit_updated_idx ON rate_limit (updated_at);
