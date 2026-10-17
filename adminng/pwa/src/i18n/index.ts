import i18n from 'i18next'
import LanguageDetector from 'i18next-browser-languagedetector'
import { initReactI18next } from 'react-i18next'

import en from './en.json'
import es from './es.json'

// English is the source language; Spanish ships complete from day one
// (technical-draft §6.1). Detection order: stored choice, browser, <html lang>.
// The catalogues are plain JSON so `scripts/check-i18n.mjs` can diff them in CI
// without a bundler (`npm run i18n:check`, part of `npm run build`).
const resources = {
  en: { translation: en },
  es: { translation: es },
}

void i18n
  .use(LanguageDetector)
  .use(initReactI18next)
  .init({
    resources,
    fallbackLng: 'en',
    supportedLngs: ['en', 'es'],
    interpolation: { escapeValue: false },
    detection: {
      order: ['localStorage', 'navigator', 'htmlTag'],
      caches: ['localStorage'],
    },
  })

export default i18n
