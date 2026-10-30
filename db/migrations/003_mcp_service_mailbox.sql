-- 003_mcp_service_mailbox.sql — MailD MCP service mailbox helper (mcp/technical-proposal.md §9.2, D8/D9).
--
-- The mcp container connects to the catalogue as the restricted MCP_DB_USER role
-- (db/ensure_roles.sh): column-level SELECT only, no INSERT/UPDATE anywhere. The one write it
-- needs is creating its own service mailbox (MCP_SERVICE_EMAIL) on first boot, so that write
-- goes through this SECURITY DEFINER function, owned by POSTGRES_USER, and nothing else.
--
-- The function only ever INSERTs a missing mailbox row. It never updates an existing one (an
-- operator-changed password survives restarts), refuses an unknown or inactive domain, refuses
-- an address already used by an alias, and only accepts an Argon2id hash in the format Dovecot
-- verifies ('{ARGON2ID}$argon2id$…'), so a compromised mcp cannot plant a weak or plaintext
-- credential. Domain counters are recounted like adminng/api catalogue.recount_domain().
--
-- Returns true when the row was created, false when it already existed.
-- Idempotent (CREATE OR REPLACE), so db/migrate.sh can run it on every boot. EXECUTE is revoked
-- from PUBLIC here and granted to the MCP role by db/ensure_roles.sh.
CREATE OR REPLACE FUNCTION public.maild_mcp_ensure_service_mailbox(p_address text, p_hash text, p_name text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_address    text := lower(btrim(p_address));
  v_local_part text;
  v_domain     text;
BEGIN
  IF v_address IS NULL OR v_address !~ '^[a-z0-9._+-]+@[a-z0-9.-]+\.[a-z0-9-]+$' THEN
    RAISE EXCEPTION 'maild_mcp_ensure_service_mailbox: invalid address %', p_address;
  END IF;
  IF p_hash IS NULL OR p_hash NOT LIKE '{ARGON2ID}$argon2id$%' THEN
    RAISE EXCEPTION 'maild_mcp_ensure_service_mailbox: an {ARGON2ID} hash is required';
  END IF;

  v_local_part := split_part(v_address, '@', 1);
  v_domain     := split_part(v_address, '@', 2);

  -- one caller at a time per address (two mcp workers booting together)
  PERFORM pg_advisory_xact_lock(hashtext('maild_mcp_ensure_service_mailbox:' || v_address));

  IF EXISTS (SELECT 1 FROM mailbox WHERE username = v_address) THEN
    RETURN false;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM domain WHERE domain = v_domain AND active) THEN
    RAISE EXCEPTION 'maild_mcp_ensure_service_mailbox: domain % is not an active catalogue domain', v_domain;
  END IF;
  IF EXISTS (SELECT 1 FROM alias WHERE address = v_address) THEN
    RAISE EXCEPTION 'maild_mcp_ensure_service_mailbox: % is already an alias', v_address;
  END IF;

  -- PostfixAdmin's maildir layout '<domain>/<local_part>/', quota 0 (domain default), like the
  -- api seeder's superadmin mailbox
  INSERT INTO mailbox (username, password, name, maildir, quota, domain, local_part, active)
  VALUES (v_address, p_hash, coalesce(p_name, ''), v_domain || '/' || v_local_part || '/', 0,
          v_domain, v_local_part, true);

  UPDATE domain
     SET mailboxes = (SELECT count(*) FROM mailbox WHERE domain = v_domain),
         aliases   = (SELECT count(*) FROM alias   WHERE domain = v_domain),
         modified  = now()
   WHERE domain = v_domain;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.maild_mcp_ensure_service_mailbox(text, text, text) FROM PUBLIC;

COMMENT ON FUNCTION public.maild_mcp_ensure_service_mailbox(text, text, text) IS
  'MailD MCP: create the service mailbox (MCP_SERVICE_EMAIL) if missing; never modifies an '
  'existing row. EXECUTE granted to the MCP role only (db/ensure_roles.sh).';
