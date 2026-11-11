# Database backups: encryption and restore

The `cron` container dumps the four MailD databases every day at **08:00 UTC** into
`/backups/db` (the `db_backups` volume in production, `ldata/backups` in dev), keeps them
**15 days** and mails the result to `MAIL_ADMIN_USER@DEFAULT_DOMAIN`:

| Archive | Database | Holds |
|---------|----------|-------|
| `maild_backup_<date>.sql.gz` | catalogue (`POSTGRES_DB`, `mailddb`) | domains, mailboxes (password hashes), aliases, admins |
| `maild_adminng_<date>.sql.gz` | AdminNG (`ADMINNG_DB`, `adminng`) | devices, sessions, TOTP seeds (encrypted), audit trail |
| `maild_mcp_<date>.sql.gz` | MailD MCP (`MCP_DB`, `mcp`) | accounts, token hashes, OAuth clients, settings |
| `maild_roundcube_<date>.sql.gz` | Roundcube webmail, `mua` (`ROUNDCUBE_DB`, `roundcube`) | users' identities, signatures, preferences, personal contacts, canned responses |

The directory is root-only (`0700`, archives `0600`). The archives still hold password
hashes and the audit trail, and copies tend to end up on less trusted storage. **Encrypt them**
unless they never leave the server.

## 1. Encryption (optional)

