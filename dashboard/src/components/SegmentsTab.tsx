import { Fragment, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { segments, type SegmentRow } from '../kairos'
import type { Range } from '../lib/range'
import { formatDurationSec, formatRowTime } from '../lib/format'
import { Skeleton } from '@/components/ui/skeleton'
import { Button } from '@/components/ui/button'

const PAGE = 100
// Start | Duration | Source | Title(flex) | Project | Client | Billable.
// One grid container for the header + every row so the `auto` tracks size to the
// widest cell across ALL rows → columns align (per-row grids would each size
// independently and misalign). Title is minmax(8rem,1fr) → remaining space.
const COLS = 'grid-cols-[auto_auto_auto_minmax(8rem,1fr)_auto_auto_auto]'
// Must match the track count in COLS above.
const COL_COUNT = 7

const DASH = <span className="text-muted-foreground">—</span>

// Waits for `ready` (overview loaded on the host) before its first fetch, so the
// daemon's per-range memo is warm and this request does not re-run attribution.
export function SegmentsTab({ range, ready }: { range: Range; ready: boolean }) {
  const { t } = useTranslation()
  const [rows, setRows] = useState<SegmentRow[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(0)
  const [loading, setLoading] = useState(false)

  useEffect(() => {
    setPage(0)
  }, [range.from, range.to])

  useEffect(() => {
    if (!ready) return
    let cancelled = false
    setLoading(true)
    segments(range.from, range.to, page * PAGE, PAGE)
      .then((res) => {
        if (cancelled) return
        setRows(res.segments)
        setTotal(res.total)
      })
      .catch(() => { if (!cancelled) { setRows([]); setTotal(0) } })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [range.from, range.to, page, ready])

  const pages = Math.max(1, Math.ceil(total / PAGE))

  return (
    <div>
      <div className="flex items-center justify-between mb-2 text-sm text-muted-foreground">
        <span>{total.toLocaleString()} {t('segments_unit')}</span>
        <div className="flex items-center gap-2">
          <Button variant="outline" size="sm" disabled={page === 0} onClick={() => setPage((p) => Math.max(0, p - 1))}>
            ‹ {t('prev')}
          </Button>
          <span>{t('page_of', { page: page + 1, total: pages })}</span>
          <Button variant="outline" size="sm" disabled={page + 1 >= pages} onClick={() => setPage((p) => p + 1)}>
            {t('next')} ›
          </Button>
        </div>
      </div>

      <div className={`grid ${COLS} gap-x-5 text-sm`}>
        {/* Header */}
        <div className="font-medium py-1.5 text-muted-foreground">{t('col.start')}</div>
        <div className="font-medium py-1.5 text-muted-foreground">{t('col.duration')}</div>
        <div className="font-medium py-1.5 text-muted-foreground">{t('col.source')}</div>
        <div className="font-medium py-1.5 text-muted-foreground min-w-0">{t('col.title')}</div>
        <div className="font-medium py-1.5 text-muted-foreground">{t('col.project')}</div>
        <div className="font-medium py-1.5 text-muted-foreground">{t('col.client')}</div>
        <div className="font-medium py-1.5 text-muted-foreground">{t('col.billable')}</div>

        {/* One full-width divider (col-span-full) per row — it spans the column
            gaps, so the line stays continuous however wide gap-x is. Per-cell
            border-t would break at every gap. A keyed Fragment inlines its cells
            into the grid (no wrapper DOM). */}
        {loading ? (
          Array.from({ length: 12 }).map((_, i) => (
            <Fragment key={i}>
              <div className="col-span-full h-px bg-border" />
              {Array.from({ length: COL_COUNT }).map((_, j) => (
                <div key={j} className="py-1.5"><Skeleton className="h-3.5 w-full" /></div>
              ))}
            </Fragment>
          ))
        ) : rows.length === 0 ? (
          <div className="col-span-full py-6 text-center text-muted-foreground">{t('no_segments')}</div>
        ) : (
          rows.map((r) => (
            <Fragment key={r.start}>
              <div className="col-span-full h-px bg-border" />
              <div className="py-1.5 whitespace-nowrap">{formatRowTime(r.start)}</div>
              <div className="py-1.5 tabular-nums whitespace-nowrap">{formatDurationSec(r.seconds)}</div>
              <div className="py-1.5 whitespace-nowrap">{r.source}</div>
              <div className="py-1.5 min-w-0 truncate">{r.title ?? DASH}</div>
              <div className="py-1.5 whitespace-nowrap">{r.project ?? DASH}</div>
              <div className="py-1.5 whitespace-nowrap">{r.client ?? DASH}</div>
              <div className="py-1.5 text-center">{r.billable ? '✓' : ''}</div>
            </Fragment>
          ))
        )}
      </div>
    </div>
  )
}
