-- 002_postfixadmin_catalogue.sql — the PostfixAdmin catalogue schema, owned by MailD.
--
-- WHY THIS FILE EXISTS
--   The catalogue schema used to be created by PostfixAdmin's `public/upgrade.php`
--   inside the `admin` container. That service is deprecated and no longer part of
--   the stack (see .agents/services/provisioning.md), so the DDL moved here: `db` is
--   the only place where schema is created, exactly like 001_maild_provision.sql.
--   MailD still adds NO table of its own beyond the sentinel: this file is a verbatim
--   snapshot of what PostfixAdmin creates, nothing more.
--
-- PROVENANCE
--   `pg_dump --schema-only --no-owner --no-privileges` (PostgreSQL 18) against a
--   catalogue initialised by PostfixAdmin **3.3.13** — the version MailD pinned in
--   admin/Dockerfile (POSTFIXADMIN_VERSION / POSTFIXADMIN_SHA512) — then rewritten to
--   be idempotent. It is a SNAPSHOT: a future PostfixAdmin release needs its own
--   migration with guarded ALTERs; never edit this file to follow upstream.
--
-- LICENCE
--   The table layout is PostfixAdmin's: GPL-2.0-or-later, Copyright (c) 2005 High5!
--   (Mischa Peters and others). MailD is GPL-3.0-or-later, which GPL-2.0-or-later
--   permits.
--
-- IDEMPOTENCY
--   db/migrate.sh re-applies every file on EVERY boot (there is no version tracking),
--   so every statement must be a no-op on an existing schema: CREATE … IF NOT EXISTS,
--   CREATE OR REPLACE (functions/triggers), ADD CONSTRAINT guarded on duplicate_object,
--   and the `config` row through ON CONFLICT. No row is ever modified or deleted.
--
-- CONTRACT (do not break)
--   Postfix (virtual_*_maps.cf), Dovecot (userdb/passdb SQL), Amavis, the MUA config
--   builder and the AdminNG API all read these tables/columns by name. Types, defaults
--   and nullability are PostfixAdmin's, so a row written by AdminNG is indistinguishable
--   from one written by PostfixAdmin.

SET client_min_messages = warning;

-- ---------------------------------------------------------------- tables -----
-- (created before the constraints/FKs below, so the order is not significant)

CREATE TABLE IF NOT EXISTS public.admin (
    username character varying(255) NOT NULL,
    password character varying(255) DEFAULT ''::character varying NOT NULL,
    created timestamp with time zone DEFAULT now(),
    modified timestamp with time zone DEFAULT now(),
    active boolean DEFAULT true NOT NULL,
    superadmin boolean DEFAULT false NOT NULL,
    phone character varying(30) DEFAULT ''::character varying NOT NULL,
    email_other character varying(255) DEFAULT ''::character varying NOT NULL,
    token character varying(255) DEFAULT ''::character varying NOT NULL,
    token_validity timestamp with time zone DEFAULT '2000-01-01 00:00:00+00'::timestamp with time zone
);
COMMENT ON TABLE public.admin IS 'Postfix Admin - Virtual Admins';

CREATE TABLE IF NOT EXISTS public.alias (
    address character varying(255) NOT NULL,
    goto text NOT NULL,
    domain character varying(255) NOT NULL,
    created timestamp with time zone DEFAULT now(),
    modified timestamp with time zone DEFAULT now(),
    active boolean DEFAULT true NOT NULL
);
COMMENT ON TABLE public.alias IS 'Postfix Admin - Virtual Aliases';

CREATE TABLE IF NOT EXISTS public.alias_domain (
    alias_domain character varying(255) NOT NULL,
    target_domain character varying(255) NOT NULL,
    created timestamp with time zone DEFAULT now(),
    modified timestamp with time zone DEFAULT now(),
    active boolean DEFAULT true NOT NULL
);
COMMENT ON TABLE public.alias_domain IS 'Postfix Admin - Domain Aliases';

CREATE TABLE IF NOT EXISTS public.config (
    id integer NOT NULL,
    name character varying(20) NOT NULL,
    value character varying(20) NOT NULL
);

CREATE SEQUENCE IF NOT EXISTS public.config_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE public.config_id_seq OWNED BY public.config.id;
ALTER TABLE ONLY public.config ALTER COLUMN id SET DEFAULT nextval('public.config_id_seq'::regclass);

CREATE TABLE IF NOT EXISTS public.domain (
    domain character varying(255) NOT NULL,
    description character varying(255) DEFAULT ''::character varying NOT NULL,
    aliases integer DEFAULT 0 NOT NULL,
    mailboxes integer DEFAULT 0 NOT NULL,
    maxquota bigint DEFAULT 0 NOT NULL,
    quota bigint DEFAULT 0 NOT NULL,
    transport character varying(255) DEFAULT NULL::character varying,
    backupmx boolean DEFAULT false NOT NULL,
    created timestamp with time zone DEFAULT now(),
    modified timestamp with time zone DEFAULT now(),
    active boolean DEFAULT true NOT NULL,
    password_expiry integer DEFAULT 0
);
COMMENT ON TABLE public.domain IS 'Postfix Admin - Virtual Domains';

