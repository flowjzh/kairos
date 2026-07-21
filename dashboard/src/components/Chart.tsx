import { useTranslation } from 'react-i18next'
import {
  Area,
  AreaChart,
  CartesianGrid,
  Line,
  XAxis,
  YAxis,
} from 'recharts'
import {
  ChartContainer,
  ChartLegend,
  ChartLegendContent,
  ChartTooltip,
  ChartTooltipContent,
  type ChartConfig,
} from '@/components/ui/chart'
import type { Timeline } from '../kairos'
import { colorFor, formatAxis, formatBucketLabel } from '../lib/format'

// Flatten the timeline into one row per bucket: { start, [source]: minutes, total }.
// Each source keeps its slug as the dataKey (stable identity); the legend shows
// display_name. Values are minutes (seconds/60) for readable axis ticks.
function toRows(timeline: Timeline) {
  return timeline.buckets.map((b) => {
    const row: Record<string, number> = { start: b.start, total: b.total / 60 }
    timeline.series.forEach((s, i) => {
      row[s.source] = (b.values[i] ?? 0) / 60
    })
    return row
  })
}

export function Chart({ timeline }: { timeline: Timeline }) {
  const { t } = useTranslation()
  const rows = toRows(timeline)
  // The chart's actual extent (bucket count × width), NOT range.to − range.from:
  // a week preset ends at "now", so early in the week the elapsed span is < 1 day
  // and would wrongly render time-only labels. The full bucketed extent is the
  // right signal for "is this a multi-day view".
  const spanSeconds = timeline.buckets.length * timeline.bucket_seconds
  const label = (v: number) => formatBucketLabel(v, timeline.bucket_seconds, spanSeconds)

  // config maps each source slug → { display label, palette color }. The same
  // slug is the Area dataKey + name, so the tooltip/legend resolve through here.
  const config: ChartConfig = {
    total: { label: t('total'), color: 'var(--chart-total)' },
  }
  timeline.series.forEach((s, i) => {
    config[s.source] = { label: s.display_name, color: colorFor(i) }
  })

  return (
    <ChartContainer config={config} className="aspect-auto h-[300px] w-full">
      <AreaChart data={rows} margin={{ top: 8, right: 16, bottom: 0, left: 0 }}>
        <CartesianGrid vertical={false} />
        <XAxis
          dataKey="start"
          tickLine={false}
          axisLine={false}
          tickMargin={8}
          minTickGap={32}
          tickFormatter={label}
        />
        <YAxis
          width={44}
          tickLine={false}
          axisLine={false}
          tickFormatter={formatAxis}
        />
        <ChartTooltip
          itemSorter={(item) => (item.dataKey === 'total' ? 1 : 0)}
          content={
            <ChartTooltipContent
              labelFormatter={(_, p) =>
                p?.[0]?.payload?.start != null ? label(p[0].payload.start) : ''
              }
            />
          }
        />
        {/* Each source: an overlapping translucent area (not stacked). monotone = no overshoot. */}
        {timeline.series.map((s, i) => (
          <Area
            key={s.source}
            type="monotone"
            dataKey={s.source}
            stroke={colorFor(i)}
            fill={colorFor(i)}
            fillOpacity={0.2}
            strokeWidth={1.5}
            isAnimationActive={false}
          />
        ))}
        {/* The overlaid total line on top (not stacked): a bright, semi-transparent accent. */}
        <Line
          type="monotone"
          dataKey="total"
          stroke="var(--chart-total)"
          strokeOpacity={0.75}
          strokeWidth={2}
          dot={false}
          isAnimationActive={false}
        />
        <ChartLegend content={<ChartLegendContent />} />
      </AreaChart>
    </ChartContainer>
  )
}
