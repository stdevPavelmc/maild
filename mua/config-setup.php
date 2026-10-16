#!/usr/bin/env php
<?php
/*
 * Copyright 2020-2026 Pavel Milanes Costa <pavelmc@gmail.com>
 *
 * MailD — SnappyMail configuration helper.
 *
 * Goal: apply the MailD settings to SnappyMail's `application.ini` and guarantee that the admin
 * password printed by docker-entrypoint.sh is the very password stored in that config.
 *
 * Why this exists (it replaces a crudini one-liner block):
 *   * SnappyMail writes its config with the values *quoted* (`pdo_dsn = "host=…;…"`). `crudini
 *     --set --inplace` strips those quotes, and PHP's ini parser then rejects the whole file
 *     (`syntax error, unexpected '='` on the DSN). RainLoop\Config\AbstractConfig::Load() treats
 *     an unparsable file as "no configuration" and calls Save(): the file is rewritten from the
 *     factory defaults, `security.admin_password` included.
 *   * The next admin-panel request (ActionsAdmin::AdminAppData) then finds an empty password,
 *     mints a new random one and writes it to `admin_password.txt`: a password no log ever
 *     showed, so `?admin` + the OTP from `docker compose logs mua` could not work.
 *
 * So: patch the file at text level (leaving every other line, comments included, untouched),
 * validate that it still parses, and only then touch the admin credentials.
 *
 * Env in:  SNAPPYMAIL_CONFIG, SNAPPYMAIL_ADMIN_PASSWORD_FILE (paths, with container defaults),
 *          BANNER_TITLE, POSTGRES_HOST/USER/PASSWORD/EXTRA_DB,
 *          MUA_ADMIN_USER (default `maild`), MUA_ADMIN_PASSWORD (empty ⇒ keep or generate).
 * Out:     `MUA_ADMIN_LOGIN=`, `MUA_ADMIN_PASSWORD=`, `MUA_ADMIN_PASSWORD_SOURCE=` on stdout
 *          (env|existing|generated) for the entrypoint banner; warnings/errors on stderr.
 *
 * Exit:    0 ok, 1 fatal (the caller must NOT advertise a password it could not store).
 *
 * Out of scope: the per-domain configs (domains/*.json), the entrypoint writes those itself.
 */

const DEFAULT_CONFIG = '/var/www/html/data/_data_/_default_/configs/application.ini';
const DEFAULT_ADMIN_USER = 'maild';
// MailD's baseline plugins: their code is baked into the image (mua/Dockerfile), the entrypoint
// syncs it into the volume and they are kept enabled here. Override with `MUA_PLUGINS`.
const DEFAULT_PLUGINS = 'add-x-originating-ip-header,change-password,two-factor-auth';

function fail(string $sMsg): void
{
	fwrite(STDERR, 'ERROR: ' . $sMsg . "\n");
	exit(1);
}

function warn(string $sMsg): void
{
	fwrite(STDERR, 'WARNING: ' . $sMsg . "\n");
}

/** SnappyMail's own quoting rule (RainLoop\Config\AbstractConfig::Save). */
function ini_quote(string $sValue): string
{
	return '"' . addcslashes($sValue, '\\"') . '"';
}

/** Single-line safety: a newline inside a value would be read back as an ini continuation. */
function ini_flat(string $sValue): string
{
	return trim((string) \preg_replace('/[\r\n]+/', ' ', $sValue));
}

/**
 * Replace (or insert) `key = value` inside `[section]`, leaving every other line untouched.
 * Text level on purpose: SnappyMail's writer drops the comments of the file and we must not
 * reformat (nor re-type) settings that are not ours.
 */
function ini_patch(string $sText, string $sSection, string $sKey, string $sRawValue): string
{
	$sLine = $sKey . ' = ' . $sRawValue;
	$sSecRe = '/^(\s*\[' . \preg_quote($sSection, '/') . '\][^\n]*\n)(.*?)(?=^\s*\[|\z)/ms';
	if (\preg_match($sSecRe, $sText, $aMatch, PREG_OFFSET_CAPTURE)) {
		$sBody = $aMatch[2][0];
		$iBodyStart = $aMatch[2][1];
		$sKeyRe = '/^\s*' . \preg_quote($sKey, '/') . '\s*=.*$/im';
		if (\preg_match($sKeyRe, $sBody)) {
			// callback on purpose: a plain replacement would expand `$2y$10$…` (phpass hashes),
			// `$POSTGRES_*` passwords… as backreferences and store a mangled value
			$sNewBody = \preg_replace_callback($sKeyRe,
				function () use ($sLine) { return $sLine; }, $sBody, 1);
		} else {
			// append after the last content line of the section, before its trailing blanks
			$sTrail = \substr($sBody, \strlen(\rtrim($sBody)));
			$sNewBody = \rtrim($sBody) . "\n" . $sLine . $sTrail;
		}
		return \substr($sText, 0, $iBodyStart) . $sNewBody
			. \substr($sText, $iBodyStart + \strlen($sBody));
	}

	// section missing: create it at the end of the file
	return \rtrim($sText, "\n") . "\n\n[" . $sSection . "]\n" . $sLine . "\n";
}