Encryption uses [age](https://age-encryption.org) with a key pair:

- the **public key** (`age1…`) goes into the server's `.env`. It can only *encrypt*, so it is
  not a secret.
- the **private key** (`AGE-SECRET-KEY-1…`) can *decrypt*. It **never goes on the mail
  server**: keep it offline (password manager, an encrypted USB stick, a safe). Anyone who
  has it can read every backup, and **if you lose it, every encrypted backup is unreadable.**

If `BACKUP_AGE_RECIPIENT` is not set, the backups are written exactly as before: plain gzip.

### 1.1 Create the key pair

On **your workstation** (not on the server), install age (`apt install age`,
`brew install age`, `winget install FiloSottile.age`, or the
[release binaries](https://github.com/FiloSottile/age/releases)) and run:

```sh
age-keygen -o maild-backup.key
# Public key: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
```

`maild-backup.key` is the private key, the printed `age1…` string is the public one (it can
be printed again with `age-keygen -y maild-backup.key`). Store `maild-backup.key` and **at
least one copy** somewhere safe and offline, then delete it from the workstation if that is
not one of those places.

No age at hand? The cron image ships it — generate the pair there and **move the private key
off the server right away**:

```sh
docker compose exec cron age-keygen        # prints the public key, then the private key on stdout
```

Copy both from the terminal and keep the private one offline. Nothing is written to disk.

### 1.2 Configure the server

Add the public key to the operator env file (`.env`) and recreate `cron`:

```sh
BACKUP_AGE_RECIPIENT=age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
```

```sh
docker compose -f docker-compose.yml up -d cron
```

Several people can each hold their own key: list their public keys comma-separated, and any
one of the matching private keys decrypts. An SSH public key (`ssh-ed25519 AAAA…`) also works
as a recipient; its SSH private key then decrypts.

```sh
BACKUP_AGE_RECIPIENT=age1first…,age1second…
```

### 1.3 Check it

Run the job once by hand and look at the result:

```sh
docker compose exec cron /scripts/backup_db.sh
docker compose exec cron /scripts/restore_db.sh --list
```

The new archives end in `.sql.gz.age` and are listed as `encrypted`. The notification mail
shows `Encryption: on (1 recipient(s), age)`.

Every dump is checked in plain form first (gzip integrity, complete `pg_dump` output). Only
then is it encrypted and the plain copy removed. If the public key is malformed or the
encryption fails, the job **keeps the plain archive** (a backup is worth more than its
encryption) and the mail arrives as `[CRITICAL] … FAILED` with the reason. Fix the key and
the next run is encrypted again.

### 1.4 Test the private key now, not on the day you need it

Copy one encrypted archive to your workstation and decrypt it there:

```sh
docker compose cp cron:/backups/db/maild_backup_20261110_080000.sql.gz.age .
age -d -i maild-backup.key maild_backup_20261110_080000.sql.gz.age | zcat | tail -n 2
# -- PostgreSQL database dump complete
```

### 1.5 Rotating the key

Generate a new pair, put the new public key in `BACKUP_AGE_RECIPIENT`, and recreate `cron`.
Archives already written stay encrypted to the **old** key: keep the old private key until
the last of them has expired (15 days).

## 2. Restore

`/scripts/restore_db.sh` (in the `cron` container) restores one archive into its database.

```sh
docker compose exec cron /scripts/restore_db.sh --list
```

```
ARCHIVE                                              FORMAT          BYTES  DATE
maild_backup_20261110_080000.sql.gz.age              encrypted        5667  2026-11-10 08:00
maild_adminng_20261110_080000.sql.gz.age             encrypted       11882  2026-11-10 08:00
maild_backup_20261101_080000.sql.gz                  plain            5467  2026-11-01 08:00
```

### 2.1 What it does

1. It checks the **file's content**, not its name, to tell whether the archive is plain or
   encrypted. A plain archive is used as it is. For an encrypted one it **asks for the private
   key** (paste it, then an empty line; it is not echoed), or takes it from `--identity FILE`.
   The pasted key goes to a temporary `0600` file that is deleted when the script ends.
2. It decrypts and decompresses the archive and checks that it is a complete `pg_dump`.
   **Nothing is changed before this check passes.**
3. It works out the target database from the file name (`maild_backup_` → catalogue,
   `maild_adminng_` → AdminNG, `maild_mcp_` → MCP, `maild_roundcube_` → Roundcube);
   `--database NAME` overrides that.
4. It refuses to run while other clients are connected to that database (see 2.2), and asks
   you to **type the database name** to confirm (`--yes` skips the question).
5. It writes a **safety dump** of the current database (`pre-restore_<db>_<date>.sql.gz`,
   encrypted too when `BACKUP_AGE_RECIPIENT` is set, same 15-day retention). If the restore
   was a mistake, restore that file the same way.
6. It replaces the database's tables in **one transaction**, as the database's owner. Any
   error rolls the whole thing back and leaves the database exactly as it was.

### 2.2 Step by step

Stop the services that write to the database you are restoring:

| Restoring | Stop first |
|-----------|-----------|
| catalogue (`maild_backup_…`) | `docker compose stop api mta mda mua amavis mcp` |
| AdminNG (`maild_adminng_…`) | `docker compose stop api` |
| MCP (`maild_mcp_…`) | `docker compose stop mcp` |
| Roundcube (`maild_roundcube_…`) | `docker compose stop mua` |

Run the restore. `docker compose exec` gives it a terminal, so it can ask for the key and the
confirmation:

```sh
docker compose exec cron /scripts/restore_db.sh maild_backup_20261110_080000.sql.gz.age
# restore: maild_backup_20261110_080000.sql.gz.age is ENCRYPTED (age): the private key is needed
# Paste the private key (the AGE-SECRET-KEY-1… line, or a whole ssh private key),
# then an empty line. It is not echoed and is deleted when this script ends.
# restore: decrypted
# restore: valid dump: 14 tables → database 'mailddb' (owner maild)
# Type the database name to confirm: mailddb
# restore: safety dump of the current 'mailddb': pre-restore_mailddb_20261110_101500.sql.gz.age
# restore: OK: 'mailddb' restored from maild_backup_20261110_080000.sql.gz.age
```

After a **catalogue** restore, restart `db` first: it re-applies the MCP role's catalogue
permissions, which a dump does not carry. Then start everything:

```sh
docker compose restart db
docker compose up -d
```

For AdminNG or the MCP, `docker compose up -d` is enough.

### 2.3 Options

| Option | Use |
|--------|-----|
| `--identity FILE` | private key file instead of pasting (path inside the container, e.g. copied in with `docker compose cp`; delete it afterwards) |
| `--database NAME` | restore into another database than the file name implies |
| `--yes` | no confirmation question (scripts) |
| `--force` | restore while clients are still connected. The swap stays atomic, but writes made since the dump are lost either way; stopping the writers is safer |
| `--no-safety-dump` | skip the safety dump (e.g. the database is broken and cannot be dumped) |
| `--list` | list the archives and whether each is encrypted |

### 2.4 Restoring an archive from elsewhere

Copy it into the backup directory, then restore it by name:

```sh
docker compose cp maild_backup_20261110_080000.sql.gz.age cron:/backups/db/
docker compose exec cron /scripts/restore_db.sh maild_backup_20261110_080000.sql.gz.age
```

With a renamed file the target cannot be guessed from the name: pass
`--database mailddb|adminng|mcp|roundcube`.

### 2.5 Without the script

The archives are standard files: `age -d -i maild-backup.key FILE.age > FILE.sql.gz`, then
`zcat FILE.sql.gz | psql …`. The dumps are plain SQL taken with `--no-owner --no-acl`, so
apply them to an **empty** `public` schema, connected as the database's owner.

## 3. Copying backups off the server

`/backups/db` is root-only. Copy the archives out with `docker compose cp`, or as root from
the volume (`docker volume inspect <project>_db_backups` shows where it lives). Encrypted archives
can go to any storage. Plain ones need the same protection as the server itself.
