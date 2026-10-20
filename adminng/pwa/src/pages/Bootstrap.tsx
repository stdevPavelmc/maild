import { useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api, type BootstrapReport } from '../lib/api'
import { Badge, ErrorBanner, SectionHeader } from '../components/kit'
import { Button } from '../components/ui/button'

/** The header row the CSV file must have, in this exact order.
 * Trailing columns `passwordhash` and/or `problem` are also accepted. */
const EXPECTED_HEADERS = ['fullname', 'emailaddress', 'password', 'quota']
const ALLOWED_TRAILING = ['passwordhash', 'problem']

/** Read a file as base64 (the API takes the CSV base64-encoded). */
function readAsBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onerror = () => reject(new Error('the file could not be read'))
    reader.onload = () => {
      const result = String(reader.result ?? '')
      // A data URL is "<prefix>,<base64>"; only the payload is sent.
      resolve(result.includes(',') ? result.slice(result.indexOf(',') + 1) : result)
    }
    reader.readAsDataURL(file)
  })
}

/** The first line of the file, split into its cells (header check). */
function headerCells(text: string): string[] {
  const line = text.split(/\r?\n/, 1)[0] ?? ''
  return line.split(',').map((cell) => cell.trim().toLowerCase())
}

export function BootstrapPage() {
  const { t } = useTranslation()
  const inputRef = useRef<HTMLInputElement>(null)
  const [file, setFile] = useState<File | null>(null)
  const [headerError, setHeaderError] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [report, setReport] = useState<BootstrapReport | null>(null)

  const pick = async (selected: File | null): Promise<void> => {
    setError(null)
    setHeaderError(null)
    setReport(null)
    if (!selected) {
      setFile(null)
      return
    }
    if (!selected.name.toLowerCase().endsWith('.csv')) {
      setFile(null)
      setHeaderError(t('bootstrap.invalidExtension'))
      return
    }
    // The header is checked in the browser before anything is uploaded.
    try {
      const text = await selected.text()
      const cells = headerCells(text)
      const ok =
        cells.length >= EXPECTED_HEADERS.length &&
        cells.every((cell, index) => cell === EXPECTED_HEADERS[index]) &&
        cells.slice(EXPECTED_HEADERS.length).every((cell) =>
          ALLOWED_TRAILING.includes(cell)
        )
      if (!ok) {
        setFile(null)
        setHeaderError(t('bootstrap.invalidHeaders'))
        return
      }
    } catch {
      setFile(null)
      setError(t('bootstrap.readError'))
      return
    }
    setFile(selected)
  }

  const upload = async (): Promise<void> => {
    if (!file) return
    setBusy(true)
    setError(null)
    try {
      const payload = await readAsBase64(file)
      setReport(await api.bootstrapUsers(payload))
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  /** Download the failed rows as a CSV (the API built it). */
  const downloadFailed = (): void => {
    if (!report?.failed_csv_base64) return
    const binary = atob(report.failed_csv_base64)
    const bytes = new Uint8Array(binary.length)
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
    const url = URL.createObjectURL(new Blob([bytes], { type: 'text/csv;charset=utf-8' }))
    const link = document.createElement('a')
    link.href = url
    link.download = 'failed-rows.csv'
    document.body.appendChild(link)
    link.click()
    link.remove()
    URL.revokeObjectURL(url)
  }

  return (
    <div className="space-y-4">
      <SectionHeader title={t('bootstrap.title')} />

      <div className="rounded-lg border border-slate-800 bg-slate-900/60 p-4 text-sm text-slate-300">
        <p className="mb-3">{t('bootstrap.intro')}</p>
        <h3 className="mb-1 font-semibold text-slate-200">{t('bootstrap.formatTitle')}</h3>
        <p className="mb-2">
          {t('bootstrap.formatHelp', { headers: EXPECTED_HEADERS.join(',') })}
        </p>
        <ul className="mb-3 list-disc space-y-1 pl-5 text-xs text-slate-400">
          <li>{t('bootstrap.columnFullname')}</li>
          <li>{t('bootstrap.columnEmail')}</li>
          <li>{t('bootstrap.columnPassword')}</li>
          <li>{t('bootstrap.columnQuota')}</li>
        </ul>
        <h3 className="mb-1 font-semibold text-slate-200">{t('bootstrap.rulesTitle')}</h3>
        <ul className="list-disc space-y-1 pl-5 text-xs text-slate-400">
          <li>{t('bootstrap.ruleDomain')}</li>
          <li>{t('bootstrap.rulePassword')}</li>
          <li>{t('bootstrap.ruleQuota')}</li>
          <li>{t('bootstrap.ruleExisting')}</li>
          <li>{t('bootstrap.rulePartial')}</li>
        </ul>
        <a
          className="mt-3 inline-flex items-center gap-2 rounded-md border border-slate-700 px-3 py-1.5 text-xs text-slate-200 hover:bg-slate-800"
          href={`${import.meta.env.BASE_URL}bootstrap-sample.csv`}
          download="bootstrap-sample.csv"
        >
          ⬇ {t('bootstrap.sample')}
        </a>
      </div>

      <ErrorBanner message={error} />
      {headerError && <ErrorBanner message={headerError} />}

      <div className="rounded-lg border border-slate-800 p-4">
        <label className="mb-2 block text-sm" htmlFor="bootstrap-file">
          {t('bootstrap.file')}
        </label>
        <input
          id="bootstrap-file"
          ref={inputRef}
          type="file"
          accept=".csv,text/csv"
          onChange={(event) => void pick(event.target.files?.[0] ?? null)}
          className="block w-full text-sm text-slate-300 file:mr-3 file:rounded-md file:border-0 file:bg-slate-800 file:px-3 file:py-2 file:text-slate-200 hover:file:bg-slate-700"
        />
        {file && (
          <p className="mt-2 text-xs text-slate-400">
            {t('bootstrap.selected', { name: file.name })}
          </p>
        )}
        <div className="mt-3 flex flex-wrap gap-2">
          <Button onClick={() => void upload()} disabled={!file || busy}>
            {busy ? t('bootstrap.uploading') : t('bootstrap.upload')}
          </Button>
          {file && (
            <Button
              variant="outline"
              onClick={() => {
                setFile(null)
                setHeaderError(null)
                setReport(null)
                if (inputRef.current) inputRef.current.value = ''
              }}
            >
              {t('common.cancel')}
            </Button>
          )}
        </div>
      </div>

      {report && (
        <div className="rounded-lg border border-slate-800 p-4">
          <SectionHeader
            title={t('bootstrap.summary')}
            action={
              report.failed > 0 && report.failed_csv_base64 ? (
                <Button variant="outline" size="sm" onClick={downloadFailed}>
                  ⬇ {t('bootstrap.downloadFailed')}
                </Button>
              ) : undefined
            }
          />
          <div className="mb-3 flex flex-wrap gap-2 text-sm">
            <Badge tone="green">{t('bootstrap.created', { count: report.created })}</Badge>
            <Badge tone={report.failed > 0 ? 'red' : 'slate'}>
              {t('bootstrap.failed', { count: report.failed })}
            </Badge>
          </div>
          {report.failed > 0 && (
            <p className="mb-3 text-xs text-slate-400">{t('bootstrap.failedHelp')}</p>
          )}
          <ul className="space-y-1 text-xs">
            {report.results.map((result) => (
              <li
                key={`${result.row}-${result.email}`}
                className="flex flex-wrap items-center gap-2 rounded-md border border-slate-800 px-2 py-1.5"
              >
                <span className="text-slate-500">{t('bootstrap.row', { row: result.row })}</span>
                <span className="font-mono text-slate-200">{result.email || '—'}</span>
                <Badge tone={result.ok ? 'green' : 'red'}>{result.code}</Badge>
                {result.reason && <span className="text-red-300">{result.reason}</span>}
              </li>
            ))}
          </ul>
          {report.results.length === 0 && (
            <p className="py-4 text-center text-xs text-slate-400">{t('bootstrap.empty')}</p>
          )}
        </div>
      )}
    </div>
  )
}

