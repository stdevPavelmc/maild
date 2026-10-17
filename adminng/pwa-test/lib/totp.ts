/**
 * Minimal RFC 6238 TOTP (SHA-1, 6 digits, 30 s) for the browser suite.
 *
 * The superadmin flow has to enroll an authenticator and then present the code,
 * exactly like a phone would; pulling a dependency for ~20 lines is not worth it.
 */

import { createHmac } from 'node:crypto'

const ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'

/** Decode an RFC 4648 base32 secret (the format the API returns). */
export function decodeBase32(input: string): Buffer {
  const clean = input.replace(/=+$/, '').toUpperCase().replace(/\s+/g, '')
  let bits = 0
  let value = 0
  const bytes: number[] = []

  for (const char of clean) {
    const index = ALPHABET.indexOf(char)
    if (index === -1) throw new Error(`invalid base32 character: ${char}`)
    value = (value << 5) | index
    bits += 5
    if (bits >= 8) {
      bytes.push((value >>> (bits - 8)) & 0xff)
      bits -= 8
    }
  }
  return Buffer.from(bytes)
}

/** Current code for a secret; `at` is milliseconds since the epoch. */
export function totp(secret: string, at: number = Date.now(), digits = 6, period = 30): string {
  const counter = Math.floor(at / 1000 / period)
  const message = Buffer.alloc(8)
  message.writeBigUInt64BE(BigInt(counter))

  const digest = createHmac('sha1', decodeBase32(secret)).update(message).digest()
  const offset = digest[digest.length - 1] & 0x0f
  const binary =
    ((digest[offset] & 0x7f) << 24) |
    (digest[offset + 1] << 16) |
    (digest[offset + 2] << 8) |
    digest[offset + 3]

  return String(binary % 10 ** digits).padStart(digits, '0')
}
