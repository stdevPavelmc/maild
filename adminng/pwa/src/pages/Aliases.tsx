import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api, ApiError, type Alias } from '../lib/api'
import { usePaged } from '../lib/usePaged'
import { Badge, ErrorBanner, Field, Input, Modal, SectionHeader } from '../components/kit'
import { Button } from '../components/ui/button'
import { ConfirmDelete } from '../components/ConfirmDelete'

export function AliasesPage({ password }: { password: string }) {
  const { t } = useTranslation()
  const initial = new URLSearchParams(window.location.search)
  const [query, setQuery] = useState(initial.get('q') ?? '')
  const [openNew, setOpenNew] = useState(initial.get('new') === '1')
  const [address, setAddress] = useState('')
  const [goto, setGoto] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [deleting, setDeleting] = useState<Alias | null>(null)

  const list = usePaged<Alias>((cursor) => api.listAliases({ q: query || undefined, cursor }), [query])

  const create = async (): Promise<void> => {
    setError(null)
    try {
      await api.createAlias({ address, goto })
      setOpenNew(false)
      setAddress('')
      setGoto('')
      await list.reload()
    } catch (err) {
      setError(err instanceof ApiError ? `${err.code}: ${err.message}` : t('login.network'))
    }
  }

  return (
    <div className="space-y-4">
      <SectionHeader
        title={t('aliases.title')}
        action={<Button onClick={() => setOpenNew(true)}>{t('aliases.new')}</Button>}
      />
      <ErrorBanner message={list.error} />
      <Input placeholder={t('common.search')} value={query} onChange={(event) => setQuery(event.target.value)} />

      <div className="overflow-x-auto rounded-lg border border-slate-800">
        <table className="min-w-full text-sm">
          <thead className="bg-slate-900 text-left text-xs uppercase text-slate-500">
            <tr>
              <th className="px-3 py-2">{t('aliases.address')}</th>
              <th className="px-3 py-2">{t('aliases.goto')}</th>
              <th className="px-3 py-2">{t('common.active')}</th>
              <th className="px-3 py-2">{t('common.actions')}</th>
            </tr>
          </thead>
          <tbody>
            {list.items.map((alias) => (
              <tr key={alias.address} className="border-t border-slate-800">
                <td className="px-3 py-2 font-mono text-xs">{alias.address}</td>
                <td className="px-3 py-2 text-slate-400">{alias.goto}</td>
                <td className="px-3 py-2">
                  {alias.active ? <Badge tone="green">{t('common.yes')}</Badge> : <Badge tone="red">{t('common.no')}</Badge>}
                </td>
                <td className="px-3 py-2">
                  <Button variant="outline" size="sm" onClick={() => setDeleting(alias)}>{t('common.delete')}</Button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {!list.loading && list.items.length === 0 && (
          <p className="py-6 text-center text-sm text-slate-500">{t('common.empty')}</p>
        )}
      </div>
      {list.cursor && <Button variant="outline" onClick={() => void list.more()}>{t('common.page')}</Button>}

      <Modal
        open={openNew}
        title={t('aliases.new')}
        onClose={() => setOpenNew(false)}
        footer={
          <>
            <Button variant="outline" onClick={() => setOpenNew(false)}>{t('common.cancel')}</Button>
            <Button onClick={() => void create()}>{t('aliases.create')}</Button>
          </>
        }
      >
        <ErrorBanner message={error} />
        <Field label={t('aliases.address')}>
          <Input value={address} onChange={(event) => setAddress(event.target.value)} placeholder="sales@example.com" />
        </Field>
        <Field label={t('aliases.goto')}>
          <Input value={goto} onChange={(event) => setGoto(event.target.value)} placeholder="user@example.com" />
        </Field>
      </Modal>

      <ConfirmDelete
        open={Boolean(deleting)}
        title={t('confirm.title')}
        body={`${t('common.delete')} ${deleting?.address ?? ''}?`}
        password={password}
        onClose={() => setDeleting(null)}
        action={async (vtoken) => {
          if (deleting) await api.deleteAlias(deleting.address, vtoken)
          await list.reload()
        }}
      />
    </div>
  )
}
