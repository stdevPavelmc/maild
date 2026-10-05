-- 001_maild_provision.sql — MailD first-boot provisioning sentinel.
--
-- This is the ONLY schema change MailD adds on top of PostfixAdmin. No PostfixAdmin core
-- table is altered; the catalogue itself (domain / mailbox / alias / admin rows) is *data*
-- seeded by admin/seed.sh — exactly what the manual /setup.php wizard + "create domain"
-- clicks do by hand.
--
-- The row is written by admin/seed.sh once the default domain, the superadmin, its mailbox
-- and the default aliases exist. Services that cache the domain list at boot (amavis for the
-- DKIM keys, mua for the SnappyMail per-domain config, mta for the virtual aliases) wait for
-- this row before they run their config stage, so a fresh deployment becomes usable with no
-- manual setup, no down/up cycle and no per-service restart.
--
-- Idempotent (CREATE TABLE IF NOT EXISTS), so db/migrate.sh can run it on every boot.
CREATE TABLE IF NOT EXISTS maild_provision (
  id             int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  version        int  NOT NULL,
  default_domain text NOT NULL,
  admin_user     text NOT NULL,
  provisioned_at timestamptz NOT NULL DEFAULT now(),
  provisioned_by text
);

COMMENT ON TABLE maild_provision IS
  'MailD first-boot provisioning sentinel: written by admin/seed.sh, read by the boot-time '
  'domain-caching services (amavis/mua/mta) before they configure themselves.';
