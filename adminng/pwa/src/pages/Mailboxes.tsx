import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api, ApiError, type Alias, type Domain, type Mailbox } from '../lib/api'
import { useOnline } from '../lib/online'
import { setSelectedDomain, useSelectedDomain } from '../lib/selectedDomain'
import { usePaged } from '../lib/usePaged'
import { useNewSignal, useSearchQuery } from '../lib/useUrlState'
import { Badge, ErrorBanner, Field, Input, Modal, SectionHeader, Toggle } from '../components/kit'
import { Button } from '../components/ui/button'
import { ConfirmDelete } from '../components/ConfirmDelete'

export function MailboxesPage({ password }: { password: string }) {
  const { t } = useTranslation()
  const online = useOnline()
  const scope = useSelectedDomain()
  const [urlQuery, setUrlQuery] = useSearchQuery()
  const [query, setQuery] = useState(urlQuery)
  const [openNew, setOpenNew] = useState(false)
  const newSignal = useNewSignal()
  useEffect(() => {
    setQuery(urlQuery)
  }, [urlQuery])
  useEffect(() => {
    if (newSignal) setOpenNew(true)
  }, [newSignal])
  const [domains, setDomains] = useState<Domain[]>([])
  const [username, setUsername] = useState('')
  const [newPassword, setNewPassword] = useState('')
  const [name, setName] = useState('')
  const [quotaMb, setQuotaMb] = useState(0)
  const [error, setError] = useState<string | null>(null)
  const [editing, setEditing] = useState<Mailbox | null>(null)
  const [deleting, setDeleting] = useState<Mailbox | null>(null)
  const [aliases, setAliases] = useState<Alias[]>([])
  const [aliasAddress, setAliasAddress] = useState('')
  const [aliasToDelete, setAliasToDelete] = useState<Alias | null>(null)

  const list = usePaged<Mailbox>(
    (cursor) => api.listMailboxes({ domain: scope || undefined, q: query || undefined, cursor }),
    [scope, query],
  )

  useEffect(() => {
    api.listDomains().then((page) => setDomains(page.items)).catch(() => setDomains([]))
  }, [])

  const openEditor = async (mailbox: Mailbox): Promise<void> => {
    setEditing(mailbox)
    setAliases([])
    try {
      const page = await api.listAliases({ goto: mailbox.username })
      setAliases(page.items)
    } catch {
      setAliases([])
    }
  }

  const create = async (): Promise<void> => {
    setError(null)
    try {
      await api.createMailbox({
        username,
        password: newPassword,
        name,
        quota_bytes: Math.max(0, Math.round(quotaMb)) * 1024 * 1024,
      })
      setOpenNew(false)
      setUsername('')
      setNewPassword('')
      setName('')
      setQuotaMb(0)
      await list.reload()
    } catch (err) {
      setError(err instanceof ApiError ? `${err.code}: ${err.message}` : t('login.network'))
    }
  }

  const addAlias = async (): Promise<void> => {
    if (!editing || !aliasAddress) return
    setError(null)
    try {
      const created = await api.createAlias({ address: aliasAddress, goto: editing.username })
      setAliases((current) => [...current, created])
      setAliasAddress('')
    } catch (err) {
      setError(err instanceof ApiError ? `${err.code}: ${err.message}` : t('login.network'))
    }
  }

  return (
    <div className="space-y-4">
      <SectionHeader
        title={t('mailboxes.title')}
        action={
          <Button disabled={!online} onClick={() => setOpenNew(true)}>{t('mailboxes.new')}</Button>
        }
      />
      <ErrorBanner message={list.error} />
      <div className="flex flex-wrap gap-2">
        <select
          className="h-10 rounded-md border border-slate-700 bg-slate-900 px-3 text-sm"
          aria-label={t('domain.select')}
          value={scope}
          onChange={(event) => setSelectedDomain(event.target.value)}
        >
          <option value="">{t('domain.all')}</option>
          {domains.map((item) => (
            <option key={item.domain} value={item.domain}>{item.domain}</option>
          ))}
        </select>
        <form
          className="max-w-xs flex-1"
          onSubmit={(event) => {
            event.preventDefault()
            setUrlQuery(query)
          }}
        >
          <Input
            placeholder={t('common.search')}
            value={query}
            onChange={(event) => setQuery(event.target.value)}
          />
        </form>
      </div>

      <div className="overflow-x-auto rounded-lg border border-slate-800">
        <table className="min-w-full text-sm">
          <thead className="bg-slate-900 text-left text-xs uppercase text-slate-400">
            <tr>
              <th className="px-3 py-2">{t('mailboxes.username')}</th>
              <th className="px-3 py-2">{t('common.name')}</th>
              <th className="px-3 py-2">{t('common.quota')}</th>
              <th className="px-3 py-2">{t('common.active')}</th>
              <th className="px-3 py-2">{t('common.actions')}</th>
            </tr>
          </thead>
          <tbody>
            {list.items.map((mailbox) => (
              <tr key={mailbox.username} className="border-t border-slate-800">
                <td className="px-3 py-2 font-mono text-xs">{mailbox.username}</td>
                <td className="px-3 py-2 text-slate-400">{mailbox.name}</td>
                <td className="px-3 py-2 text-xs">
                  {mailbox.quota_bytes > 0
                    ? `${Math.round(mailbox.quota_bytes / 1024 / 1024)} MB`
                    : t('common.unlimited')}
                </td>
                <td className="px-3 py-2">
                  {mailbox.active ? (
                    <Badge tone="green">{t('common.yes')}</Badge>
                  ) : (
                    <Badge tone="red">{t('common.no')}</Badge>
                  )}
                </td>
                <td className="px-3 py-2">
                  <div className="flex gap-2">
                    <Button variant="outline" size="sm" disabled={!online} onClick={() => void openEditor(mailbox)}>
                      {t('common.edit')}
                    </Button>
                    <Button variant="outline" size="sm" disabled={!online} onClick={() => setDeleting(mailbox)}>
                      {t('common.delete')}
                    </Button>
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {!list.loading && list.items.length === 0 && (
          <p className="py-6 text-center text-sm text-slate-400">{t('common.empty')}</p>
        )}
      </div>
      {list.cursor && (
        <Button variant="outline" onClick={() => void list.more()}>{t('common.page')}</Button>
      )}

      <Modal
        open={openNew}
        title={t('mailboxes.new')}
        onClose={() => setOpenNew(false)}
        footer={
          <>
            <Button variant="outline" onClick={() => setOpenNew(false)}>{t('common.cancel')}</Button>
            <Button disabled={!online} onClick={() => void create()}>{t('mailboxes.create')}</Button>
          </>
        }
      >
        <ErrorBanner message={error} />
        <Field label={t('mailboxes.username')}>
          <Input value={username} onChange={(event) => setUsername(event.target.value)} placeholder="user@example.com" />
        </Field>
        <Field label={t('mailboxes.password')}>
          <Input type="password" value={newPassword} onChange={(event) => setNewPassword(event.target.value)} />
        </Field>
        <Field label={t('common.name')}>
          <Input value={name} onChange={(event) => setName(event.target.value)} />
        </Field>
        <Field label={t('mailboxes.quota')}>
          <Input
            inputMode="numeric"
            value={quotaMb}
            onChange={(event) => setQuotaMb(Number(event.target.value) || 0)}
          />
        </Field>
      </Modal>

      <Modal
        open={Boolean(editing)}
        title={editing?.username ?? ''}
        onClose={() => setEditing(null)}
        footer={<Button variant="outline" onClick={() => setEditing(null)}>{t('common.close')}</Button>}
      >
        {editing && (
          <>
            <ErrorBanner message={error} />
            <Field label={t('common.name')}>
              <Input
                defaultValue={editing.name}
                disabled={!online}
                onBlur={(event) => {
                  void api
                    .updateMailbox(editing.username, { name: event.target.value })
                    .then(() => list.reload())
                }}
              />
            </Field>
            <Field label={t('mailboxes.quota')}>
              <Input
                inputMode="numeric"
                defaultValue={Math.round(editing.quota_bytes / 1024 / 1024)}
                disabled={!online}
                onBlur={(event) => {
                  void api
                    .updateMailbox(editing.username, {
                      quota_bytes: Math.max(0, Number(event.target.value) || 0) * 1024 * 1024,
                    })
                    .then(() => list.reload())
                }}
              />
            </Field>
            <Field label={t('mailboxes.password')}>
              <Input
                type="password"
                placeholder="••••••••"
                disabled={!online}
                onBlur={(event) => {
                  if (!event.target.value) return
                  void api.updateMailbox(editing.username, { password: event.target.value })
                }}
              />
            </Field>
            <Toggle
              checked={editing.active}
              label={t('common.active')}
              disabled={!online}
              onChange={(value) => {
                void api
                  .updateMailbox(editing.username, { active: value })
                  .then(() => list.reload())
              }}
            />

            <div className="rounded border border-slate-800 p-3">
              <p className="mb-2 text-xs uppercase tracking-wide text-slate-400">
                {t('mailboxes.aliases')}
              </p>
              <div className="flex flex-wrap gap-2">
                {aliases.map((alias) => (
                  <span
                    key={alias.address}
                    className="flex items-center gap-2 rounded bg-slate-800 px-2 py-1 text-xs"
                  >
                    {alias.address}
                    <button aria-label="remove" disabled={!online} onClick={() => setAliasToDelete(alias)}>✕</button>
                  </span>
                ))}
                {aliases.length === 0 && <span className="text-xs text-slate-400">—</span>}
              </div>
              <div className="mt-3 flex gap-2">
                <Input
                  placeholder={t('mailboxes.aliasAddress')}
                  value={aliasAddress}
                  disabled={!online}
                  onChange={(event) => setAliasAddress(event.target.value)}
                />
                <Button variant="outline" disabled={!online} onClick={() => void addAlias()}>
                  {t('mailboxes.addAlias')}
                </Button>
              </div>
            </div>
          </>
        )}
      </Modal>

      <ConfirmDelete
        open={Boolean(deleting)}
        title={t('confirm.title')}
        body={`${t('common.delete')} ${deleting?.username ?? ''}?`}
        password={password}
        onClose={() => setDeleting(null)}
        action={async (vtoken) => {
          if (deleting) await api.deleteMailbox(deleting.username, vtoken)
          await list.reload()
        }}
      />

      <ConfirmDelete
        open={Boolean(aliasToDelete)}
        title={t('confirm.title')}
        body={`${t('common.delete')} ${aliasToDelete?.address ?? ''}?`}
        password={password}
        onClose={() => setAliasToDelete(null)}
        action={async (vtoken) => {
          if (aliasToDelete) {
            await api.deleteAlias(aliasToDelete.address, vtoken)
            setAliases((current) => current.filter((item) => item.address !== aliasToDelete.address))
          }
        }}
      />
    </div>
  )
}
