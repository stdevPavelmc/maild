import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Button, Card } from '../components/ui'

const CLIENTS = ['claude', 'chatgpt', 'claudeCode', 'gemini', 'mcpRemote', 'rest'] as const
type Client = (typeof CLIENTS)[number]

/** Copy-ready connection settings per client (proposal §7.3 "Connection help"). The URLs come
 * from the page's own origin, which is the public MCP host behind the ingress. */
function snippet(client: Client, base: string): string {
  const mcp = `${base}/api/v1/mcp`
  switch (client) {
    case 'claude':
    case 'chatgpt':
      return mcp
    case 'claudeCode':
      return `claude mcp add --transport http maild ${mcp}\n\n# or with a personal access token instead of signing in:\nclaude mcp add --transport http maild ${mcp} \\\n  --header "Authorization: Bearer mdmcp_pat_…"`
    case 'gemini':
      return JSON.stringify(
        { mcpServers: { maild: { httpUrl: mcp, headers: { Authorization: 'Bearer mdmcp_pat_…' } } } },
        null,
        2,
      )
    case 'mcpRemote':
      return JSON.stringify(
        {
          mcpServers: {
            maild: {
              command: 'npx',
              args: ['-y', 'mcp-remote', mcp, '--header', 'Authorization:${MAILD_AUTH}'],
              env: { MAILD_AUTH: 'Bearer mdmcp_pat_…' },
            },
          },
        },
        null,
        2,
      )
    case 'rest':
      return `export MAILD_TOKEN=mdmcp_pat_…\ncurl -s -X POST ${base}/api/v1/mail/list_accounts \\\n  -H "Authorization: Bearer $MAILD_TOKEN" -H 'Content-Type: application/json' -d '{}'`
  }
}

export default function Connect() {
  const { t } = useTranslation()
  const [client, setClient] = useState<Client>('claude')
  const [copied, setCopied] = useState(false)
  const base = window.location.origin
  const text = snippet(client, base)

  return (
    <Card title={t('connect.title')}>
      <p className="mb-3 text-sm text-slate-300">{t('connect.intro')}</p>
      <div className="mb-3 flex flex-wrap gap-2" role="group" aria-label={t('connect.clients')}>
        {CLIENTS.map((c) => (
          <Button
            key={c}
            variant={c === client ? 'primary' : 'secondary'}
            aria-pressed={c === client}
            onClick={() => {
              setClient(c)
              setCopied(false)
            }}
          >
            {t(`connect.client.${c}`)}
          </Button>
        ))}
      </div>
      <div className="flex flex-col gap-2" data-testid="connect-panel">
        <p className="text-sm text-slate-300">{t(`connect.how.${client}`)}</p>
        <div className="flex flex-col gap-2 sm:flex-row sm:items-start">
          <pre className="flex-1 overflow-x-auto whitespace-pre rounded-md border border-slate-700 bg-slate-950 p-3 text-xs" data-testid="connect-snippet">
            {text}
          </pre>
          <Button
            variant="secondary"
            onClick={() => {
              void navigator.clipboard?.writeText(text).then(() => setCopied(true))
            }}
          >
            {copied ? t('tokens.copied') : t('tokens.copy')}
          </Button>
        </div>
        {client === 'rest' && (
          <p className="text-sm text-slate-300">
            {t('connect.docs')}{' '}
            <a className="text-blue-400 underline" href="/api/v1/openapi.json">
              openapi.json
            </a>
            {' · '}
            <a className="text-blue-400 underline" href="/api/v1/skill.md" download="SKILL.md">
              SKILL.md
            </a>
          </p>
        )}
      </div>
    </Card>
  )
}