CREATE TABLE IF NOT EXISTS public.domain_admins (
    username character varying(255) NOT NULL,
    domain character varying(255) NOT NULL,
    created timestamp with time zone DEFAULT now(),
    active boolean DEFAULT true NOT NULL,
    id integer NOT NULL
);
COMMENT ON TABLE public.domain_admins IS 'Postfix Admin - Domain Admins';

CREATE SEQUENCE IF NOT EXISTS public.domain_admins_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE public.domain_admins_id_seq OWNED BY public.domain_admins.id;
ALTER TABLE ONLY public.domain_admins ALTER COLUMN id SET DEFAULT nextval('public.domain_admins_id_seq'::regclass);

CREATE TABLE IF NOT EXISTS public.fetchmail (
    id integer NOT NULL,
    mailbox character varying(255) DEFAULT ''::character varying NOT NULL,
    src_server character varying(255) DEFAULT ''::character varying NOT NULL,
    src_auth character varying(15) NOT NULL,
    src_user character varying(255) DEFAULT ''::character varying NOT NULL,
    src_password character varying(255) DEFAULT ''::character varying NOT NULL,
    src_folder character varying(255) DEFAULT ''::character varying NOT NULL,
    poll_time integer DEFAULT 10 NOT NULL,
    fetchall boolean DEFAULT false NOT NULL,
    keep boolean DEFAULT false NOT NULL,
    protocol character varying(15) NOT NULL,
    extra_options text,
    returned_text text,
    mda character varying(255) DEFAULT ''::character varying NOT NULL,
    date timestamp with time zone DEFAULT now(),
    usessl boolean DEFAULT false CONSTRAINT fetchmail_ssl_not_null NOT NULL,
    sslcertck boolean DEFAULT false NOT NULL,
    sslcertpath character varying(255) DEFAULT ''::character varying,
    sslfingerprint character varying(255) DEFAULT ''::character varying,
    domain character varying(255) DEFAULT ''::character varying,
    active boolean DEFAULT false NOT NULL,
    created timestamp with time zone DEFAULT '2000-01-01 00:00:00+00'::timestamp with time zone,
    modified timestamp with time zone DEFAULT now(),
    src_port integer DEFAULT 0 NOT NULL,
    CONSTRAINT fetchmail_protocol_check CHECK (((protocol)::text = ANY ((ARRAY['POP3'::character varying, 'IMAP'::character varying, 'POP2'::character varying, 'ETRN'::character varying, 'AUTO'::character varying])::text[]))),
    CONSTRAINT fetchmail_src_auth_check CHECK (((src_auth)::text = ANY ((ARRAY['password'::character varying, 'kerberos_v5'::character varying, 'kerberos'::character varying, 'kerberos_v4'::character varying, 'gssapi'::character varying, 'cram-md5'::character varying, 'otp'::character varying, 'ntlm'::character varying, 'msn'::character varying, 'ssh'::character varying, 'any'::character varying])::text[])))
);

CREATE SEQUENCE IF NOT EXISTS public.fetchmail_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE public.fetchmail_id_seq OWNED BY public.fetchmail.id;
ALTER TABLE ONLY public.fetchmail ALTER COLUMN id SET DEFAULT nextval('public.fetchmail_id_seq'::regclass);

CREATE TABLE IF NOT EXISTS public.log (
    "timestamp" timestamp with time zone DEFAULT now(),
    username character varying(255) DEFAULT ''::character varying NOT NULL,
    domain character varying(255) DEFAULT ''::character varying NOT NULL,
    action character varying(255) DEFAULT ''::character varying NOT NULL,
    data text DEFAULT ''::text CONSTRAINT log_data_not_null1 NOT NULL,
    id integer NOT NULL
);
COMMENT ON TABLE public.log IS 'Postfix Admin - Log';

CREATE SEQUENCE IF NOT EXISTS public.log_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE public.log_id_seq OWNED BY public.log.id;
ALTER TABLE ONLY public.log ALTER COLUMN id SET DEFAULT nextval('public.log_id_seq'::regclass);

