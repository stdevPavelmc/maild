import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api, ApiError, type Admin, type Domain } from '../lib/api'
import { useOnline } from '../lib/online'
import { usePaged } from '../lib/usePaged'
import { Empty, ErrorBanner, Field, Input, Modal, SectionHeader, Toggle } from '../components/kit'
import {
  ActionButton,
  ActionRow,
  Address,
  CardGrid,
  CardHead,
  EntityCard,
  MetaChip,
  MetaRow,
  StatusMark,
} from '../components/cards'
import { Button } from '../components/ui/button'
import { ConfirmDelete } from '../components/ConfirmDelete'

export function AdminsPage({ password }: { password: string }) {
  const { t } = useTranslation()
  const online = useOnline()
  const [openNew, setOpenNew] = useState(false)
  const [username, setUsername] = useState('')
  const [newPassword, setNewPassword] = useState('')
  const [superadmin, setSuperadmin] = useState(false)
  const [domains, setDomains] = useState<string[]>([])
  const [allDomains, setAllDomains] = useState<Domain[]>([])
  const [error, setError] = useState<string | null>(null)
  const [deleting, setDeleting] = useState<Admin | null>(null)

  const list = usePaged<Admin>((cursor) => api.listAdmins(cursor), [])

  useEffect(() => {
    api.listDomains().then((page) => setAllDomains(page.items)).catch(() => setAllDomains([]))
  }, [])

  const create = async (): Promise<void> => {
    setError(null)
    try {
      await api.createAdmin({ username, password: newPassword, superadmin, domains })
      setOpenNew(false)
      setUsername('')
      setNewPassword('')
      setSuperadmin(false)
      setDomains([])
      await list.reload()
    } catch (err) {
      setError(err instanceof ApiError ? `${err.code}: ${err.message}` : t('login.network'))
    }
  }

  return (
    <div className="space-y-4">
      <SectionHeader
        title={t('admins.title')}
        action={
          <Button disabled={!online} onClick={() => setOpenNew(true)}>{t('admins.new')}</Button>
        }
      />
      <ErrorBanner message={list.error} />
      <CardGrid>
        {list.items.map((admin) => (
          <EntityCard key={admin.username} status={admin.active ? 'active' : 'inactive'}>
            <CardHead>
              <div className="flex min-w-0 items-start gap-2">
                <StatusMark active={admin.active} />
                <Address address={admin.username} />
              </div>
              <ActionRow label={t('common.actions')}>
                <ActionButton
                  glyph={admin.active ? '⏸' : '▶'}
                  label={admin.active ? t('mailboxes.suspend') : t('mailboxes.activate')}
                  disabled={!online}
                  onClick={() => {
                    void api
                      .updateAdmin(admin.username, { active: !admin.active })
                      .then(() => list.reload())
                  }}
                />
                <ActionButton
                  glyph="❌"
                  label={t('common.delete')}
                  tone="danger"
                  disabled={!online}
                  onClick={() => setDeleting(admin)}
                />
              </ActionRow>
            </CardHead>
            <MetaRow>
              {admin.superadmin ? (
                <MetaChip icon="👑" title={t('admins.superadmin')}>
                  {t('admins.superadminShort')}
                </MetaChip>
              ) : (
                <>
                  {admin.domains.slice(0, 3).map((domain) => (
                    <MetaChip key={domain} icon="🌐" title={t('admins.domains')}>
                      {domain}
                    </MetaChip>
                  ))}
                  {admin.domains.length > 3 && (
                    <MetaChip icon="🌐" title={admin.domains.join(', ')}>
                      {t('common.more', { count: admin.domains.length - 3 })}
                    </MetaChip>
                  )}
                  {admin.domains.length === 0 && (
                    <MetaChip icon="🌐" title={t('admins.domains')}>—</MetaChip>
                  )}
                </>
              )}
            </MetaRow>
          </EntityCard>
        ))}
      </CardGrid>
      {!list.loading && list.items.length === 0 && <Empty text={t('common.empty')} />}
      {list.cursor && (
        <Button variant="outline" onClick={() => void list.more()}>{t('common.page')}</Button>
      )}

      <Modal
        open={openNew}
        title={t('admins.new')}
        onClose={() => setOpenNew(false)}
        footer={
          <>
            <Button variant="outline" onClick={() => setOpenNew(false)}>{t('common.cancel')}</Button>
            <Button disabled={!online} onClick={() => void create()}>{t('admins.create')}</Button>
          </>
        }
      >
        <ErrorBanner message={error} />
        <Field label={t('login.username')}>
          <Input value={username} onChange={(event) => setUsername(event.target.value)} />
        </Field>
        <Field label={t('mailboxes.password')}>
          <Input
            type="password"
            value={newPassword}
            onChange={(event) => setNewPassword(event.target.value)}
          />
        </Field>
        <Toggle checked={superadmin} label={t('admins.superadmin')} disabled={!online} onChange={setSuperadmin} />
        {!superadmin && (
          <div className="space-y-1 rounded border border-slate-800 p-3">
            <p className="text-xs uppercase tracking-wide text-slate-400">{t('admins.domains')}</p>
            {allDomains.map((domain) => (
              <label key={domain.domain} className="flex items-center gap-2 text-sm text-slate-300">
                <input
                  type="checkbox"
                  checked={domains.includes(domain.domain)}
                  onChange={(event) =>
                    setDomains((current) =>
                      event.target.checked
                        ? [...current, domain.domain]
                        : current.filter((item) => item !== domain.domain),
                    )
                  }
                />
                {domain.domain}
              </label>
            ))}
          </div>
        )}
      </Modal>

      <ConfirmDelete
        open={Boolean(deleting)}
        title={t('confirm.title')}
        body={`${t('common.delete')} ${deleting?.username ?? ''}?`}
        password={password}
        onClose={() => setDeleting(null)}
        action={async (vtoken) => {
          if (deleting) await api.deleteAdmin(deleting.username, vtoken)
          await list.reload()
        }}
      />
    </div>
  )
}
