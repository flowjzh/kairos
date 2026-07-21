// The locale is chosen by the Swift host (the daemon's AppSettings language) and
// injected as `window.kairos.locale` before the bundle runs — the web app exposes
// no language picker. Resolved to a BCP47 tag for Intl (date/time) formatting.

type KairosGlobal = { kairos?: { locale?: string } }

export function getLocale(): string {
  return (window as unknown as KairosGlobal).kairos?.locale ?? 'en'
}

/** i18next lng key: 'en' or 'zh-Hans'. */
export function i18nLng(): string {
  return getLocale().startsWith('zh') ? 'zh-Hans' : 'en'
}

/** BCP47 for Intl.DateTimeFormat: zh-Hans works; en → en-US for stable dates. */
export function intlLocale(): string {
  return getLocale().startsWith('zh') ? 'zh-Hans' : 'en-US'
}
