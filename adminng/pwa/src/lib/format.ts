/**
 * Quota/byte formatting, shared by the card chips and the quota editor.
 *
 * Binary 1024 steps (the same steps the editor's unit multipliers use) and no
 * decimals: values are rounded to the nearest whole unit, so a card, an editor
 * and a log always agree on what "1 GB" means.
 */

export type QuotaUnit = 'MB' | 'GB' | 'TB'

export const QUOTA_UNITS: QuotaUnit[] = ['MB', 'GB', 'TB']

export const UNIT_BYTES: Record<QuotaUnit, number> = {
  MB: 1024 ** 2,
  GB: 1024 ** 3,
  TB: 1024 ** 4,
}

/**
 * "1 GB", "300 MB", "2 TB"… or null when there is no limit (the caller renders
 * its localized "Unlimited"). Below 1 MB the quota is meaningless, so it clamps
 * to 1 MB instead of showing a confusing "0 MB".
 */
export function formatQuota(bytes: number): string | null {
  if (!bytes || bytes <= 0) return null
  for (let i = QUOTA_UNITS.length - 1; i >= 0; i--) {
    const unit = QUOTA_UNITS[i]
    if (bytes >= UNIT_BYTES[unit]) {
      return `${Math.max(1, Math.round(bytes / UNIT_BYTES[unit]))} ${unit}`
    }
  }
  return '1 MB'
}

/** The editor prefill: the largest unit that divides the bytes exactly. */
export function quotaValueFromBytes(bytes: number): { number: number; unit: QuotaUnit } {
  if (!bytes || bytes <= 0) return { number: 0, unit: 'MB' }
  for (let i = QUOTA_UNITS.length - 1; i >= 0; i--) {
    const unit = QUOTA_UNITS[i]
    if (bytes % UNIT_BYTES[unit] === 0) return { number: bytes / UNIT_BYTES[unit], unit }
  }
  return { number: Math.max(1, Math.round(bytes / UNIT_BYTES.MB)), unit: 'MB' }
}

/** A {number, unit} pair back to bytes (what the API takes: quota_bytes). */
export function quotaToBytes(number: number, unit: QuotaUnit): number {
  return Math.max(0, Math.round(number)) * UNIT_BYTES[unit]
}
