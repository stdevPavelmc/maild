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
 * MailD's own scheme, md5crypt ($1$…), which PostfixAdmin (encrypt=md5crypt) and Dovecot
 * (default_password_scheme = MD5-CRYPT) both verify. It uses the same generator admin/seed.sh
 * uses, so nothing distinguishes a password changed here from one changed in PostfixAdmin.
 *
 * Connection defaults come from the container environment (POSTGRES_HOST/DB/USER/PASSWORD), so no
 * configuration is needed; every value can be overridden from the admin panel (Plugins → Change
 * Password → MailD catalogue), including the hash scheme for deployments that moved
 * POSTFIXADMIN_ENCRYPT away from md5crypt (see .agents/services/catalog.md).
 */

use SnappyMail\SensitiveString;

class ChangePasswordMaildDriver
{
	const
		NAME        = 'MailD catalogue (PostgreSQL)',
		DESCRIPTION = 'Writes the new password into the MailD catalogue, the same way PostfixAdmin does (md5crypt by default).';

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
				->SetDefaultValue(['md5crypt', 'bcrypt', 'Argon2i', 'Argon2id', 'SHA256-CRYPT', 'SHA512-CRYPT', 'none'])
				->SetDescription('md5crypt is what PostfixAdmin (POSTFIXADMIN_ENCRYPT) and Dovecot expect in MailD'),
			\RainLoop\Plugins\Property::NewInstance('maild_encrypt_prefix')->SetLabel('Encrypt prefix')
				->SetDescription('Only for the non md5crypt schemes, e.g. {ARGON2ID} or {BLF-CRYPT} (Dovecot needs it)')
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

			$sHash = self::encrypt($this->get('maild_encrypt') ?: 'md5crypt',
				$this->get('maild_encrypt_prefix'), $oNewPassword);

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
	 * md5crypt the way admin/seed.sh does it ($1$ + 8 hex chars); the other schemes reuse the
	 * helper the change-password plugin already has, with the optional Dovecot {SCHEME} prefix.
	 */
	private static function encrypt(string $sAlgo, string $sPrefix, SensitiveString $oPassword) : string
	{
		$sAlgo = \strtolower(\trim($sAlgo));
		if ('' === $sAlgo || 'md5crypt' === $sAlgo) {
			$sHash = \crypt((string) $oPassword, \sprintf('$1$%08x$', \crc32(\uniqid('', true))));
			if (!\str_starts_with($sHash, '$1$')) {
				throw new \RuntimeException('this PHP has no MD5 crypt support');
			}
			return $sHash;
		}
		// anything else must be a scheme the plugin knows, or we would store a password that
		// neither Dovecot nor PostfixAdmin can verify (the plugin's helper falls back to the
		// plaintext for unknown values, which is never what we want here)
		if (!\in_array($sAlgo, ['none', 'bcrypt', 'argon2i', 'argon2id', 'sha256-crypt', 'sha512-crypt'], true)) {
			throw new \RuntimeException("unsupported encryption '{$sAlgo}'");
		}
		return $sPrefix . \ChangePasswordPlugin::encrypt($sAlgo, $oPassword);
	}

	private function get(string $sKey) : string
	{
		$mValue = $this->oConfig->Get('plugin', $sKey, '');
		if (\is_array($mValue)) {
			// a SELECTION property that was never saved carries its options list: take the first
			$mValue = \reset($mValue) ?: '';
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
