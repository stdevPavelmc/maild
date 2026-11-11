<?php

/*
 * MailD mua — render the deployment-specific Roundcube settings from the environment.
 *
 *   php render-config.php <output file>
 *
 * Run by docker-entrypoint.sh on every boot (as root). Writes a PHP file that returns one array
 * (var_export: no quoting games, any character in a password is safe), consumed by the static
 * config/config.inc.php. Exits non-zero, writing nothing, when a value is unusable — the
 * entrypoint then refuses to start the web server rather than serve a half-configured webmail.
 *
 * ROUNDCUBE_DES_KEY reaches this script already resolved by the entrypoint (operator value, or
 * the one generated on the first boot and kept in /var/lib/roundcube).
 */

function env(string $name, string $default = ''): string
{
    $v = getenv($name);
    return ($v === false || trim($v) === '') ? $default : trim($v);
}

function fail(string $msg): void
{
    fwrite(STDERR, "mua: ERROR - {$msg}\n");
    exit(1);
}

function csv(string $value): array
{
    return array_values(array_filter(array_map('trim', explode(',', $value)), 'strlen'));
}

function yes(string $value): bool
{
    return in_array(strtolower($value), ['yes', 'true', '1', 'on'], true);
}

function size_bytes(string $value): int
{
    if (!preg_match('/^(\d+)\s*([KMG]?)B?$/i', $value, $m)) {
        fail("ROUNDCUBE_UPLOAD_MAX must look like 24M, got '{$value}'");
    }
    $mult = ['' => 1, 'K' => 1024, 'M' => 1048576, 'G' => 1073741824][strtoupper($m[2])];
    return (int) $m[1] * $mult;
}

$out = $argv[1] ?? '';
if ($out === '') {
    fail('usage: render-config.php <output file>');
}

$domain = strtolower(env('DEFAULT_DOMAIN'));
if (!preg_match('/^[a-z0-9.-]+\.[a-z0-9-]+$/', $domain)) {
    fail('DEFAULT_DOMAIN is empty or not a domain name');
}

$dbPass = env('ROUNDCUBE_DB_PASSWORD');
if ($dbPass === '') {
    fail('ROUNDCUBE_DB_PASSWORD is not set: mua connects as its own restricted role (db/ensure_roles.sh)');
}
$dbUser = env('ROUNDCUBE_DB_USER', 'maild_roundcube');
$dbHost = env('POSTGRES_HOST', 'db');

$desKey = env('ROUNDCUBE_DES_KEY');
if (strlen($desKey) < 32) {
    fail('ROUNDCUBE_DES_KEY must be at least 32 characters (AES-256-CBC)');
}

// pgsql://user:pass@host:5432/db — rcube_db::parse_dsn() rawurldecode()s every part
$dsn = static fn (string $db): string => sprintf('pgsql://%s:%s@%s:5432/%s',
    rawurlencode($dbUser), rawurlencode($dbPass), $dbHost, rawurlencode($db));

// PASSWORD_SCHEME → Roundcube password plugin algorithm (+ the Dovecot {SCHEME} prefix).
// config.inc.php re-checks the md5crypt cut-off at request time, so a container that keeps
// running past 2027-02-01 switches to argon2id without a restart.
$scheme = strtolower(env('PASSWORD_SCHEME', 'argon2id'));
switch ($scheme) {
    case 'argon2id':
        [$algo, $prefix] = ['hash-argon2id', '{ARGON2ID}'];
        break;
    case 'md5crypt':
        [$algo, $prefix] = ['md5-crypt', ''];
        fwrite(STDERR, "mua: WARNING - PASSWORD_SCHEME=md5crypt: legacy hashes until 2027-02-01, argon2id after\n");
        break;
    default:
        fail("PASSWORD_SCHEME '{$scheme}' is not supported (argon2id | md5crypt)");
}
if (!defined('PASSWORD_ARGON2ID')) {
    fail('this PHP has no Argon2id support (password_hash)');
}

$scope = strtolower(env('ROUNDCUBE_DIRECTORY_SCOPE', 'domain'));
if (!in_array($scope, ['domain', 'all', 'off'], true)) {
    fail("ROUNDCUBE_DIRECTORY_SCOPE must be domain, all or off, got '{$scope}'");
}

// the MCP service mailbox sends notices only: keep it out of the directory
$hide = csv(strtolower(env('ROUNDCUBE_DIRECTORY_HIDE')));
$hide[] = strtolower(env('MCP_SERVICE_EMAIL', "mcp@{$domain}"));

$hosts = csv(env('ROUNDCUBE_TRUSTED_HOSTS'));
if (!$hosts) {
    $hosts = ["webmails.{$domain}", "webmail.{$domain}", 'localhost', '127.0.0.1'];
}