/** Last resort for files mangled by an older release: quote the values that need it. */
function ini_quote_repair(string $sText): string
{
	$aLines = \explode("\n", $sText);
	$bInSection = false;
	foreach ($aLines as $i => $sLine) {
		if (\preg_match('/^\s*\[[^\]]+\]\s*$/', $sLine)) {
			$bInSection = true;
			continue;
		}
		if (!$bInSection || \preg_match('/^\s*[;#]/', $sLine)) {
			continue;
		}
		// key = value (simple keys/values only: anything else is left alone)
		if (\preg_match('/^(\s*[A-Za-z0-9_.\-]+\s*=\s*)(.*)$/', $sLine, $aMatch)) {
			$sValue = \trim($aMatch[2]);
			$bSafe = '' === $sValue						// empty
				|| '"' === \substr($sValue, 0, 1)		// already quoted
				|| \preg_match('/^[A-Za-z0-9_.\-]+$/', $sValue);	// On/Off/numbers/words
			if (!$bSafe) {
				$aLines[$i] = $aMatch[1] . ini_quote($sValue);
			}
		}
	}
	return \implode("\n", $aLines);
}

/**
 * Parse an ini string, capturing why PHP refused it (that message is the whole diagnostic).
 * Same parser SnappyMail uses, so "it parses here" means "it parses there".
 */
function ini_parse(string $sText, ?string &$sWhy = null): array
{
	$sWhy = '';
	$iPrev = \error_reporting(E_ALL);
	\set_error_handler(function ($iNo, $sStr) use (&$sWhy) { $sWhy = $sStr; return true; });
	$aData = \parse_ini_string($sText, true);
	\restore_error_handler();
	\error_reporting($iPrev);
	return \is_array($aData) ? $aData : [];
}

function ini_read(string $sFile, ?string &$sWhy = null): array
{
	return ini_parse((string) \file_get_contents($sFile), $sWhy);
}

/** The web server must own its configuration: a root-owned 0600 file is invisible to www-data. */
function own_file(string $sFile): void
{
	@\chown($sFile, 'www-data');
	@\chgrp($sFile, 'www-data');
	@\chmod($sFile, 0600);
}

/**
 * Write atomically: SnappyMail keeps serving requests while we run, and a half written ini would
 * send it back to its factory defaults -- the very failure this helper exists to prevent.
 */
function write_file(string $sFile, string $sContent): void
{
	$sTmp = $sFile . '.tmp';
	if (false === \file_put_contents($sTmp, $sContent)) {
		fail("could not write {$sTmp}");
	}
	own_file($sTmp);
	if (!\rename($sTmp, $sFile)) {
		@\unlink($sTmp);
		fail("could not replace {$sFile}");
	}
	own_file($sFile);
}

/**
 * Verification failed: leave the container exactly as we found it (a half applied config is
 * worse than none, it would neither log in nor self-heal) and let the caller shout about it.
 */
function rollback(string $sConfig, string $sOriginal, string $sPassFile, bool $bTxtWritten): void
{
	write_file($sConfig, $sOriginal);
	if ($bTxtWritten && \is_file($sPassFile)) {
		@\unlink($sPassFile);
	}
}

/**
 * Merge keys into a SnappyMail plugin settings file (configs/plugin-<name>.json, written by
 * RainLoop\Config\Plugin). `$aSet` always wins, `$aDefault` only fills what is missing: a value an
 * operator changed in the admin panel must survive the next boot.
 */
