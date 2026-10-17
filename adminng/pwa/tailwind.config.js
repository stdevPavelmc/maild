/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        // MailD palette — dark slate shell, blue accents (quota bars go
        // blue -> orange -> red as usage rises, see technical-draft §6.2).
        brand: {
          DEFAULT: '#1d4ed8',
          dark: '#1e3a8a',
        },
      },
    },
  },
  plugins: [],
}