// default UI language: a Roundcube locale (en_US, es_ES, es_419, pt_BR…; "es-es"/"es_es" are
// normalised, a bare "es" goes through Roundcube's own alias table) or "auto" = the browser's
$language = env('ROUNDCUBE_LANGUAGE', 'en_US');
if (strtolower($language) === 'auto') {
    $language = null;
} else {
    $locDir = '/var/www/roundcube/program/localization';
    if (preg_match('/^([a-z]{2,3})(?:[_-]([a-z0-9]{2,3}))?$/i', $language, $m)) {
        $language = strtolower($m[1]) . (isset($m[2]) ? '_' . strtoupper($m[2]) : '');
    }
    if (!is_dir("{$locDir}/{$language}")) {
        $rcube_language_aliases = [];
        @include "{$locDir}/index.inc";
        $language = $rcube_language_aliases[$language] ?? $language;
    }
    if (!preg_match('/^[a-z]{2,3}(_[A-Z0-9]{2,3})?$/', $language) || !is_dir("{$locDir}/{$language}")) {
        fail("ROUNDCUBE_LANGUAGE: no Roundcube localization '" . env('ROUNDCUBE_LANGUAGE') . "' (e.g. en_US, es_ES, es_419, or auto)");
    }
}

// Roundcube's max_message_size is the whole ENCODED message: it shows max_message_size / 1.33
// as the attachment limit (base64) and counts 10 KB for the body. So ROUNDCUBE_UPLOAD_MAX (the
// attachment limit the user sees) becomes max_message_size = upload × 1.33 + 10 KB, capped by
// the mta's MAX_MESSAGESIZE (a larger message would be refused at submission anyway).
$uploadBytes = size_bytes(env('ROUNDCUBE_UPLOAD_MAX', '24M'));
$maxMessage = (int) ceil($uploadBytes * 1.33) + 10 * 1024;
$mtaMax = (int) env('MAX_MESSAGESIZE', '34865152');
if ($mtaMax > 0 && $maxMessage > $mtaMax) {
    fwrite(STDERR, sprintf("mua: WARNING - ROUNDCUBE_UPLOAD_MAX=%s needs %d bytes once base64-encoded, more than the mta's MAX_MESSAGESIZE=%d: capped, attachments up to ~%d MB\n",
        env('ROUNDCUBE_UPLOAD_MAX', '24M'), $maxMessage, $mtaMax, intdiv((int) (($mtaMax - 10240) / 1.33), 1048576)));
    $maxMessage = $mtaMax;
}

$minChars = (int) env('ROUNDCUBE_AUTOCOMPLETE_MIN', '3');
$minPass = (int) env('ROUNDCUBE_PASSWORD_MIN_LENGTH', '8');
$lifetime = (int) env('ROUNDCUBE_SESSION_LIFETIME', '30');

$settings = [
    'default_domain' => $domain,
    'mta' => env('MTA', 'mta'),
    'mda' => env('MDA', 'mda'),
    'db_dsn' => $dsn(env('ROUNDCUBE_DB', 'roundcube')),
    'catalogue_dsn' => $dsn(env('POSTGRES_DB', 'mailddb')),
    'des_key' => $desKey,
    'product_name' => env('ROUNDCUBE_PRODUCT_NAME', env('BANNER_TITLE', 'Webmail')),
    'language' => $language,
    'session_lifetime' => max(5, $lifetime),
    'trusted_hosts' => $hosts,
    'trusted_proxies' => csv(env('ROUNDCUBE_TRUSTED_PROXIES')),
    'directory_scope' => $scope,
    'directory_aliases' => yes(env('ROUNDCUBE_DIRECTORY_ALIASES', 'yes')),
    'directory_hide' => array_values(array_unique($hide)),
    'autocomplete_min' => max(1, $minChars),
    'password_algorithm' => $algo,
    'password_algorithm_prefix' => $prefix,
    'password_min_length' => max(8, $minPass),
    'upload_max' => env('ROUNDCUBE_UPLOAD_MAX', '24M'),
    'upload_max_bytes' => size_bytes(env('ROUNDCUBE_UPLOAD_MAX', '24M')),
    'max_message_size' => $maxMessage,
    'debug' => yes(env('ROUNDCUBE_DEBUG', 'no')),
];

$php = "<?php\n// generated by mua/render-config.php on every boot — do not edit\nreturn "
     . var_export($settings, true) . ";\n";

$tmp = $out . '.tmp';
if (file_put_contents($tmp, $php) === false || !rename($tmp, $out)) {
    fail("cannot write {$out}");
}

// for the entrypoint (never the secrets)
printf("PASSWORD_ALGORITHM=%s\nDIRECTORY_SCOPE=%s\nUPLOAD_MAX_BYTES=%d\nTRUSTED_HOSTS=%s\nLANGUAGE=%s\n",
    $algo, $scope, $settings['upload_max_bytes'], implode(',', $hosts), $language ?? 'auto');
