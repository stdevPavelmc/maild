/** Destructive confirmation: password re-auth + the 5-second armed button. */

import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { ApiError, api } from '../lib/api'
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
  const [value, setValue] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const run = async (): Promise<void> => {
    setBusy(true)
    setError(null)
    try {
      const { security_validation_token } = await api.reauth(value || password)
      await action(security_validation_token)
      setValue('')
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
          <ArmedButton label={label ?? t('confirm.proceed')} onConfirm={() => void run()} disabled={busy} />
        </>
      }
    >
      <p className="text-sm text-slate-300">{body}</p>
      <p className="text-xs text-slate-500">{t('confirm.body')}</p>
      <ErrorBanner message={error} />
      <Field label={t('confirm.password')}>
        <Input type="password" autoComplete="current-password" value={value} onChange={(event) => setValue(event.target.value)} />
      </Field>
    </Modal>
  )
}
