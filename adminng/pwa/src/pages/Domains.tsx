import { useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { api, ApiError, type Domain } from '../lib/api'
import { usePaged } from '../lib/usePaged'
import { Badge, ErrorBanner, Field, Input, Modal, SectionHeader, Toggle } from '../components/kit'
import { Button } from '../components/ui/button'
import { ConfirmDelete } from '../components/ConfirmDelete'

export function DomainsPage({ password }: { password: string }) {
  const { t } = useTranslation()
  const [params, setParams] = useSearchParams()
  const [query, setQuery] = useState(params.get('q') ?? '')
  const [openNew, setOpenNew] = useState(params.get('new') === '1')
  const [domain, setDomain] = useState('')
  const [description, setDescription] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [advisory, setAdvisory] = useState<string | null>(null)
  const [editing, setEditing] = useState<Domain | null>(null)
  const [deleting, setDeleting] = useState<Domain | null>(null)

  const list = usePaged<Domain>((cursor) => api.listDomains(query || undefined, cursor), [query])

  const create = async (): Promise<void> => {
    setError(null)
    try {
      const created = await api.createDomain({ domain, description })
      setOpenNew(false)
      setDomain('')
      setDescription('')
      setAdvisory(created.advisories?.[0]?.message ?? t('domains.advisory'))
      await list.reload()
    } catch (err) {
      setError(err instanceof ApiError ? `${err.code}: ${err.message}` : t('login.network'))
    }
  }

  return (
    <div className="space-y-4">
      <SectionHeader
        title={t('domains.title')}
        action={<Button onClick={() => setOpenNew(true)}>{t('domains.new')}</Button>}
      />
      {advisory && (
        <div className="rounded border border-amber-800 bg-amber-950/50 p-3 text-sm text-amber-200">
          {advisory}
        </div>
      )}
      <ErrorBanner message={list.error} />
      <form
        className="flex gap-2"
        onSubmit={(event) => {
          event.preventDefault()
          params.set('q', query)
          setParams(params)
        }}
      >
        <Input
          placeholder={t('common.search')}
          value={query}
          onChange={(event) => setQuery(event.target.value)}
        />
      </form>

      <div className="overflow-x-auto rounded-lg border border-slate-800">
        <table className="min-w-full text-sm">
          <thead className="bg-slate-900 text-left text-xs uppercase text-slate-500">
            <tr>
              <th className="px-3 py-2">{t('nav.domains')}</th>
              <th className="px-3 py-2">{t('domains.description')}</th>
              <th className="px-3 py-2">{t('domains.mailboxes')}</th>
              <th className="px-3 py-2">{t('domains.aliases')}</th>
              <th className="px-3 py-2">{t('common.active')}</th>
              <th className="px-3 py-2">{t('common.actions')}</th>
            </tr>
          </thead>
          <tbody>
            {list.items.map((item) => (
              <tr key={item.domain} className="border-t border-slate-800">
                <td className="px-3 py-2 font-mono text-xs">{item.domain}</td>
                <td className="px-3 py-2 text-slate-400">{item.description}</td>
                <td className="px-3 py-2">{item.mailboxes}</td>
                <td className="px-3 py-2">{item.aliases}</td>
                <td className="px-3 py-2">
                  {item.active ? (
                    <Badge tone="green">{t('common.yes')}</Badge>
                  ) : (
                    <Badge tone="red">{t('common.no')}</Badge>
                  )}
                </td>
                <td className="px-3 py-2">
                  <div className="flex gap-2">
                    <Button variant="outline" size="sm" onClick={() => setEditing(item)}>
                      {t('common.edit')}
                    </Button>
                    <Button variant="outline" size="sm" onClick={() => setDeleting(item)}>
                      {t('common.delete')}
                    </Button>
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {!list.loading && list.items.length === 0 && (
          <p className="py-6 text-center text-sm text-slate-500">{t('common.empty')}</p>
        )}
      </div>
      {list.cursor && (
        <Button variant="outline" onClick={() => void list.more()}>
          {t('common.page')}
        </Button>
      )}

      <Modal
        open={openNew}
        title={t('domains.new')}
        onClose={() => setOpenNew(false)}
        footer={
          <>
            <Button variant="outline" onClick={() => setOpenNew(false)}>{t('common.cancel')}</Button>
            <Button onClick={() => void create()}>{t('domains.create')}</Button>
          </>
        }
      >
        <ErrorBanner message={error} />
        <Field label={t('nav.domains')}>
          <Input value={domain} onChange={(event) => setDomain(event.target.value)} placeholder="example.com" />
        </Field>
        <Field label={t('domains.description')}>
          <Input value={description} onChange={(event) => setDescription(event.target.value)} />
        </Field>
      </Modal>

      <Modal
        open={Boolean(editing)}
        title={editing?.domain ?? ''}
        onClose={() => setEditing(null)}
        footer={<Button variant="outline" onClick={() => setEditing(null)}>{t('common.close')}</Button>}
      >
        {editing && (
          <>
            <Field label={t('domains.description')}>
              <Input
                defaultValue={editing.description}
                onBlur={(event) => {
                  void api
                    .updateDomain(editing.domain, { description: event.target.value })
                    .then(() => list.reload())
                }}
              />
            </Field>
            <Toggle
              checked={editing.active}
              label={t('common.active')}
              onChange={(value) => {
                void api.updateDomain(editing.domain, { active: value }).then(() => list.reload())
              }}
            />
          </>
        )}
      </Modal>

      <ConfirmDelete
        open={Boolean(deleting)}
        title={t('confirm.title')}
        body={`${t('common.delete')} ${deleting?.domain ?? ''}?`}
        password={password}
        onClose={() => setDeleting(null)}
        action={async (vtoken) => {
          if (deleting) await api.deleteDomain(deleting.domain, vtoken)
          await list.reload()
        }}
      />

    </div>
  )
}
