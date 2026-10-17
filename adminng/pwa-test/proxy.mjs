#!/usr/bin/env node
/**
 * Localhost tunnel for the containerized browser suite.
 *
 * Service workers, the install prompt and the offline shell require a *secure
 * context*; `http://adminng` on the Compose network is not one. Chromium treats
 * `http://localhost:<port>` as trustworthy, so the entrypoint forwards
 * 127.0.0.1:E2E_PROXY_PORT to the `adminng` nginx and the tests keep using the
 * exact same base URL as the host-run suite (`http://localhost:8083`).
 *
 * Plain TCP: the suite speaks HTTP/1.1 only, no TLS is involved and the nginx
 * reverse proxy resolves the API inside the network.
 */

import net from 'node:net'

const port = Number(process.env.E2E_PROXY_PORT ?? 8083)
const targetHost = process.env.E2E_UPSTREAM_HOST ?? 'adminng'
const targetPort = Number(process.env.E2E_UPSTREAM_PORT ?? 80)

const server = net.createServer((client) => {
  const upstream = net.connect({ host: targetHost, port: targetPort })
  client.pipe(upstream).pipe(client)

  const teardown = () => {
    client.destroy()
    upstream.destroy()
  }
  client.on('error', teardown)
  upstream.on('error', teardown)
  client.on('close', teardown)
  upstream.on('close', teardown)
})

// No host argument: Node binds the dual-stack wildcard, so both 127.0.0.1 and
// ::1 (Chromium resolves `localhost` to both) reach the tunnel.
server.listen(port, () => {
  console.log(`pwa-test: tunnel localhost:${port} -> ${targetHost}:${targetPort}`)
})

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => server.close(() => process.exit(0)))
}
