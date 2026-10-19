# AdminNG browser harness (`pwa-test`)

Dev-only, one-shot container that runs the AdminNG PWA against the live dev stack with a
pinned Playwright + Chromium and Lighthouse. Nothing needs to be installed on the host
except Docker and a stack brought up by `./bootstrap-dev.sh`.

| File | Purpose |
|------|---------|
| `Dockerfile` | `mcr.microsoft.com/playwright:v<version>-noble` (pinned to `package-lock.json`) + static Docker CLI |
| `entrypoint.sh` | mode dispatcher: waits for the stack, starts the localhost tunnel, runs the mode |
| `proxy.mjs` | `localhost:8083` → `adminng:80` TCP tunnel (keeps a secure context for the service worker) |
| `run.sh` | host wrapper: uid/gid mapping, `ldata/e2e`, `compose run --rm --build` |
| `tests/` | `flows` (CRUD + offline + i18n), `installable`, `superadmin` (TOTP + devices panel), `visual`, `a11y` |
| `lib/` | `env` (paths + CLI), `login` (shared flows), `totp` (RFC 6238 codes) |

```bash
./adminng/pwa-test/run.sh verify        # the gate: flows + installability + Lighthouse
./adminng/pwa-test/run.sh flows         # one spec (flows | installable | superadmin)
./adminng/pwa-test/run.sh visual        # PNGs in ldata/e2e/screens
./adminng/pwa-test/run.sh a11y          # axe JSON in ldata/e2e/a11y
./adminng/pwa-test/run.sh lighthouse
./adminng/pwa-test/run.sh shell         # bash inside the image
./adminng/pwa-test/run.sh flows --debug # any Playwright flag passes through
```

Notes:

- **Device approval is out of band.** The suite signs in to register the browser, reads the
  pending UUID from the screen and runs `adminng.py --approve-device <id>`
  inside the `api` container through the mounted docker socket. Deleting the socket mount
  breaks only that step; `superadmin` exercises the UI path instead (devices panel, re-auth +
  5 s armed authorize).
- **Secure context.** Service workers and installability need a trustworthy origin. Inside
  the Compose network `http://adminng` is not one, so `entrypoint.sh` tunnels
  `http://localhost:8083` to it; the tests keep the same base URL as a host run.
- Artifacts are host-owned (`run.sh` passes the invoking uid/gid) and live in
  `ldata/e2e/` (git-ignored): `report/` (HTML), `results/` (traces/videos on failure),
  `screens/`, `a11y/`, `lighthouse.report.{json,html}`.
- `a11y` and `visual` run with tracing **off** (`entrypoint.sh --trace=off`): they are pure
  artifact-review modes and each opens a second browser context for the superadmin step,
  where a Playwright 1.64 trace-teardown bug otherwise fails an otherwise-green run. Pass
  `--trace=on` to override when debugging.
- The image is rebuilt from the working tree on every run (cached); set
  `PWA_TEST_NO_BUILD=1` to reuse it.
