-- 008_device_trust.sql — device-scoped approval + a 24h "skip the code" window.
--
-- Two operator-requested simplifications of the Phase-2 model:
--
--   * Approval moves from the (device, admin) `device_grant` row to the `device`
--     row itself (`state`). One approval authorizes the *browser*; afterwards any
--     admin whose password verifies may sign in from it. `device_grant` is kept
--     as a per-admin activity log (last seen / last IP) and as the home of the
--     per-(device, admin) trust window below.
--
--   * `device_grant.trusted_until` remembers a successful login that ticked
--     "remember this device for 24 hours": while it is in the future the TOTP
--     code is not requested again for that (device, admin). It is a fixed window
--     armed by a TOTP (or biometric) success and is not extended by password-only
--     logins.

ALTER TABLE device ADD COLUMN IF NOT EXISTS state text NOT NULL DEFAULT 'PENDING'
  CHECK (state IN ('PENDING','APPROVED','REVOKED'));
ALTER TABLE device ADD COLUMN IF NOT EXISTS approved_at timestamptz;
ALTER TABLE device ADD COLUMN IF NOT EXISTS approved_by text;

-- Backfill the browser state from the grants it already had: APPROVED as soon
-- as one admin was approved, REVOKED only when every grant was revoked.
UPDATE device d
   SET state = CASE
         WHEN EXISTS (SELECT 1 FROM device_grant g
                       WHERE g.device_id = d.device_id AND g.state = 'APPROVED')
              THEN 'APPROVED'
         WHEN EXISTS (SELECT 1 FROM device_grant g
                       WHERE g.device_id = d.device_id AND g.state <> 'REVOKED')
              THEN 'PENDING'
         WHEN EXISTS (SELECT 1 FROM device_grant g WHERE g.device_id = d.device_id)
              THEN 'REVOKED'
         ELSE 'PENDING'
       END
 WHERE d.state = 'PENDING';

CREATE INDEX IF NOT EXISTS device_state_idx ON device (state, first_seen DESC);

-- The per-(device, admin) rollover: bumped on every successful login with
-- "remember" ticked. NULL means "ask for the code on the next login".
ALTER TABLE device_grant ADD COLUMN IF NOT EXISTS trusted_until timestamptz;
