'''Typed read models for the Kairos SDK.

These mirror the `segments.get` wire shape (docs/05): a flat `segments` array
plus an `activities` map keyed by stringified id. `parse_segments_result` joins
each segment to its activity so a consumer can reach
`segment.activity.transcript_path` directly.
'''
from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class Client:
    id: int
    name: str


@dataclass(frozen=True)
class Activity:
    '''An activity with its client/billable already resolved by the daemon.'''
    id: int
    source: str
    external_id: str | None
    project: str | None
    title: str | None
    client: Client | None
    billable: bool
    metadata: dict[str, Any]

    @property
    def transcript_path(self) -> str | None:
        '''The AI transcript file, when the source recorded one (docs/08).'''
        return self.metadata.get('transcript_path')

    @property
    def is_ai(self) -> bool:
        return self.transcript_path is not None


@dataclass(frozen=True)
class Segment:
    '''A computed attributed-time block joined to its activity. `seconds` is the
    afk/pause-subtracted human time (docs/04); it is the effort measure — never
    recompute it from end - start.'''
    activity_id: int
    start: float
    end: float
    seconds: float
    rule: str
    activity: Activity


def _parse_activity(id_: int, raw: dict[str, Any]) -> Activity:
    client = raw.get('client')
    return Activity(
        id=id_,
        source=raw['source'],
        external_id=raw.get('external_id'),
        project=raw.get('project'),
        title=raw.get('title'),
        client=Client(id=client['id'], name=client['name']) if client else None,
        billable=raw.get('billable', True),
        metadata=raw.get('metadata') or {},
    )


def parse_segments_result(result: dict[str, Any]) -> list[Segment]:
    '''Turn a raw `segments.get` result into joined `Segment`s, ordered by start.'''
    activities = {(i := int(k)): _parse_activity(i, v) for k, v in result.get('activities', {}).items()}
    segments = []
    for s in result.get('segments', []):
        activity = activities.get(s['activity_id'])
        if activity is None:
            raise KeyError(f'segment references unknown activity {s["activity_id"]}')
        segments.append(Segment(
            activity_id=s['activity_id'], start=s['start'], end=s['end'],
            seconds=s['seconds'], rule=s['rule'], activity=activity))
    segments.sort(key=lambda s: s.start)
    return segments
