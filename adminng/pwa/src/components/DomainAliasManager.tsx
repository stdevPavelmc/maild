import { useCallback, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api, ApiError, type DomainAlias } from '../lib/api'
import { Button } from './ui/button'
import { ConfirmDelete } from './ConfirmDelete'
import { ErrorBanner, Field, Input, Toggle } from './kit'

export function DomainAliasManager({
  domain,
  password,
  online,
  onChanged,
}: {
  domain: string
  password: string
  online: boolean
  onChanged: () => Promise<void>
}) {
  const { t } = useTranslation()
  const [aliases, setAliases] = useState<DomainAlias[]>([])
  const [targetDrafts, setTargetDrafts] = useState<Record<string, string>>({})
  const [source, setSource] = useState('')
  const [target, setTarget] = useState(domain)
  const [error, setError] = useState<string | null>(null)
  const [deleting, setDeleting] = useState<DomainAlias | null>(null)

  const reload = useCallback(async () => {
    try {
      const result = await api.listDomainAliases(domain)
      setAliases(result.items)
      setTargetDrafts(
        Object.fromEntries(result.items.map((alias) => [alias.alias_domain, alias.target_domain])),
      )
      setError(null)
    } catch (err) {
      setError(err instanceof ApiError ? `${err.code}: ${err.message}` : t('login.network'))
    }
  }, [domain, t])

  useEffect(() => {
    setTarget(domain)
    setSource('')
    void reload()
  }, [domain, reload])

  const add = async (event: React.FormEvent): Promise<void> => {
    event.preventDefault()
    setError(null)
    try {
      await api.createDomainAlias({ alias_domain: source, target_domain: target })
      setSource('')
      await reload()
      await onChanged()
    } catch (err) {
      setError(err instanceof ApiError ? `${err.code}: ${err.message}` : t('login.network'))
    }
  }

  const updateActive = async (alias: DomainAlias, active: boolean): Promise<void> => {
    setError(null)
    try {
      await api.updateDomainAlias(alias.alias_domain, { active })
      await reload()
      await onChanged()
    } catch (err) {
      setError(err instanceof ApiError ? `${err.code}: ${err.message}` : t('login.network'))
    }
  }

  const updateTarget = async (alias: DomainAlias): Promise<void> => {
    setError(null)
    try {
      await api.updateDomainAlias(alias.alias_domain, {
        target_domain: targetDrafts[alias.alias_domain] ?? alias.target_domain,
      })
      await reload()
      await onChanged()
    } catch (err) {
      setError(err instanceof ApiError ? `${err.code}: ${err.message}` : t('login.network'))
    }
  }

  return (
    <section className="space-y-3 border-t border-slate-700 pt-4">
      <h3 className="font-medium">{t('domains.aliasManager')}</h3>
      <ErrorBanner message={error} />
      {aliases.length === 0 ? (
        <p className="text-sm text-slate-400">{t('domains.noAliases')}</p>
      ) : (
        <ul className="space-y-2">
          {aliases.map((alias) => (
            <li
              key={alias.alias_domain}
              className="flex flex-wrap items-center justify-between gap-3 rounded-lg bg-slate-800/60 p-3"
            >
              <div className="grid min-w-0 flex-1 gap-2 sm:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto]">
                <span className="break-all font-mono text-sm">
                  {alias.alias_domain} <span aria-hidden="true">→</span>
                </span>
                <Input
                  value={targetDrafts[alias.alias_domain] ?? alias.target_domain}
                  disabled={!online}
                  aria-label={`${t('domains.targetDomain')} ${alias.alias_domain}`}
                  onChange={(event) =>
                    setTargetDrafts((drafts) => ({
                      ...drafts,
                      [alias.alias_domain]: event.target.value,
                    }))
                  }
                />
                <Button
                  variant="outline"
                  size="sm"
                  disabled={
                    !online ||
                    !(targetDrafts[alias.alias_domain] ?? alias.target_domain).trim() ||
                    (targetDrafts[alias.alias_domain] ?? alias.target_domain) === alias.target_domain
                  }
                  onClick={() => void updateTarget(alias)}
                >
                  {t('domains.saveTarget')}
                </Button>
              </div>
              <div className="flex items-center gap-3">
                <Toggle
                  checked={alias.active}
                  label={t('common.active')}
                  disabled={!online}
                  onChange={(active) => void updateActive(alias, active)}
                />
                <Button
                  variant="outline"
                  size="sm"
                  disabled={!online}
                  onClick={() => setDeleting(alias)}
                >
                  {t('common.delete')}
                </Button>
              </div>
            </li>
          ))}
        </ul>
      )}
      <form className="space-y-3 rounded-lg border border-slate-800 p-3" onSubmit={add}>
        <h4 className="text-sm font-medium">{t('domains.addAlias')}</h4>
        <Field label={t('domains.aliasDomain')}>
          <Input
            value={source}
            onChange={(event) => setSource(event.target.value)}
            placeholder="example-alias.net"
          />
        </Field>
        <Field label={t('domains.targetDomain')}>
          <Input
            value={target}
            onChange={(event) => setTarget(event.target.value)}
            placeholder="example.net"
          />
        </Field>
        <Button type="submit" size="sm" disabled={!online || !source.trim() || !target.trim()}>
          {t('domains.addAlias')}
        </Button>
      </form>
      <ConfirmDelete
        open={Boolean(deleting)}
        title={t('confirm.title')}
        body={`${t('common.delete')} ${deleting?.alias_domain ?? ''}?`}
        password={password}
        onClose={() => setDeleting(null)}
        action={async (vtoken) => {
          if (deleting) await api.deleteDomainAlias(deleting.alias_domain, vtoken)
          await reload()
          await onChanged()
        }}
      />
    </section>
  )
}