function plugin_config_merge(string $sFile, array $aSet, array $aDefault): void
{
	$aData = [];
	if (\is_readable($sFile)) {
		$aDecoded = \json_decode((string) \file_get_contents($sFile), true);
		\is_array($aDecoded) && $aData = $aDecoded;
	}
	$aPlugin = \is_array($aData['plugin'] ?? null) ? $aData['plugin'] : [];
	$aData['plugin'] = \array_merge($aDefault, $aPlugin, $aSet);
	write_file($sFile, \json_encode($aData, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
}

// ---------------------------------------------------------------------------------------------
$sConfig = \getenv('SNAPPYMAIL_CONFIG') ?: DEFAULT_CONFIG;
$sPassFile = \getenv('SNAPPYMAIL_ADMIN_PASSWORD_FILE')
	?: \dirname(\dirname($sConfig)) . '/admin_password.txt';
$sWhy = '';

if (!\is_file($sConfig)) {
	fail("no SnappyMail configuration at {$sConfig}");
}
$sOriginal = (string) \file_get_contents($sConfig);
if ('' === \trim($sOriginal)) {
	fail("empty SnappyMail configuration at {$sConfig}");
}
// what the file says right now: a file mangled by an older release parses as empty, which the
// repair below takes care of
$aOrig = ini_parse($sOriginal, $sWhy);

// --- the values MailD owns --------------------------------------------------------------------
$sBanner = \getenv('BANNER_TITLE') ?: 'Webmail';
$sDbHost = \getenv('POSTGRES_HOST') ?: 'db';
$sDbExtra = \getenv('POSTGRES_EXTRA_DB') ?: 'contacts';

$sAdminUser = \trim((string) \getenv('MUA_ADMIN_USER')) ?: DEFAULT_ADMIN_USER;
if (!\preg_match('/^[A-Za-z0-9_.@+\-]+$/', $sAdminUser)) {
	warn("MUA_ADMIN_USER '{$sAdminUser}' has unexpected characters, using " . DEFAULT_ADMIN_USER);
	$sAdminUser = DEFAULT_ADMIN_USER;
}

$sEnvPassword = \trim((string) \getenv('MUA_ADMIN_PASSWORD'));
if (\preg_match('/[\r\n]/', $sEnvPassword)) {
	fail('MUA_ADMIN_PASSWORD must be a single line');
}

// --- plugins: keep the MailD baseline installed and enabled ------------------------------------
$sPluginsRequested = \trim((string) \getenv('MUA_PLUGINS'));
if ('' === $sPluginsRequested) {
	$sPluginsRequested = DEFAULT_PLUGINS;
}
$aPlugins = [];
// baseline first (stable order), then whatever the admin panel had enabled: additive on purpose,
// an operator disables a baseline plugin by dropping it from MUA_PLUGINS and unticking it there
foreach (\explode(',', $sPluginsRequested . ',' . (string) ($aOrig['plugins']['enabled_list'] ?? '')) as $sPlugin) {
	$sPlugin = \trim($sPlugin);
	if ('' !== $sPlugin) {
		$aPlugins[$sPlugin] = true;
	}
}

$aSections = [
	'webmail' => [
		'title' => ini_quote(ini_flat($sBanner)),
		'loading_description' => ini_quote('Maild Webmail'),
	],
	'contacts' => [
		// the key is `enable`, not `enabled`: the latter is not a SnappyMail key, it was
		// silently ignored and the contacts database never got enabled
		'enable' => 'On',
		'type' => ini_quote('pgsql'),
		'pdo_dsn' => ini_quote(ini_flat("host={$sDbHost};port=5432;dbname={$sDbExtra}")),
		'pdo_user' => ini_quote(ini_flat((string) \getenv('POSTGRES_USER'))),
		'pdo_password' => ini_quote(ini_flat((string) \getenv('POSTGRES_PASSWORD'))),
	],
	'security' => [
		'admin_login' => ini_quote($sAdminUser),
	],
	'plugins' => [
		'enable' => 'On',
		'enabled_list' => ini_quote(\implode(',', \array_keys($aPlugins))),
	],
];

$sText = $sOriginal;
foreach ($aSections as $sSection => $aKeys) {
	foreach ($aKeys as $sKey => $sValue) {
		$sText = ini_patch($sText, $sSection, $sKey, $sValue);
	}
}

// --- the file must stay readable by SnappyMail -------------------------------------------------
$aCfg = ini_parse($sText, $sWhy);
if (!$aCfg) {
	warn("the configuration did not parse ({$sWhy}), repairing unquoted values");
	$sText = ini_quote_repair($sText);
	$aCfg = ini_parse($sText, $sWhy);
}
if (!$aCfg) {
	fail("the configuration is unparsable and could not be repaired ({$sWhy}); left it untouched,"
		. ' SnappyMail would fall back to its factory defaults');
}

// --- admin credentials -------------------------------------------------------------------------
$sHash = (string) ($aCfg['security']['admin_password'] ?? '');
$sStored = \is_readable($sPassFile) ? \trim((string) \file_get_contents($sPassFile)) : '';

if ('' !== $sEnvPassword) {
	$sPassword = $sEnvPassword;
	$sSource = 'env';
} else if ('' !== $sStored && '' !== $sHash && \password_verify($sStored, $sHash)) {
	$sPassword = $sStored;
	$sSource = 'existing';
} else if ('' === $sStored && '' !== $sHash) {
	// set from the admin panel: SnappyMail deletes the plaintext file when an administrator
	// changes the password there. Keep it (we cannot know it, and silently replacing a
	// password somebody chose on purpose would be an evil of its own)
	$sPassword = '';
	$sSource = 'stored';
} else {
	// either nothing is set yet, or admin_password.txt no longer matches the stored hash
	// (the case that made the printed OTP fail: a wiped config regenerated the hash behind our
	// back). Take ownership of the credentials and print something that actually works.
	$sPassword = \substr(\base64_encode(\random_bytes(16)), 0, 12);
	$sSource = 'generated';
}

$bTxtWritten = false;
if ('existing' !== $sSource && 'stored' !== $sSource) {
	$sText = ini_patch($sText, 'security', 'admin_password',
		ini_quote(\password_hash($sPassword, PASSWORD_DEFAULT)));
	if ('generated' === $sSource) {
		write_file($sPassFile, $sPassword . "\n");
		$bTxtWritten = true;
	} else if (\is_file($sPassFile)) {
		// the password comes from the environment: drop the plaintext copy (and with it the
		// "weak password" flag the admin panel shows)
		@\unlink($sPassFile);
	}
}

// --- write it, then check what landed on disk --------------------------------------------------
write_file($sConfig, $sText);

$aCfg = ini_read($sConfig, $sWhy);
if (!$aCfg) {
	rollback($sConfig, $sOriginal, $sPassFile, $bTxtWritten);
	fail("the configuration is unparsable after the update ({$sWhy}); kept the previous one");
}
if ((string) ($aCfg['security']['admin_login'] ?? '') !== $sAdminUser) {
	rollback($sConfig, $sOriginal, $sPassFile, $bTxtWritten);
	fail("admin_login was not stored in {$sConfig}; kept the previous configuration");
}
$aStoredPlugins = \array_filter(\array_map('trim', \explode(',', (string) ($aCfg['plugins']['enabled_list'] ?? ''))));
foreach (\array_keys($aPlugins) as $sPlugin) {
	if (!\in_array($sPlugin, $aStoredPlugins, true)) {
		rollback($sConfig, $sOriginal, $sPassFile, $bTxtWritten);
		fail("plugin {$sPlugin} is missing from enabled_list ({$sConfig}); kept the previous configuration");
	}
}
$sHashNow = (string) ($aCfg['security']['admin_password'] ?? '');
$bPasswordOk = 'stored' === $sSource
	? ('' !== $sHashNow && $sHashNow === $sHash)	// untouched: still the admin's own password
	: ('' !== $sHashNow && \password_verify($sPassword, $sHashNow));
if (!$bPasswordOk) {
	rollback($sConfig, $sOriginal, $sPassFile, $bTxtWritten);
	fail("the admin password was not stored in {$sConfig}; kept the previous configuration");
}

// --- the MailD change-password driver ----------------------------------------------------------
// MailD ships this driver (mua/plugins/change-password-maild, see its header comment): it has to be
// the enabled one, or the webmail answers "There are no change-password drivers enabled". Values an
// operator edits in the panel survive; drop change-password from MUA_PLUGINS to stop managing it.
if (isset($aPlugins['change-password'])) {
	plugin_config_merge(\dirname($sConfig) . '/plugin-change-password.json',
		['driver_maild_enabled' => true],
		['driver_maild_allowed_emails' => '*']
	);
}

echo 'MUA_ADMIN_LOGIN=' . $sAdminUser . "\n";
if ('env' !== $sSource && 'stored' !== $sSource) {
	echo 'MUA_ADMIN_PASSWORD=' . $sPassword . "\n";
}
echo 'MUA_ADMIN_PASSWORD_SOURCE=' . $sSource . "\n";
exit(0);
