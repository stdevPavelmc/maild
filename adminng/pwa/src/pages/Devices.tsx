import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api, type Device } from '../lib/api'
import { usePaged } from '../lib/usePaged'
import { Badge, ErrorBanner, SectionHeader } from '../components/kit'
import { Button } from '../components/ui/button'
import { ConfirmDelete } from '../components/ConfirmDelete'

export function DevicesPage({ password }: { password: string }) {
  const { t } = useTranslation()
  const pending = usePaged<Device>(() => api.devices('PENDING'), [])
  const approved = usePaged<Device>(() => api.devices('APPROVED'), [])
  const [action, setAction] = useState<{ device: Device; kind: 'APPROVE' | 'REVOKE' } | null>(null)
  const [copied, setCopied] = useState<string | null>(null)

  const refresh = async (): Promise<void> => {
    await Promise.all([pending.reload(), approved.reload()])
  }

  const row = (device: Device, kind: 'APPROVE' | 'REVOKE') => (
    <li key={device.device_id} className="flex flex-wrap items-center justify-between gap-2 border-t border-slate-800 py-2 text-sm">
      <div className="min-w-0">
        <p className="truncate">
          {device.device_name || device.client_type} <Badge tone={device.authorization_state === 'APPROVED' ? 'green' : 'amber'}>{device.authorization_state}</Badge>
        </p>
        <p className="truncate font-mono text-[11px] text-slate-500">{device.device_id}</p>
        <p className="text-xs text-slate-400">
          {t('devices.user')}: {device.associated_user || '—'} · {t('devices.lastSeen')}: {new Date(device.last_seen).toLocaleString()}
          {device.last_ip ? ` · ${device.last_ip}` : ''}
        </p>
      </div>
      <div className="flex gap-2">
        <Button
          variant="outline"
          size="sm"
          onClick={() => {
            void navigator.clipboard.writeText(device.device_id)
            setCopied(device.device_id)
            window.setTimeout(() => setCopied(null), 1500)
          }}
        >
          {copied === device.device_id ? '✓' : t('device.copy')}
        </Button>
        <Button
          variant="outline"
          size="sm"
          className={kind === 'REVOKE' ? 'border-red-800 text-red-300' : ''}
          onClick={() => setAction({ device, kind })}
        >
          {kind === 'APPROVE' ? t('devices.approve') : t('devices.revoke')}
        </Button>
      </div>
    </li>
  )

  return (
    <div className="space-y-6">
      <SectionHeader title={t('devices.title')} />
      <ErrorBanner message={pending.error ?? approved.error} />

      <section>
        <h3 className="mb-2 text-sm font-medium text-amber-300">
          ⚠️ {t('devices.pending')} ({pending.items.length})
        </h3>
        <ul>{pending.items.map((device) => row(device, 'APPROVE'))}</ul>
        {pending.items.length === 0 && <p className="text-xs text-slate-500">{t('devices.none')}</p>}
      </section>

      <section>
        <h3 className="mb-2 text-sm font-medium text-slate-300">
          ✓ {t('devices.active')} ({approved.items.length})
        </h3>
        <ul>{approved.items.map((device) => row(device, 'REVOKE'))}</ul>
        {approved.items.length === 0 && <p className="text-xs text-slate-500">{t('devices.none')}</p>}
      </section>

      <ConfirmDelete
        open={Boolean(action)}
        title={t('confirm.title')}
        body={`${action?.kind === 'APPROVE' ? t('devices.approve') : t('devices.revoke')} ${action?.device.device_name ?? action?.device.device_id ?? ''}?`}
        password={password}
        label={action?.kind === 'APPROVE' ? t('devices.approve') : t('devices.revoke')}
        onClose={() => setAction(null)}
        action={async (vtoken) => {
          if (action) await api.setDeviceState(action.device.device_id, action.kind, vtoken)
          await refresh()
        }}
      />
    </div>
  )
}
