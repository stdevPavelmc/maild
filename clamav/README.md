# Antivirus Engine (ClamAV) for MailD

The `clamav` container runs ClamAV daemon (`clamd`) and FreshClam signature updater,
providing high-throughput antivirus scanning for the Amavis content filter.

## Overview

- **Service daemon:** Runs `clamd` listening on TCP port 3310.
- **Amavis integration:** Amavis requests scans using `CONTSCAN <path>` over TCP port 3310.
  Clamd directly inspects unpacked message files in the shared `/var/lib/amavis` volume.
- **Permissions:** To access Amavis temporary files (`/var/lib/amavis/tmp`), the container
  user `clamav` is joined to group `amavis` (`AMAVIS_GID=994`).
- **Signature updates:** FreshClam downloads and maintains official virus signature databases
  in `/var/lib/clamav` (~230 MB on first boot).
- **Isolation:** ClamAV does not access the PostgreSQL database and does not receive the
  operator `.env` file via `env_file`. Knobs are passed strictly as explicit environment entries.

## Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 3310 | TCP      | ClamAV daemon listener (used internally by Amavis; published in dev for debugging) |

## Volumes

| Container Path | Host / Source | Description |
|----------------|---------------|-------------|
| `/var/lib/clamav` | `ldata/clamav` | ClamAV signature database (`main.cvd`, `daily.cvd`, `bytecode.cvd`) |
| `/var/lib/amavis` | `ldata/amavis` (or named volume `amavis`) | Shared mount for Amavis temporary files and extracted message parts |

## Variables

ClamAV requires no catalogue access or mandatory credentials. All settings are optional overrides:

- `ALTERNATE_MIRROR`: Custom or local signature mirror URL for FreshClam (e.g. `clamav.internal.lan` or `clamav.ddns.net`). Crucial on restricted or air-gapped networks.
- `CLAMAV_DEBUG=1`: Enables verbose logging in `freshclam` and `clamd`.

## Operational commands

```bash
# Health check
docker compose exec clamav /check.sh

# Probe ClamAV TCP port
nc -z localhost 3310

# View ClamAV logs
docker compose logs -f clamav

# Check signature database freshness inside container
docker compose exec clamav sigtool -i /var/lib/clamav/daily.cvd

# Run manual freshclam update
docker compose exec clamav freshclam
```

> [!WARNING]
> Never change the container hostname from `clamav` — the Amavis content filter relies on `clamav:3310` to scan mail attachments.

# Probe ClamAV TCP port
nc -z localhost 3310

# View ClamAV logs
docker compose logs -f clamav

# Check signature database freshness inside container
docker compose exec clamav sigtool -i /var/lib/clamav/daily.cvd

# Run manual freshclam update
docker compose exec clamav freshclam
```

> [!WARNING]
> Never change the container hostname from `clamav` — the Amavis content filter relies on `clamav:3310` to scan mail attachments.

