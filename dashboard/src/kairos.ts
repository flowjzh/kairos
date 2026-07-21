// Host-agnostic client. `invoke` is injected by the WKWebView host (or, under a
// future Tauri/Windows host, by the Tauri transport). Falls back to rejecting
// when no host is present (e.g. opened in a plain browser) so the UI shows a
// clear error instead of hanging.

export interface SeriesMeta { source: string; display_name: string }
export interface Bucket { start: number; values: number[]; total: number }
export interface Timeline { bucket_seconds: number; series: SeriesMeta[]; buckets: Bucket[] }
export interface ProjectRow { project: string | null; total_seconds: number; billable_seconds: number }
export interface ClientGroup {
  client_id: number | null
  client_name: string | null
  total_seconds: number
  billable_seconds: number
  projects: ProjectRow[]
}
export interface Overview {
  timeline: Timeline
  summary: ClientGroup[]
  total: number
  total_seconds: number
}
export interface SegmentRow {
  start: number
  seconds: number
  source: string
  project: string | null
  client: string | null
  title: string | null
  billable: boolean
}
export interface SegmentsPage { segments: SegmentRow[]; total: number }

interface KairosHost {
  invoke(method: string, params: Record<string, unknown>): Promise<unknown>
}

const host = (window as unknown as { kairos?: KairosHost }).kairos

export async function overview(from: number, to: number): Promise<Overview> {
  if (!host) throw new Error('Kairos host not available')
  return host.invoke('report.overview', { from, to }) as Promise<Overview>
}

export async function segments(from: number, to: number, offset: number, limit: number): Promise<SegmentsPage> {
  if (!host) throw new Error('Kairos host not available')
  return host.invoke('report.segments', { from, to, offset, limit }) as Promise<SegmentsPage>
}
