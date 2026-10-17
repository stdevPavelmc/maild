#!/usr/bin/env node
/**
 * i18n completeness gate (plan.md Phase 3, task 8).
 *
 * Compares `src/i18n/en.json` (source language) with `src/i18n/es.json` and fails
 * on anything that would surface as a raw key or an untranslated placeholder in
 * the UI:
 *
 *   - a key present in only one catalogue;
 *   - an empty translation;
 *   - `{{placeholders}}` that differ between the two languages for the same key.
 *
 * Identical EN/ES values are reported as warnings (a few are legitimate, e.g.
 * "Ctrl/⌘ K"); they never fail the run. No dependencies: runs on plain Node.
 */

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
const dir = join(here, '..', 'src', 'i18n')

/** Keys that are intentionally identical in both languages. */
const SAME_BY_DESIGN = new Set(['app.title', 'nav.admin', 'search.hint', 'common.no'])

function flatten(node, prefix = '', out = new Map()) {
  for (const [key, value] of Object.entries(node)) {
    const path = prefix ? `${prefix}.${key}` : key
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      flatten(value, path, out)
    } else if (typeof value === 'string') {
      out.set(path, value)
    } else {
      throw new Error(`${path}: expected a string, got ${typeof value}`)
    }
  }
  return out
}

function placeholders(value) {
  return new Set([...value.matchAll(/{{\s*([\w.]+)\s*}}/g)].map((match) => match[1]))
}

function load(language) {
  return flatten(JSON.parse(readFileSync(join(dir, `${language}.json`), 'utf8')))
}

const en = load('en')
const es = load('es')
const errors = []
const warnings = []

for (const key of en.keys()) {
  if (!es.has(key)) errors.push(`missing in es: ${key}`)
}
for (const key of es.keys()) {
  if (!en.has(key)) errors.push(`not in en (source): ${key}`)
}

for (const [key, value] of en) {
  if (!value.trim()) errors.push(`empty en value: ${key}`)
  const translated = es.get(key)
  if (translated === undefined) continue
  if (!translated.trim()) errors.push(`empty es value: ${key}`)

  const source = placeholders(value)
  const target = placeholders(translated)
  for (const name of source) {
    if (!target.has(name)) errors.push(`placeholder {{${name}}} missing in es: ${key}`)
  }
  for (const name of target) {
    if (!source.has(name)) errors.push(`placeholder {{${name}}} only in es: ${key}`)
  }

  if (value === translated && !SAME_BY_DESIGN.has(key)) {
    warnings.push(`identical en/es value: ${key} ("${value}")`)
  }
}

for (const warning of warnings) console.warn(`i18n: warning: ${warning}`)

if (errors.length > 0) {
  for (const error of errors) console.error(`i18n: error: ${error}`)
  console.error(`\ni18n: ${errors.length} problem(s) — the catalogues are out of sync`)
  process.exit(1)
}

console.log(`i18n: OK — ${en.size} keys aligned between en and es (${warnings.length} warning(s))`)
