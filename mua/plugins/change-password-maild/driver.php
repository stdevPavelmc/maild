<?php

/**
 * MailD change-password driver for the SnappyMail "change-password" plugin.
 *
 * The plugin discovers drivers in two places (see its index.php):
 *   1. plugins/change-password/drivers/<name>.php  → class ChangePasswordDriver<Name>
 *   2. plugins/change-password-<name>/driver.php   → class ChangePassword<name>Driver
 * We use (2) on purpose: it lives *outside* the upstream package directory, so installing or
 * updating `change-password` from the admin panel can never overwrite this file. Enable it with
 * the plugin setting `driver_maild_enabled` (mua/config-setup.php seeds it on every boot, so the
 * webmail ships with a working password change out of the box).
 *
 * What it does: writes the new password into the MailD catalogue (the PostfixAdmin schema in
 * PostgreSQL) exactly like the admin UI does — `mailbox.password`, plus `modified` — hashed in
 * the stack-wide PASSWORD_SCHEME (Argon2id by default, '{ARGON2ID}$argon2id$…', which Dovecot
 * verifies through its {SCHEME} prefix dispatch; the legacy raw md5crypt ($1$…) is only an
 * escape hatch: weak-scheme support is REMOVED on 2027-02-01, see .agents/services/
 * configuration.md). It uses the same parameters the AdminNG API uses (PHP's
 * PASSWORD_ARGON2ID defaults: m=65536, t=4, p=1), so nothing distinguishes a password changed
 * here from one changed via the API or rehashed by Dovecot's rehash-on-login.
 *
 * Connection defaults come from the container environment (POSTGRES_HOST/DB/USER/PASSWORD), so no
 * configuration is needed; every value can be overridden from the admin panel (Plugins → Change
 * Password → MailD catalogue), including the hash scheme for deployments that want another one
 * (see .agents/services/catalog.md).
 */

use SnappyMail\SensitiveString;

class ChangePasswordMaildDriver
{
	const
		NAME        = 'MailD catalogue (PostgreSQL)',
		DESCRIPTION = 'Writes the new password into the MailD catalogue, hashed per PASSWORD_SCHEME (Argon2id by default; the md5crypt escape hatch ends on 2027-02-01).';

	/** @var \RainLoop\Config\Plugin */
	private $oConfig = null;

	/** @var \MailSo\Log\Logger */
	private $oLogger = null;

	function __construct(\RainLoop\Config\Plugin $oConfig, \MailSo\Log\Logger $oLogger)
	{
		$this->oConfig = $oConfig;
		$this->oLogger = $oLogger;
	}

	/** The image always ships pdo_pgsql (mua/Dockerfile), so this driver is always usable. */
	public static function isSupported() : bool
	{
		return \extension_loaded('pdo_pgsql');
	}

	public static function configMapping() : array
	{
		return [
			\RainLoop\Plugins\Property::NewInstance('maild_dsn')->SetLabel('DSN')
				->SetDescription('Empty: built from the container environment (POSTGRES_HOST/POSTGRES_DB)')
				->SetDefaultValue(''),
			\RainLoop\Plugins\Property::NewInstance('maild_user')->SetLabel('User')
				->SetDescription('Empty: POSTGRES_USER')
				->SetDefaultValue(''),
			\RainLoop\Plugins\Property::NewInstance('maild_password')->SetLabel('Password')
				->SetType(\RainLoop\Enumerations\PluginPropertyType::PASSWORD)
				->SetDescription('Empty: POSTGRES_PASSWORD')
				->SetDefaultValue(''),
			\RainLoop\Plugins\Property::NewInstance('maild_encrypt')->SetLabel('Encryption')
				->SetType(\RainLoop\Enumerations\PluginPropertyType::SELECTION)
				->SetDefaultValue(['argon2id', 'md5crypt', 'bcrypt', 'Argon2i', 'SHA256-CRYPT', 'SHA512-CRYPT', 'none'])
				->SetDescription('argon2id is what PASSWORD_SCHEME (AdminNG API + Dovecot) expect in MailD; md5crypt is the legacy escape hatch (ends 2027-02-01)'),
			\RainLoop\Plugins\Property::NewInstance('maild_encrypt_prefix')->SetLabel('Encrypt prefix')
				->SetDescription('Only for the non md5crypt schemes, e.g. {ARGON2ID} (Dovecot needs the {SCHEME} prefix); empty = auto (default per scheme)')
				->SetDefaultValue(''),
			\RainLoop\Plugins\Property::NewInstance('maild_update_modified')->SetLabel('Update the modified timestamp')
				->SetType(\RainLoop\Enumerations\PluginPropertyType::BOOL)
				->SetDefaultValue(true),
		];
	}