CREATE TABLE IF NOT EXISTS public.mailbox (
    username character varying(255) NOT NULL,
    password character varying(255) DEFAULT ''::character varying NOT NULL,
    name character varying(255) DEFAULT ''::character varying NOT NULL,
    maildir character varying(255) DEFAULT ''::character varying NOT NULL,
    quota bigint DEFAULT 0 NOT NULL,
    created timestamp with time zone DEFAULT now(),
    modified timestamp with time zone DEFAULT now(),
    active boolean DEFAULT true NOT NULL,
    domain character varying(255),
    local_part character varying(255) NOT NULL,
    phone character varying(30) DEFAULT ''::character varying NOT NULL,
    email_other character varying(255) DEFAULT ''::character varying NOT NULL,
    token character varying(255) DEFAULT ''::character varying NOT NULL,
    token_validity timestamp with time zone DEFAULT '2000-01-01 00:00:00+00'::timestamp with time zone,
    password_expiry timestamp with time zone DEFAULT '2000-01-01 00:00:00+00'::timestamp with time zone
);
COMMENT ON TABLE public.mailbox IS 'Postfix Admin - Virtual Mailboxes';

CREATE TABLE IF NOT EXISTS public.quota (
    username character varying(255) NOT NULL,
    path character varying(100) NOT NULL,
    current bigint DEFAULT 0 NOT NULL
);

CREATE TABLE IF NOT EXISTS public.quota2 (
    username character varying(100) NOT NULL,
    bytes bigint DEFAULT 0 NOT NULL,
    messages integer DEFAULT 0 NOT NULL
);

CREATE TABLE IF NOT EXISTS public.vacation (
    email character varying(255) NOT NULL,
    subject character varying(255) NOT NULL,
    body text DEFAULT ''::text NOT NULL,
    created timestamp with time zone DEFAULT now(),
    active boolean DEFAULT true NOT NULL,
    domain character varying(255),
    modified timestamp with time zone DEFAULT now(),
    activefrom timestamp with time zone DEFAULT '2000-01-01 00:00:00+00'::timestamp with time zone,
    activeuntil timestamp with time zone DEFAULT '2038-01-18 00:00:00+00'::timestamp with time zone,
    interval_time integer DEFAULT 0 NOT NULL
);

CREATE TABLE IF NOT EXISTS public.vacation_notification (
    on_vacation character varying(255) NOT NULL,
    notified character varying(255) NOT NULL,
    notified_at timestamp with time zone DEFAULT now() NOT NULL
);

-- ----------------------------------------------------------- constraints -----
-- Primary/unique keys. PostgreSQL has no ADD CONSTRAINT IF NOT EXISTS, so each one is
-- attempted and the "already there" cases are swallowed. The constraint NAMES are
-- PostfixAdmin's (admin_key, alias_key, …), which is why a re-run hits duplicate_object
-- rather than the "multiple primary keys" error.
DO $$
DECLARE
    c record;
BEGIN
    FOR c IN
        SELECT * FROM (VALUES
            ('admin',          'admin_key',         'PRIMARY KEY (username)'),
            ('alias',          'alias_key',         'PRIMARY KEY (address)'),
            ('alias_domain',   'alias_domain_pkey', 'PRIMARY KEY (alias_domain)'),
            ('config',         'config_pkey',       'PRIMARY KEY (id)'),
            ('config',         'config_name_key',   'UNIQUE (name)'),
            ('domain',         'domain_key',        'PRIMARY KEY (domain)'),
            ('domain_admins',  'domain_admins_pkey','PRIMARY KEY (id)'),
            ('fetchmail',      'fetchmail_pkey',    'PRIMARY KEY (id)'),
            ('log',            'log_pkey',          'PRIMARY KEY (id)'),
            ('mailbox',        'mailbox_key',       'PRIMARY KEY (username)'),
            ('quota',          'quota_pkey',        'PRIMARY KEY (username, path)'),
            ('quota2',         'quota2_pkey',       'PRIMARY KEY (username)'),
            ('vacation',       'vacation_pkey',     'PRIMARY KEY (email)'),
            ('vacation_notification', 'vacation_notification_pkey',
                                                    'PRIMARY KEY (on_vacation, notified)')
        ) AS t(tbl, con, def)
    LOOP
        BEGIN
            EXECUTE format('ALTER TABLE ONLY public.%I ADD CONSTRAINT %I %s',
                           c.tbl, c.con, c.def);
        EXCEPTION
            WHEN duplicate_object OR duplicate_table OR invalid_table_definition THEN
                NULL;  -- already present (the normal path on every boot after the first)
        END;
    END LOOP;
END
$$;

