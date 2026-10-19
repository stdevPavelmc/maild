import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api, type Device } from '../lib/api'
import { useOnline } from '../lib/online'
import { usePaged } from '../lib/usePaged'
import { ErrorBanner, SectionHeader } from '../components/kit'
import { ActionButton, ActionRow, CardGrid, CardHead, EntityCard } from '../components/cards'
import { Button } from '../components/ui/button'
import { ConfirmDelete } from '../components/ConfirmDelete'

export function DevicesPage({ password }: { password: string }) {
  const { t } = useTranslation()
  const online = useOnline()
  const pending = usePaged<Device>((cursor) => api.devices('PENDING', cursor), [])
  const approved = usePaged<Device>((cursor) => api.devices('APPROVED', cursor), [])
  const [action, setAction] = useState<{ device: Device; kind: 'APPROVE' | 'REVOKE' } | null>(null)
  const [copied, setCopied] = useState<string | null>(null)

  const refresh = async (): Promise<void> => {
    await Promise.all([pending.reload(), approved.reload()])
  }

  const card = (device: Device, kind: 'APPROVE' | 'REVOKE') => (
    <EntityCard
      key={device.device_id}
      status={device.authorization_state === 'APPROVED' ? 'active' : 'pending'}
    >
      <CardHead>
        <div className="flex min-w-0 items-start gap-2">
          <span aria-hidden="true" className="shrink-0 text-xl leading-none lg:text-base">
            🖥️
          </span>
          <div className="min-w-0">
            <p
              className="break-all font-semibold leading-snug text-slate-100 line-clamp-1"
              title={device.device_name || device.client_type || undefined}
            >
              {device.usernames.length > 0 ? device.usernames.join(', ') : t('devices.noUser')}
            </p>
            <p
              className="mt-0.5 truncate font-mono text-[11px] text-slate-400"
              title={device.device_id}
            >
              {device.device_id}
            </p>
          </div>
        </div>
        <ActionRow label={t('common.actions')}>
          <ActionButton
            glyph={copied === device.device_id ? '✓' : '📋'}
            label={t('device.copy')}
            onClick={() => {
              void navigator.clipboard.writeText(device.device_id)
              setCopied(device.device_id)
              window.setTimeout(() => setCopied(null), 1500)
            }}
          />
          <ActionButton
            glyph={kind === 'APPROVE' ? '✅' : '⛔'}
            label={kind === 'APPROVE' ? t('devices.approve') : t('devices.revoke')}
            tone={kind === 'REVOKE' ? 'danger' : 'default'}
            disabled={!online}
            onClick={() => setAction({ device, kind })}
          />
        </ActionRow>
      </CardHead>
      <p className="mt-2 text-xs text-slate-400">
        {device.device_name || device.client_type || '—'} · {t('devices.lastSeen')}:{' '}
        {new Date(device.last_seen).toLocaleString()}
        {device.last_ip ? ` · ${device.last_ip}` : ''}
      </p>
      {device.fingerprint && (
        <p className="mt-1 font-mono text-[11px] text-slate-400">
          {t('device.fingerprint')}: {device.fingerprint}
        </p>
      )}
    </EntityCard>
  )

  return (
    <div className="space-y-6">
      <SectionHeader title={t('devices.title')} />
      <ErrorBanner message={pending.error ?? approved.error} />

      <section>
        <h3 className="mb-2 text-sm font-medium text-amber-300">
          ⚠️ {t('devices.pending')} ({pending.items.length})
        </h3>
        <CardGrid>{pending.items.map((device) => card(device, 'APPROVE'))}</CardGrid>
        {pending.items.length === 0 && <p className="text-xs text-slate-400">{t('devices.none')}</p>}
        {pending.cursor && (
          <Button variant="outline" size="sm" className="mt-3" onClick={() => void pending.more()}>{t('common.page')}</Button>
        )}
      </section>

      <section>
        <h3 className="mb-2 text-sm font-medium text-slate-300">
          ✓ {t('devices.active')} ({approved.items.length})
        </h3>
        <CardGrid>{approved.items.map((device) => card(device, 'REVOKE'))}</CardGrid>
        {approved.items.length === 0 && <p className="text-xs text-slate-400">{t('devices.none')}</p>}
        {approved.cursor && (
          <Button variant="outline" size="sm" className="mt-3" onClick={() => void approved.more()}>{t('common.page')}</Button>
        )}
      </section>

      <ConfirmDelete
        open={Boolean(action)}
        title={t('confirm.title')}
        body={`${action?.kind === 'APPROVE' ? t('devices.approve') : t('devices.revoke')} ${action?.device.usernames.join(', ') || t('devices.noUser')} @ ${action?.device.device_name || action?.device.device_id || ''}?`}
        password={password}
        label={action?.kind === 'APPROVE' ? t('devices.approve') : t('devices.revoke')}
        onClose={() => setAction(null)}
        action={async (vtoken) => {
          if (action)
            await api.setDeviceState(action.device.device_id, action.kind, vtoken)
          await refresh()
        }}
      />
    </div>
  )
}
