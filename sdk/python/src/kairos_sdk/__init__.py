'''Kairos Python SDK — a thin consumer wrapper over the daemon's line-JSON
socket (docs/05, docs/08). Exposes `segments.get` as typed models.'''
from .client import DEFAULT_SOCKET, Kairos, KairosError
from .models import Activity, Client, Segment, parse_segments_result

__all__ = [
    'Kairos', 'KairosError', 'DEFAULT_SOCKET',
    'Segment', 'Activity', 'Client', 'parse_segments_result',
]
