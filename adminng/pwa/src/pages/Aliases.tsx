import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api, ApiError, type Alias } from '../lib/api'
import { useOnline } from '../lib/online'
import { useSelectedDomain } from '../lib/selectedDomain'
import { usePaged } from '../lib/usePaged'
import { useNewSignal, useSearchQuery } from '../lib/useUrlState'
import { Empty, ErrorBanner, Field, Input, Modal, SectionHeader } from '../components/kit'
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

export function AliasesPage({ password }: { password: string }) {
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
  const [address, setAddress] = useState('')
  const [goto, setGoto] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [deleting, setDeleting] = useState<Alias | null>(null)

  const list = usePaged<Alias>(
    (cursor) => api.listAliases({ domain: scope || undefined, q: query || undefined, cursor }),
    [scope, query],
  )

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
        action={
          <Button disabled={!online} onClick={() => setOpenNew(true)}>{t('aliases.new')}</Button>
        }
      />
      <ErrorBanner message={list.error} />
      <form
        onSubmit={(event) => {
          event.preventDefault()
          setUrlQuery(query)
        }}
      >
        <Input placeholder={t('common.search')} value={query} onChange={(event) => setQuery(event.target.value)} />
      </form>

      <CardGrid>
        {list.items.map((alias) => (
          <EntityCard key={alias.address} status={alias.active ? 'active' : 'inactive'}>
            <CardHead>
              <div className="flex min-w-0 items-start gap-2">
                <StatusMark active={alias.active} />
                <Address address={alias.address} />
              </div>
              <ActionRow label={t('common.actions')}>
                <ActionButton
                  glyph="❌"
                  label={t('common.delete')}
                  tone="danger"
                  disabled={!online}
                  onClick={() => setDeleting(alias)}
                />
              </ActionRow>
            </CardHead>
            <p className="mt-1 break-all text-sm text-slate-400 line-clamp-1" title={alias.goto}>
              <span aria-hidden="true">↳ </span>
              {alias.goto}
            </p>
            <MetaRow>
              <MetaChip icon="🌐" title={t('domain.select')}>{alias.domain}</MetaChip>
              {alias.created && (
                <MetaChip icon="🗓" title={t('common.created')}>{alias.created.slice(0, 10)}</MetaChip>
              )}
            </MetaRow>
          </EntityCard>
        ))}
      </CardGrid>
      {!list.loading && list.items.length === 0 && <Empty text={t('common.empty')} />}
      {list.cursor && <Button variant="outline" onClick={() => void list.more()}>{t('common.page')}</Button>}

      <Modal
        open={openNew}
        title={t('aliases.new')}
        onClose={() => setOpenNew(false)}
        footer={
          <>
            <Button variant="outline" onClick={() => setOpenNew(false)}>{t('common.cancel')}</Button>
            <Button disabled={!online} onClick={() => void create()}>{t('aliases.create')}</Button>
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
