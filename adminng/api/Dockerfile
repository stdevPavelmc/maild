FROM python:3.14-slim-trixie

# AdminNG API — FastAPI backend for the next-generation MailD admin interface.
#
# Reads/writes the PostfixAdmin catalogue (mailddb) exactly like PostfixAdmin does
# and owns its own state (devices, sessions, TOTP credentials, audit trail) in the
# ADMINNG_DB database. The catalogue schema belongs to the `admin` container
# (public/upgrade.php); the adminng schema is migrated by this image's entrypoint.
# The vmail volume is mounted READ-ONLY: quota usage is read from the Maildir++
# .maildirsize files, never written.

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app

# --- MailD default configuration (new env schema) --------------------------------
# Defaults live HERE; a same-named variable in the operator env file (env.dev /
# .env) always wins. POSTGRES_PASSWORD is NEVER baked — it comes from the operator
# file only. Full matrix: .agents/services/configuration.md.
ENV POSTGRES_HOST=db \
    POSTGRES_PORT=5432 \
    POSTGRES_DB=mailddb \
    POSTGRES_USER=maild \
    ADMINNG_DB=adminng \
    ADMINNG_API_PORT=8080 \
    ADMINNG_API_DOCS=no \
    PASSWORD_SCHEME=argon2id \
    ADMINNG_ACCESS_TTL=600 \
    ADMINNG_REFRESH_IDLE_TTL=900 \
    ADMINNG_REMEMBER_TTL=86400 \
    ADMINNG_REAUTH_TTL=30 \
    ADMINNG_AUTO_APPROVE_FIRST=no \
    ADMINNG_PENDING_TTL_DAYS=3 \
    ADMINNG_TOTP_REQUIRED=superadmin \
    ADMINNG_WEBAUTHN_RP_ID=localhost \
    ADMINNG_WEBAUTHN_ORIGINS=http://localhost:8083,https://localhost:8084 \
    ADMINNG_WEBAUTHN_CHALLENGE_TTL=300 \
    ADMINNG_SEARCH_LIMIT=20 \
    ADMINNG_QUOTA_CACHE_TTL=300 \
    VMAIL_ROOT=/home/vmail

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/
COPY migrations/ ./migrations/
COPY tests/ ./tests/
COPY adminng.py entrypoint.sh ./

# The API reads the Maildir++ .maildirsize accounting straight from the vmail
# volume. Maildirs are 0700 owned by vmail (uid/gid 5000, pinned in mda/Dockerfile),
# so the process runs as that uid; the volume is additionally mounted READ-ONLY in
# every compose file, so the API can read sizes but never write mail.
RUN chmod +x /app/entrypoint.sh /app/adminng.py \
    && ln -s /app/adminng.py /usr/local/bin/adminng.py

ENV HOME=/tmp
USER 5000:5000

EXPOSE 8080

HEALTHCHECK --interval=1m --timeout=5s --start-period=20s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=3).status == 200 else 1)" || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]

# OCI labels (kept last; the pre-commit hook rewrites the created date)
LABEL org.opencontainers.image.title="MailD AdminNG API" \
      org.opencontainers.image.description="MailD AdminNG backend: device-trust admin API over the PostfixAdmin catalogue, PWA-first" \
      org.opencontainers.image.authors="Pavel Milanes <pavelmc@gmail.com>" \
      org.opencontainers.image.url="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.source="https://github.com/stdevPavelmc/maild" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.created="2026-10-19"
