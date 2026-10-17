import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api, ApiError, type Alias } from '../lib/api'
import { useOnline } from '../lib/online'
import { useSelectedDomain } from '../lib/selectedDomain'
import { usePaged } from '../lib/usePaged'
import { useNewSignal, useSearchQuery } from '../lib/useUrlState'
import { Empty, ErrorBanner, Field, GotoInput, Input, Modal, SectionHeader, Toggle } from '../components/kit'
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
import { splitForwardsTo } from '../lib/format'
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
  const [editing, setEditing] = useState<Alias | null>(null)

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
                  glyph="🛠"
                  label={t('common.edit')}
                  disabled={!online}
                  onClick={() => setEditing(alias)}
                />
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
              {splitForwardsTo(alias.goto)
                .slice(0, 4)
                .map((goto) => (
                  <MetaChip key={goto} icon="🎭" title={t('aliases.goto')}>
                    {goto}
                  </MetaChip>
                ))}
              {splitForwardsTo(alias.goto).length > 4 && (
                <MetaChip icon="🎭" title={splitForwardsTo(alias.goto).join(', ')}>
                  {t('common.more', { count: splitForwardsTo(alias.goto).length - 4 })}
                </MetaChip>
              )}
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
          <GotoInput
            value={goto}
            disabled={!online}
            onCommit={(value) => setGoto(value)}
          />
        </Field>
      </Modal>

      <Modal
        open={Boolean(editing)}
        title={editing?.address ?? ''}
        onClose={() => setEditing(null)}
        footer={<Button variant="outline" onClick={() => setEditing(null)}>{t('common.close')}</Button>}
      >
        {editing && (
          <>
            <Field label={t('aliases.goto')}>
              <GotoInput
                value={editing.goto}
                disabled={!online}
                onCommit={(value) => {
                  void api
                    .updateAlias(editing.address, { goto: value })
                    .then(() => list.reload())
                }}
              />
            </Field>
            <Toggle
              checked={editing.active}
              label={t('common.active')}
              disabled={!online}
              onChange={(value) => {
                void api
                  .updateAlias(editing.address, { active: value })
                  .then(() => list.reload())
              }}
            />
          </>
        )}
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
