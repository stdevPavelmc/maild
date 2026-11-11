<?php

/*
 * MailD mua2 — Roundcube configuration.
 *
 * This file is static (baked into the image). Everything that depends on the deployment is
 * rendered from the container environment on every boot by mua2/render-config.php into
 * /run/maild-roundcube/maild.inc.php (root:www-data 0640), which returns a plain array: no
 * environment variable is read at request time, and the web server runs with a scrubbed
 * environment (see docker-entrypoint.sh).
 *
 * Settings are grouped as: connections, security, the MailD integration (directory, password),
 * behaviour. Roundcube's own defaults (config/defaults.inc.php) apply to anything not set here.
 */

$maild = require '/run/maild-roundcube/maild.inc.php';

$config = [];

// ---------------------------------------------------------------------------- connections
// Roundcube's own state (users, prefs, personal contacts, sessions, caches): its own database,
// owned by the restricted ROUNDCUBE_DB_USER role (db/ensure_roles.sh).
$config['db_dsnw'] = $maild['db_dsn'];

// IMAP/Sieve on the mda over STARTTLS (Dovecot has ssl = required), SMTP submission on the
// mta over implicit TLS (465). The certificates are issued for the public mail hostname, not
// for the internal service names, so peer-name verification is off on this internal hop — the
// same trade-off the SnappyMail mua makes.
$maild_tls = [
    'ssl' => [
        'verify_peer' => false,
        'verify_peer_name' => false,
        'allow_self_signed' => true,
    ],
];
$config['imap_host'] = 'tls://' . $maild['mda'] . ':143';
$config['imap_conn_options'] = $maild_tls;
$config['imap_auth_type'] = 'PLAIN';
$config['imap_delimiter'] = null;
$config['smtp_host'] = 'ssl://' . $maild['mta'] . ':465';
$config['smtp_conn_options'] = $maild_tls;
$config['smtp_user'] = '%u';
$config['smtp_pass'] = '%p';
$config['smtp_auth_type'] = 'PLAIN';

// logins without a domain get DEFAULT_DOMAIN (alice → alice@DEFAULT_DOMAIN); full addresses
// are used as typed. Usernames are lower-cased like the catalogue stores them.
$config['username_domain'] = $maild['default_domain'];
$config['username_domain_forced'] = false;
$config['login_lc'] = 2;
$config['login_username_filter'] = 'email';

// ---------------------------------------------------------------------------------- logging
// PHP's error_log is the container's stderr (php/maild.ini): `docker compose logs mua2`
$config['log_driver'] = 'php';
$config['log_logins'] = true;
$config['log_session'] = false;
$config['sql_debug'] = false;
$config['imap_debug'] = $maild['debug'];
$config['smtp_debug'] = $maild['debug'];
$config['temp_dir'] = '/tmp/roundcube/';

// --------------------------------------------------------------------------------- security
$config['des_key'] = $maild['des_key'];
$config['cipher_method'] = 'AES-256-CBC';
$config['enable_installer'] = false;
$config['ip_check'] = true;
$config['session_lifetime'] = $maild['session_lifetime'];
$config['session_samesite'] = 'Strict';
$config['x_frame_options'] = 'sameorigin';
$config['login_rate_limit'] = 3;
$config['login_autocomplete'] = 0;
$config['password_charset'] = 'UTF-8';
// Host header checks (resolve_url(), Received:, links in mail): only the names this webmail
// is published under. Empty list in render-config.php ⇒ any host (never shipped that way).
$config['trusted_host_patterns'] = $maild['trusted_hosts'];
// X-Forwarded-For / X-Real-IP are only honoured from the ingress (production: Traefik)
$config['proxy_whitelist'] = $maild['trusted_proxies'];
// the client's IP in a Received: header of sent mail (what SnappyMail's X-Originating-IP
// plugin did); 1.7.6 only uses trusted hosts and proxied IPs here
$config['http_received_header'] = true;
$config['http_received_header_encrypt'] = false;
// one identity per real address: users manage names/signatures, not sender addresses (the
// mta enforces reject_sender_login_mismatch anyway)
$config['identities_level'] = 1;
// remote content in HTML mail is blocked unless the user allows it per message
$config['show_images'] = 0;
// features that keep showing up in Roundcube's security releases and that MailD does not use
$config['enable_spellcheck'] = false;          // ATD/Google backends: outbound HTTP (1.7.6 fix)
$config['messages_cache'] = false;             // IMAP CRLF injection via _uid (1.7.6 fix)
$config['imap_cache'] = null;
$config['image_thumbnail_size'] = 0;           // no ImageMagick/GD in the image
$config['disabled_actions'] = [
    'mail.import',                             // mbox import: not needed, large input surface
];
$config['support_url'] = '';
$config['useragent'] = 'Webmail';              // no version in the generated headers

