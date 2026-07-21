// Pure formatting helpers. No host calls. Date/time formatters are locale-aware
// via Intl (BCP47 from lib/locale), so they follow the Swift host's language.

import { intlLocale } from './locale'

/** Minute-granular duration: "2h 15m" / "45m". For the chart + summary. */
export function formatDuration(seconds: number): string {
  const total = Math.round(seconds / 60)
  const h = Math.floor(total / 60)
  const m = total % 60
  return h > 0 ? `${h}h ${m}m` : `${m}m`
}

/** Second-granular duration: "1h 2m 3s" / "2m 3s" / "3s". For raw rows. */
export function formatDurationSec(seconds: number): string {
  const s = Math.round(seconds)
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const sec = s % 60
  if (h > 0) return `${h}h ${m}m ${sec}s`
  if (m > 0) return `${m}m ${sec}s`
  return `${sec}s`
}

/** Y-axis tick. Input is the chart's data unit = MINUTES (seconds/60). */
export function formatAxis(minutes: number): string {
  if (minutes < 60) return `${Math.round(minutes)}m`
  const hours = minutes / 60
  return `${hours.toFixed(hours < 10 ? 1 : 0)}h`
}

/**
 * X-axis label for a bucket start. Granularity adapts to the span and bucket
 * width: time-only within a day, date+time for sub-daily buckets across days,
 * date-only for daily/coarser buckets.
 */
export function formatBucketLabel(startEpoch: number, bucketSeconds: number, spanSeconds: number): string {
  const locale = intlLocale()
  const d = new Date(startEpoch * 1000)
  const day = 86400
  if (spanSeconds <= day) {
    return d.toLocaleTimeString(locale, { hour: '2-digit', minute: '2-digit' })
  }
  if (bucketSeconds < day) {
    return d.toLocaleString(locale, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })
  }
  return d.toLocaleDateString(locale, { month: 'short', day: 'numeric' })
}

export function formatRowTime(startEpoch: number): string {
  return new Date(startEpoch * 1000).toLocaleString(intlLocale(), {
    month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit',
  })
}

/** Chart palette by series index, cycling through the five CSS vars. */
export function colorFor(index: number): string {
  const n = (index % 5) + 1
  return `var(--chart-${n})`
}
