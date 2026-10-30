import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router-dom'
import { confirmLink } from '../lib/api'
import { Alert, Button } from '../components/ui'
import { errorText } from './Login'

/**
 * Magic-link landing page (/confirm#<token>). The token sits in the fragment, so it never
 * reaches a server log or a Referer; confirming needs an explicit click, so a mail scanner
 * that pre-fetches the link confirms nothing.
 */
export default function Confirm() {
  const { t } = useTranslation()
  const [token] = useState(() => window.location.hash.replace(/^#/, ''))
  const [state, setState] = useState<'idle' | 'busy' | 'done' | 'error'>('idle')
  const [message, setMessage] = useState('')

  useEffect(() => {
    // drop the token from the address bar and the history entry
    if (window.location.hash) history.replaceState(null, '', window.location.pathname)
  }, [])

  async function go() {
    setState('busy')
    try {
      const res = await confirmLink(token)
      setMessage(t('confirm.done', { address: res.address, account: res.account }))
      setState('done')
    } catch (err) {
      setMessage(errorText(t, err))
      setState('error')
    }
  }

  return (
    <main className="mx-auto flex min-h-screen w-full max-w-md flex-col justify-center gap-4 px-4 py-10">
      <h1 className="text-xl font-semibold">{t('confirm.title')}</h1>
      {state === 'done' && <Alert kind="success">{message}</Alert>}
      {state === 'error' && <Alert>{message}</Alert>}
      {(state === 'idle' || state === 'busy') &&
        (token ? (
          <>
            <p className="text-sm text-slate-300">{t('confirm.body')}</p>
            <Button onClick={go} disabled={state === 'busy'} data-testid="confirm-submit">
              {t('confirm.button')}
            </Button>
          </>
        ) : (
          <Alert>{t('errors.invalid_link')}</Alert>
        ))}
      <Link to="/" className="text-sm text-blue-300 underline">
        {t('confirm.back')}
      </Link>
    </main>
  )
}
