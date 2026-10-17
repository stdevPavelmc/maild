import i18n from 'i18next'
import LanguageDetector from 'i18next-browser-languagedetector'
import { initReactI18next } from 'react-i18next'

// English is the source language; Spanish ships complete from day one
// (technical-draft §6.1). Detection order: browser language, then <html lang>.
const resources = {
  en: {
    translation: {
      app: {
        title: 'MailD AdminNG',
        subtitle: 'PWA-first mailserver administration',
      },
      health: {
        checking: 'Checking the API…',
        ok: 'API reachable',
        fail: 'API unreachable',
        database: 'Database',
      },
      language: 'Language',
      phase0: 'Scaffolding build — the admin screens land in later phases.',
    },
  },
  es: {
    translation: {
      app: {
        title: 'MailD AdminNG',
        subtitle: 'Administración del servidor de correo, PWA primero',
      },
      health: {
        checking: 'Comprobando la API…',
        ok: 'API disponible',
        fail: 'API no disponible',
        database: 'Base de datos',
      },
      language: 'Idioma',
      phase0: 'Compilación de andamiaje: las pantallas de administración llegan en fases posteriores.',
    },
  },
} as const

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
