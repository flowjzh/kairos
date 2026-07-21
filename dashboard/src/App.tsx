import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { overview, type Overview } from './kairos'
import { Chart } from './components/Chart'
import { SegmentsTab } from './components/SegmentsTab'
import { SummaryTab } from './components/SummaryTab'
import {
  epochToDateInput,
  dateInputToEpoch,
  presetRange,
  type Preset,
  type Range,
} from './lib/range'
import { formatDuration } from './lib/format'
import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/ui/tabs'
import { Button } from '@/components/ui/button'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import { Input } from '@/components/ui/input'
import { Card } from '@/components/ui/card'
import { Skeleton } from '@/components/ui/skeleton'
import { RefreshCw } from 'lucide-react'

export default function App() {
  const { t } = useTranslation()
  const [range, setRange] = useState<Range>(() => presetRange('today'))
  const [data, setData] = useState<Overview | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const presets: { value: Exclude<Preset, 'custom'>; key: string }[] = [
    { value: 'today', key: 'range.today' },
    { value: 'week', key: 'range.week' },
    { value: 'month', key: 'range.month' },
  ]

  // Load overview for the current range. SegmentsTab waits for `data` before its
  // own fetch, so the daemon's per-range memo is warm (one attribution pass).
  async function load(r: Range) {
    setLoading(true)
    setError(null)
    try {
      setData(await overview(r.from, r.to))
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
      setData(null)
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    load(range)
  }, [range.from, range.to])

  // Refresh: live presets re-snapshot `to` to now. A frozen `to` is the blocker —
  // the daemon's `ts <= to` filter excludes events past it (the range memo does
  // bust via the events watermark, but that doesn't surface events beyond the frozen
  // bound). Custom keeps its fixed dates. Calling load() directly also covers the
  // custom + same-second cases where the range-change effect wouldn't fire.
  const refresh = () => {
    const next = range.preset === 'custom' ? range : presetRange(range.preset)
    setRange(next)
    load(next)
  }

  return (
    <div className="h-full overflow-auto p-6 sm:p-8">
      <div className="mx-auto max-w-6xl space-y-6">
        <header className="flex flex-wrap items-center gap-2">
          <Select
            value={range.preset === 'custom' ? 'custom' : range.preset}
            onValueChange={(v) => {
              if (v === 'custom') setRange({ ...range, preset: 'custom' })
              else setRange(presetRange(v as Exclude<Preset, 'custom'>))
            }}
          >
            <SelectTrigger className="w-[150px]">
              <SelectValue>
                {(v: string) =>
                  v === 'custom'
                    ? t('range.custom')
                    : t(presets.find((p) => p.value === v)?.key ?? 'range.today')
                }
              </SelectValue>
            </SelectTrigger>
            <SelectContent>
              {presets.map((p) => (
                <SelectItem key={p.value} value={p.value}>{t(p.key)}</SelectItem>
              ))}
              <SelectItem value="custom">{t('range.custom')}</SelectItem>
            </SelectContent>
          </Select>

          {range.preset === 'custom' && (
            <div className="flex items-center gap-1.5">
              <Input
                type="date"
                value={epochToDateInput(range.from)}
                onChange={(e) => {
                  const from = dateInputToEpoch(e.target.value)
                  if (from != null) setRange({ from, to: range.to, preset: 'custom' })
                }}
                className="w-[150px]"
              />
              <span className="text-muted-foreground">→</span>
              <Input
                type="date"
                value={epochToDateInput(range.to)}
                onChange={(e) => {
                  const to = dateInputToEpoch(e.target.value)
                  if (to != null) setRange({ from: range.from, to: to + 86399, preset: 'custom' })
                }}
                className="w-[150px]"
              />
            </div>
          )}

          <Button variant="outline" onClick={refresh} disabled={loading}>
            <RefreshCw className={loading ? 'animate-spin' : undefined} />
            {loading ? t('loading') : t('refresh')}
          </Button>

          {data && (
            <span className="ml-auto text-sm text-muted-foreground tabular-nums">
              {t('header_total', { count: data.total.toLocaleString(), duration: formatDuration(data.total_seconds) })}
            </span>
          )}
        </header>

        <Card className="p-3">
          {error ? (
            <div className="h-[300px] flex items-center justify-center text-sm text-destructive">
              {error}
            </div>
          ) : !data ? (
            <div className="space-y-2 px-2">
              <Skeleton className="h-[260px] w-full" />
            </div>
          ) : data.timeline.series.length === 0 ? (
            <div className="h-[300px] flex items-center justify-center text-sm text-muted-foreground">
              {t('no_activity')}
            </div>
          ) : (
            <Chart timeline={data.timeline} />
          )}
        </Card>

        <Tabs defaultValue="segments">
          <TabsList>
            <TabsTrigger value="segments">{t('tab.segments')}</TabsTrigger>
            <TabsTrigger value="summary">{t('tab.summary')}</TabsTrigger>
          </TabsList>
          <TabsContent value="segments" className="mt-3">
            <SegmentsTab range={range} ready={data != null} />
          </TabsContent>
          <TabsContent value="summary" className="mt-3">
            <SummaryTab groups={data?.summary ?? []} />
          </TabsContent>
        </Tabs>
      </div>
    </div>
  )
}