// ------------------------------------------------------------------------------ plugins
$config['plugins'] = [
    'maild_directory',     // MailD: catalogue address book (autocomplete) + identity name
    'password',            // password change → the catalogue, hashed per PASSWORD_SCHEME
    'managesieve',         // server-side filters, vacation and forward (Dovecot Sieve)
    'markasjunk',          // Junk button: moves to Junk, where the mda's imapsieve learns spam
    'archive',
    'zipdownload',
    'newmail_notifier',
    'attachment_reminder',
    'hide_blockquote',
    'identity_select',
];

// --- maild_directory (mua2/plugins/maild_directory) -------------------------------------
$config['maild_directory_dsn'] = $maild['catalogue_dsn'];
$config['maild_directory_scope'] = $maild['directory_scope'];        // domain | all | off
$config['maild_directory_aliases'] = $maild['directory_aliases'];
$config['maild_directory_hide'] = $maild['directory_hide'];
$config['maild_directory_name'] = $maild['product_name'];
$config['autocomplete_min_length'] = $maild['autocomplete_min'];
$config['autocomplete_max'] = 15;
$config['addressbook_search_mode'] = 0;         // substring: "ali" finds "Alice", "malik"…

// --- password (Roundcube's sql driver against the catalogue) -----------------------------
// The restricted role may UPDATE only mailbox.password/modified. The hash follows the
// stack-wide PASSWORD_SCHEME exactly like the AdminNG API, the SnappyMail driver and
// Dovecot's rehash-on-login: Argon2id via password_hash() with PHP's defaults (m=65536, t=4,
// p=1) and the '{ARGON2ID}' prefix Dovecot dispatches on; or, until 2027-02-01 only, the
// legacy raw md5crypt '$1$…' (weak-scheme removal: after that date argon2id is used anyway).
$config['password_driver'] = 'sql';
$config['password_db_dsn'] = $maild['catalogue_dsn'];
$config['password_query'] = 'UPDATE mailbox SET password = %P, modified = now() WHERE username = %u AND active';
$config['password_algorithm'] = $maild['password_algorithm'];
$config['password_algorithm_prefix'] = $maild['password_algorithm_prefix'];
if ($config['password_algorithm'] === 'md5-crypt' && time() >= strtotime('2027-02-01T00:00:00+00:00')) {
    // weak-scheme removal: never write a new md5crypt hash after the stack-wide cut-off
    $config['password_algorithm'] = 'hash-argon2id';
    $config['password_algorithm_prefix'] = '{ARGON2ID}';
}
$config['password_algorithm_options'] = [];
$config['password_confirm_current'] = true;
$config['password_minimum_length'] = $maild['password_min_length'];
$config['password_require_nonalpha'] = false;
$config['password_force_save'] = false;
$config['password_log'] = true;
$config['password_idn_ascii'] = false;
$config['password_disabled'] = false;
$config['password_strength_driver'] = null;

// --- managesieve (Dovecot Pigeonhole on the mda, STARTTLS) -------------------------------
$config['managesieve_host'] = 'tls://' . $maild['mda'] . ':4190';
$config['managesieve_conn_options'] = $maild_tls;
$config['managesieve_auth_type'] = 'PLAIN';
$config['managesieve_vacation'] = 1;            // vacation (out of office) as its own section
$config['managesieve_forward'] = 1;             // simple forward/redirect
$config['managesieve_raw_editor'] = false;      // no free-form script editing
$config['managesieve_kolab_master'] = false;
$config['managesieve_replace_delimiter'] = '';

// --- markasjunk: move only. NEVER a cmd_learn/sa_* driver (RCE in 1.7.3's release notes);
// the mda learns spam/ham from the move itself (imapsieve → sa-learn)
$config['markasjunk_learning_driver'] = null;
$config['markasjunk_read_spam'] = true;
$config['markasjunk_unread_ham'] = false;

// ------------------------------------------------------------------------------ behaviour
$config['product_name'] = $maild['product_name'];
$config['skin'] = 'elastic';
// ROUNDCUBE_LANGUAGE (default en_US; null = follow the browser): the login page and the
// initial language of a user's first login. Each user can still pick another in Settings.
$config['language'] = $maild['language'];
$config['timezone'] = 'auto';
$config['draft_autosave'] = 120;
$config['mime_param_folding'] = 0;
$config['default_charset'] = 'UTF-8';
$config['create_default_folders'] = true;
$config['delete_junk'] = false;
// the encoded message (ROUNDCUBE_UPLOAD_MAX × 1.33 + 10 KB, ≤ the mta's MAX_MESSAGESIZE):
// Roundcube shows max_message_size / 1.33 as the attachment limit, i.e. ROUNDCUBE_UPLOAD_MAX
$config['max_message_size'] = $maild['max_message_size'];