	/**
	 * @return bool true when the catalogue row was updated (the plugin reports "could not save"
	 *              otherwise, and the webmail keeps the old password)
	 */
	public function ChangePassword(\RainLoop\Model\Account $oAccount, SensitiveString $oPrevPassword, SensitiveString $oNewPassword) : bool
	{
		try
		{
			$sEmail = $oAccount->Email();
			if (!\strlen($sEmail)) {
				throw new \RuntimeException('empty email address');
			}

			$sDsn = $this->get('maild_dsn') ?: \sprintf('pgsql:host=%s;port=5432;dbname=%s',
				\getenv('POSTGRES_HOST') ?: 'db', \getenv('POSTGRES_DB') ?: 'mailddb');
			$sUser = $this->get('maild_user') ?: (string) \getenv('POSTGRES_USER');
			$sPassword = $this->get('maild_password') ?: (string) \getenv('POSTGRES_PASSWORD');
			if (!\strlen($sUser)) {
				throw new \RuntimeException('no catalogue credentials in the environment');
			}

			$sScheme = self::defaultScheme();
			$sAlgo = $this->get('maild_encrypt');
			$sPrefix = $this->get('maild_encrypt_prefix');
			if ('' === $sAlgo) {
				// not configured in the panel: follow the stack-wide PASSWORD_SCHEME
				$sAlgo = $sScheme['algo'];
			}

			$sHash = self::encrypt($sAlgo, $sPrefix, $oNewPassword);

			$sSql = 'UPDATE mailbox SET password = :password'
				. ($this->oConfig->Get('plugin', 'maild_update_modified', true) ? ', modified = now()' : '')
				. ' WHERE username = :username AND active';

			$oPdo = new \PDO($sDsn, $sUser, $sPassword, [
				\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION,
				\PDO::ATTR_EMULATE_PREPARES => true,
			]);
			$oStatement = $oPdo->prepare($sSql);
			$oStatement->execute([':password' => $sHash, ':username' => $sEmail]);

			if (1 === $oStatement->rowCount()) {
				$this->log("MailD: password updated for {$sEmail}");
				return true;
			}

			// no such mailbox, or it is inactive: PostfixAdmin would not let it log in either
			$this->log("MailD: no active mailbox {$sEmail} in the catalogue");
		}
		catch (\Throwable $oException)
		{
			// never log the password (nor the DSN): just what failed
			$this->log('MailD: password change failed: ' . $oException->getMessage());
		}

		return false;
	}

	/**
	 * The stack-wide default (PASSWORD_SCHEME): 'argon2id' by default (the
	 * '{ARGON2ID}' prefix is what Dovecot's SQL passdb requires for anything
	 * that is not the default_password_scheme) or the legacy 'md5crypt' escape
	 * hatch — which stops being valid on 2027-02-01 (weak-scheme removal,
	 * see .agents/services/configuration.md).
	 */
	private static function defaultScheme() : array
	{
		$sScheme = \strtolower(\trim((string) \getenv('PASSWORD_SCHEME') ?: 'argon2id'));
		if ('md5crypt' === $sScheme) {
			return ['algo' => 'md5crypt', 'prefix' => ''];
		}
		return ['algo' => 'argon2id', 'prefix' => '{ARGON2ID}'];
	}

	/**
	 * md5crypt the way admin/seed.sh does it ($1$ + 8 hex chars); the other schemes reuse the
	 * helper the change-password plugin already has, with the optional Dovecot {SCHEME} prefix.
	 */
	private static function encrypt(string $sAlgo, string $sPrefix, SensitiveString $oPassword) : string
	{
		$sAlgo = \strtolower(\trim($sAlgo));
		if ('' === $sAlgo || 'md5crypt' === $sAlgo) {
			// Legacy escape hatch with a hard end: weak-scheme support is removed
			// stack-wide on 2027-02-01 (Dovecot auth_allow_weak_schemes goes 'no',
			// the AdminNG API refuses to boot with PASSWORD_SCHEME=md5crypt).
			if (\time() >= \strtotime('2027-02-01T00:00:00+00:00')) {
				throw new \RuntimeException('md5crypt password hashing is no longer supported (weak-scheme removal, 2027-02-01)');
			}
			$sHash = \crypt((string) $oPassword, \sprintf('$1$%08x$', \crc32(\uniqid('', true))));
			if (!\str_starts_with($sHash, '$1$')) {
				throw new \RuntimeException('this PHP has no MD5 crypt support');
			}
			return $sHash;
		}
		// anything else must be a scheme the plugin knows, or we would store a password that
		// neither Dovecot nor the API can verify (the plugin's helper falls back to the
		// plaintext for unknown values, which is never what we want here)
		if (!\in_array($sAlgo, ['none', 'bcrypt', 'argon2i', 'argon2id', 'sha256-crypt', 'sha512-crypt'], true)) {
			throw new \RuntimeException("unsupported encryption '{$sAlgo}'");
		}
		// 'argon2id' is password_hash(PASSWORD_ARGON2ID) with PHP's defaults
		// (m=65536, t=4, p=1) — the same parameters the AdminNG API writes.
		// Dovecot's SQL passdb needs the explicit {SCHEME} prefix for anything
		// that is not the default_password_scheme: auto-fill it per algo unless
		// the operator set their own.
		if ('' === $sPrefix) {
			$sPrefix = [
				'argon2id' => '{ARGON2ID}',
				'argon2i' => '{ARGON2I}',
				'bcrypt' => '{BLF-CRYPT}',
				'sha256-crypt' => '{SHA256-CRYPT}',
				'sha512-crypt' => '{SHA512-CRYPT}',
			][$sAlgo] ?? '';
		}
		return $sPrefix . \ChangePasswordPlugin::encrypt($sAlgo, $oPassword);
	}

	private function get(string $sKey) : string
	{
		$mValue = $this->oConfig->Get('plugin', $sKey, '');
		if (\is_array($mValue)) {
			// a SELECTION property that was never saved carries its options list:
			// signal "not configured" so the PASSWORD_SCHEME env default applies
			return '';
		}
		return \trim((string) $mValue);
	}

	private function log(string $sMessage) : void
	{
		if ($this->oLogger) {
			$this->oLogger->Write($sMessage);
		}
	}
}