-- Foreign keys (PostfixAdmin's: a domain cannot be dropped while it still owns rows;
-- domain aliases cascade, a vacation's notification log cascades with it).
DO $$
DECLARE
    c record;
BEGIN
    FOR c IN
        SELECT * FROM (VALUES
            ('alias_domain', 'alias_domain_alias_domain_fkey',
             'FOREIGN KEY (alias_domain) REFERENCES public.domain(domain) ON DELETE CASCADE'),
            ('alias_domain', 'alias_domain_target_domain_fkey',
             'FOREIGN KEY (target_domain) REFERENCES public.domain(domain) ON DELETE CASCADE'),
            ('alias', 'alias_domain_fkey',
             'FOREIGN KEY (domain) REFERENCES public.domain(domain)'),
            ('domain_admins', 'domain_admins_domain_fkey',
             'FOREIGN KEY (domain) REFERENCES public.domain(domain)'),
            ('mailbox', 'mailbox_domain_fkey1',
             'FOREIGN KEY (domain) REFERENCES public.domain(domain)'),
            ('vacation', 'vacation_domain_fkey1',
             'FOREIGN KEY (domain) REFERENCES public.domain(domain)'),
            ('vacation_notification', 'vacation_notification_on_vacation_fkey',
             'FOREIGN KEY (on_vacation) REFERENCES public.vacation(email) ON DELETE CASCADE')
        ) AS t(tbl, con, def)
    LOOP
        BEGIN
            EXECUTE format('ALTER TABLE ONLY public.%I ADD CONSTRAINT %I %s',
                           c.tbl, c.con, c.def);
        EXCEPTION
            WHEN duplicate_object OR duplicate_table THEN
                NULL;
        END;
    END LOOP;
END
$$;

-- --------------------------------------------------------------- indexes -----
CREATE INDEX IF NOT EXISTS alias_address_active   ON public.alias          USING btree (address, active);
CREATE INDEX IF NOT EXISTS alias_domain_active    ON public.alias_domain   USING btree (alias_domain, active);
CREATE INDEX IF NOT EXISTS alias_domain_idx       ON public.alias          USING btree (domain);
CREATE INDEX IF NOT EXISTS domain_domain_active   ON public.domain         USING btree (domain, active);
CREATE INDEX IF NOT EXISTS log_domain_timestamp_idx ON public.log          USING btree (domain, "timestamp");
CREATE INDEX IF NOT EXISTS mailbox_domain_idx     ON public.mailbox        USING btree (domain);
CREATE INDEX IF NOT EXISTS mailbox_username_active ON public.mailbox       USING btree (username, active);
CREATE INDEX IF NOT EXISTS vacation_email_active  ON public.vacation       USING btree (email, active);

-- ------------------------------------------- quota merge functions/triggers --
-- PostfixAdmin's optional Dovecot-quota helpers. MailD does not use a quota
-- dictionary (the Maildir++ .maildirsize is authoritative, see mda/dovecot), but the
-- tables/functions are part of the upstream contract and are kept verbatim.
CREATE OR REPLACE FUNCTION public.merge_quota() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            UPDATE quota SET current = NEW.current + current
             WHERE username = NEW.username AND path = NEW.path;
            IF found THEN
                RETURN NULL;
            ELSE
                RETURN NEW;
            END IF;
      END;
      $$;

CREATE OR REPLACE FUNCTION public.merge_quota2() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            IF NEW.messages < 0 OR NEW.messages IS NULL THEN
                -- ugly kludge: we came here from this function, really do try to insert
                IF NEW.messages IS NULL THEN
                    NEW.messages = 0;
                ELSE
                    NEW.messages = -NEW.messages;
                END IF;
                return NEW;
            END IF;

            LOOP
                UPDATE quota2 SET bytes = bytes + NEW.bytes,
                    messages = messages + NEW.messages
                    WHERE username = NEW.username;
                IF found THEN
                    RETURN NULL;
                END IF;

                BEGIN
                    IF NEW.messages = 0 THEN
                    INSERT INTO quota2 (bytes, messages, username) VALUES (NEW.bytes, NULL, NEW.username);
                    ELSE
                        INSERT INTO quota2 (bytes, messages, username) VALUES (NEW.bytes, -NEW.messages, NEW.username);
                    END IF;
                    return NULL;
                    EXCEPTION WHEN unique_violation THEN
                    -- someone just inserted the record, update it
                END;
            END LOOP;
        END;
        $$;

CREATE OR REPLACE TRIGGER mergequota
    BEFORE INSERT ON public.quota FOR EACH ROW
    EXECUTE FUNCTION public.merge_quota();

CREATE OR REPLACE TRIGGER mergequota2
    BEFORE INSERT ON public.quota2 FOR EACH ROW
    EXECUTE FUNCTION public.merge_quota2();

-- ---------------------------------------------------- PostfixAdmin version -----
-- upgrade.php records its schema revision in `config`; 1847 is PostfixAdmin 3.3.13's.
-- ON CONFLICT keeps a newer value written by a real PostfixAdmin run (an operator who
-- re-adds the deprecated UI for inspection must not be told the schema is older).
INSERT INTO public.config (name, value) VALUES ('version', '1847')
ON CONFLICT (name) DO NOTHING;


