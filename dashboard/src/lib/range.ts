// Range presets resolve to [from, to] epoch seconds in the local timezone.
// Week start follows the Swift-chosen locale's CLDR first weekday (Intl.Locale
// weekInfo); falls back to Monday.

import { intlLocale } from './locale'

export type Preset = 'today' | 'week' | 'month' | 'custom'

export interface Range { from: number; to: number; preset: Preset }

function startOfDay(d: Date): number {
  const x = new Date(d)
  x.setHours(0, 0, 0, 0)
  return Math.floor(x.getTime() / 1000)
}

/** CLDR first weekday (1=Mon..7=Sun) for the host locale, defaulting to Monday. */
function localeFirstDay(): number {
  try {
    // `weekInfo` is a runtime API not yet in TS lib types; WKWebView ships it.
    const locale = new Intl.Locale(intlLocale()) as Intl.Locale & {
      weekInfo?: { firstDay?: number }
    }
    const fd = locale.weekInfo?.firstDay
    if (fd && fd >= 1 && fd <= 7) return fd
  } catch {
    // Intl.Locale.weekInfo unsupported — fall through to default.
  }
  return 1
}

export function now(): number { return Math.floor(Date.now() / 1000) }

export function presetRange(preset: Exclude<Preset, 'custom'>): Range {
  const t = now()
  const today = new Date()
  switch (preset) {
    case 'today':
      return { from: startOfDay(today), to: t, preset: 'today' }
    case 'week': {
      const firstDay = localeFirstDay()
      const jsDay = today.getDay() // 0=Sun..6=Sat → 1=Mon..7=Sun
      const dayOfWeek = jsDay === 0 ? 7 : jsDay
      const offset = (dayOfWeek - firstDay + 7) % 7
      return { from: startOfDay(today) - offset * 86400, to: t, preset: 'week' }
    }
    case 'month': {
      const x = new Date(today.getFullYear(), today.getMonth(), 1)
      return { from: Math.floor(x.getTime() / 1000), to: t, preset: 'month' }
    }
  }
}

/** Parse a YYYY-MM-DD date input as local midnight epoch. */
export function dateInputToEpoch(s: string): number | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s)
  if (!m) return null
  const x = new Date(+m[1], +m[2] - 1, +m[3], 0, 0, 0, 0)
  return Math.floor(x.getTime() / 1000)
}

export function epochToDateInput(epoch: number): string {
  const d = new Date(epoch * 1000)
  const mm = String(d.getMonth() + 1).padStart(2, '0')
  const dd = String(d.getDate()).padStart(2, '0')
  return `${d.getFullYear()}-${mm}-${dd}`
}
