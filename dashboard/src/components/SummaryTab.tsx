import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { ClientGroup } from '../kairos'
import { formatDuration } from '../lib/format'
import {
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
} from '@/components/ui/collapsible'
import { Card } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'

// Client → Project tree. Each node shows total + billable duration; the
// "unassigned client" and "no project" buckets are already sorted last by the
// reducer. Default-expanded; click a client to collapse.
export function SummaryTab({ groups }: { groups: ClientGroup[] }) {
  const { t } = useTranslation()
  if (!groups.length) {
    return <div className="py-6 text-center text-sm text-muted-foreground">{t('no_data')}</div>
  }
  return (
    <div className="space-y-3">
      {groups.map((g, i) => <Group key={`${g.client_id ?? 'none'}-${i}`} group={g} />)}
    </div>
  )
}

function Group({ group }: { group: ClientGroup }) {
  const { t } = useTranslation()
  const [open, setOpen] = useState(true)
  const name = group.client_name ?? t('unassigned')
  const muted = group.client_id === null
  return (
    <Card className="p-0 overflow-hidden">
      <Collapsible open={open} onOpenChange={setOpen}>
        <CollapsibleTrigger className="w-full flex items-center justify-between px-3 py-2 hover:bg-muted/50 transition-colors">
          <span className="flex items-center gap-2 font-medium">
            <span className="text-xs text-muted-foreground">{open ? '▼' : '▶'}</span>
            <span className={muted ? 'text-muted-foreground' : ''}>{name}</span>
            <Badge variant="secondary" className="font-normal">{group.projects.length}</Badge>
          </span>
          <span className="flex items-center gap-4 text-sm tabular-nums">
            <span className="text-muted-foreground">{formatDuration(group.billable_seconds)} {t('billable')}</span>
            <span className="font-medium">{formatDuration(group.total_seconds)}</span>
          </span>
        </CollapsibleTrigger>
        <CollapsibleContent>
          {group.projects.map((p, i) => {
            const pname = p.project ?? t('no_project')
            const isUnassigned = p.project === null
            return (
              <div
                key={`${pname}-${i}`}
                className="flex items-center justify-between px-3 py-1.5 border-t text-sm"
              >
                <span className={`pl-6 ${isUnassigned ? 'text-muted-foreground' : ''}`}>{pname}</span>
                <span className="flex items-center gap-4 tabular-nums">
                  <span className="text-muted-foreground">{formatDuration(p.billable_seconds)}</span>
                  <span>{formatDuration(p.total_seconds)}</span>
                </span>
              </div>
            )
          })}
        </CollapsibleContent>
      </Collapsible>
    </Card>
  )
}
