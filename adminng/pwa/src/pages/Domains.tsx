import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api, ApiError, type Domain } from '../lib/api'
import { useOnline } from '../lib/online'
import { usePaged } from '../lib/usePaged'
import { useNewSignal, useSearchQuery } from '../lib/useUrlState'
import { Empty, ErrorBanner, Field, Input, Modal, SectionHeader, Toggle } from '../components/kit'
import {
  ActionButton,
  ActionRow,
  CardGrid,
  CardHead,
  EntityCard,
  MetaChip,
  MetaRow,
  StatusMark,
  TruncatedName,
} from '../components/cards'
import { Button } from '../components/ui/button'
import { ConfirmDelete } from '../components/ConfirmDelete'
import { DomainAliasManager } from '../components/DomainAliasManager'

export function DomainsPage({ password }: { password: string }) {
  const { t } = useTranslation()
  const online = useOnline()
  // `?q=` and `?new=1` drive the screen, so the search modal and the FAB work
  // even when Domains is already mounted (React Router keeps it alive).
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
  const [domain, setDomain] = useState('')
  const [description, setDescription] = useState('')
  // PostfixAdmin created postmaster/abuse/hostmaster/webmaster with every domain;
  // keep that default, but let the operator opt out (some domains are aliases only).
  const [defaultAliases, setDefaultAliases] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [advisory, setAdvisory] = useState<string | null>(null)
  const [editing, setEditing] = useState<Domain | null>(null)
  const [deleting, setDeleting] = useState<Domain | null>(null)

  const list = usePaged<Domain>((cursor) => api.listDomains(query || undefined, cursor), [query])

  const create = async (): Promise<void> => {
    setError(null)
    try {
      const created = await api.createDomain({ domain, description, default_aliases: defaultAliases })
      setOpenNew(false)
      setDomain('')
      setDescription('')
      setDefaultAliases(true)
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
        action={
          <Button disabled={!online} onClick={() => setOpenNew(true)}>{t('domains.new')}</Button>
        }
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
          setUrlQuery(query)
        }}
      >
        <Input
          placeholder={t('common.search')}
          value={query}
          onChange={(event) => setQuery(event.target.value)}
        />
      </form>

      <CardGrid>
        {list.items.map((item) => (
          <EntityCard key={item.domain} status={item.active ? 'active' : 'inactive'}>
            <CardHead>
              <div className="flex min-w-0 items-start gap-2">
                <StatusMark active={item.active} />
                <TruncatedName name={item.domain} />
              </div>
              <ActionRow label={t('common.actions')}>
                <ActionButton
                  glyph="🛠"
                  label={t('common.edit')}
                  disabled={!online}
                  onClick={() => setEditing(item)}
                />
                <ActionButton
                  glyph="❌"
                  label={t('common.delete')}
                  tone="danger"
                  disabled={!online}
                  onClick={() => setDeleting(item)}
                />
              </ActionRow>
            </CardHead>
            <p
              className="mt-1 break-all text-sm text-slate-400 line-clamp-2"
              title={item.description}
            >
              {item.description || '—'}
            </p>
            <MetaRow>
              <MetaChip icon="📬" title={t('domains.mailboxes')}>{item.mailboxes}</MetaChip>
              <MetaChip icon="🎭" title={t('domains.aliases')}>{item.aliases}</MetaChip>
              {item.alias_domains > 0 && (
                <MetaChip icon="↗" title={t('domains.aliasDomains')}>
                  {item.alias_domains}
                </MetaChip>
              )}
              {item.aliasing_to && (
                <MetaChip icon="↗" title={t('domains.aliasingTo')}>
                  {t('domains.aliasingTo')} {item.aliasing_to}
                </MetaChip>
              )}
            </MetaRow>
          </EntityCard>
        ))}
      </CardGrid>
      {!list.loading && list.items.length === 0 && <Empty text={t('common.empty')} />}
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
            <Button disabled={!online} onClick={() => void create()}>{t('domains.create')}</Button>
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
        <Toggle
          checked={defaultAliases}
          label={t('domains.defaultAliases')}
          disabled={!online}
          onChange={setDefaultAliases}
        />
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
              disabled={!online}
              onChange={(value) => {
                void api.updateDomain(editing.domain, { active: value }).then(() => list.reload())
              }}
            />
            <DomainAliasManager
              domain={editing.domain}
              password={password}
              online={online}
              onChanged={() => list.reload()}
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
