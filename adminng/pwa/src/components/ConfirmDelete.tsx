/** Destructive confirmation: password re-auth + the 5-second armed button. */

import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { ApiError, api } from '../lib/api'
import { getPlatformCredential } from '../lib/webauthn'
import { useOnline } from '../lib/online'
import { ArmedButton, ErrorBanner, Field, Input, Modal } from './kit'
import { Button } from './ui/button'

export function ConfirmDelete({
  open,
  title,
  body,
  password,
  onClose,
  action,
  label,
}: {
  open: boolean
  title: string
  body: string
  password: string
  onClose: () => void
  action: (vtoken: string) => Promise<void>
  label?: string
}) {
  const { t } = useTranslation()
  const online = useOnline()
  const [value, setValue] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [useBiometric, setUseBiometric] = useState(false)

  useEffect(() => {
    if (open) {
      setValue('')
      setError(null)
      setUseBiometric(false)
    }
  }, [open])

  const run = async (): Promise<void> => {
    setBusy(true)
    setError(null)
    try {
      let security_validation_token: string
      if (useBiometric) {
        const options = await api.webauthnReauthOptions()
        const credential = await getPlatformCredential(options.public_key)
        const result = await api.webauthnReauthVerify(options.challenge_id, credential)
        security_validation_token = result.security_validation_token
      } else {
        const result = await api.reauth(value || password)
        security_validation_token = result.security_validation_token
      }
      await action(security_validation_token)
      setValue('')
      setUseBiometric(false)
      onClose()
    } catch (err) {
      setError(err instanceof ApiError ? `${err.code}: ${err.message}` : t('login.network'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <Modal
      open={open}
      title={title}
      onClose={onClose}
      footer={
        <>
          <Button variant="outline" onClick={onClose}>{t('common.cancel')}</Button>
          <ArmedButton label={label ?? t('confirm.proceed')} onConfirm={() => void run()} disabled={busy || !online} />
        </>
      }
    >
      <p className="text-sm text-slate-300">{body}</p>
      <p className="text-xs text-slate-400">{t('confirm.body')}</p>
      <ErrorBanner message={error} />
      <div className="flex flex-wrap gap-2">
        <Button
          type="button"
          variant={useBiometric ? 'default' : 'outline'}
          onClick={() => setUseBiometric(true)}
        >
          {t('confirm.biometric')}
        </Button>
        <Button
          type="button"
          variant={!useBiometric ? 'default' : 'outline'}
          onClick={() => setUseBiometric(false)}
        >
          {t('confirm.passwordMethod')}
        </Button>
      </div>
      {!useBiometric && (
        <Field label={t('confirm.password')}>
          <Input type="password" autoComplete="current-password" value={value} onChange={(event) => setValue(event.target.value)} />
        </Field>
      )}
    </Modal>
  )
}
