'''The Kairos socket client.

The daemon speaks line-JSON over a Unix domain socket, one request per
connection (docs/05): open the socket, write one request line, read one
response line, close. A single `segments.get` round-trip returns every segment
in the range — there is no pagination.
'''
from __future__ import annotations

import json
import socket
from pathlib import Path

from .models import Segment, parse_segments_result

DEFAULT_SOCKET = Path.home() / '.kairos' / 'daemon.sock'


class KairosError(Exception):
    '''A daemon-returned error or a transport failure.'''


class Kairos:
    def __init__(self, socket_path: str | Path = DEFAULT_SOCKET):
        self.socket_path = str(socket_path)

    def segments(self, start: float, end: float, project: str | None = None,
                 client: int | None = None) -> list[Segment]:
        '''All attributed segments in `[start, end]` (epoch seconds), optionally
        filtered by project slug and/or client id. Segments are joined to their
        activities and ordered by start.'''
        params: dict[str, object] = {'from': start, 'to': end}
        if project is not None:
            params['project'] = project
        if client is not None:
            params['client'] = client
        return parse_segments_result(self._call('segments.get', params))

    def _call(self, method: str, params: dict[str, object]) -> dict:
        request = json.dumps({'method': method, 'params': params}) + '\n'
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
                sock.connect(self.socket_path)
                sock.sendall(request.encode())
                line = sock.makefile('rb').readline()   # one line, then the daemon closes
        except OSError as e:
            raise KairosError(f'cannot reach daemon at {self.socket_path}: {e}') from e
        if not line:
            raise KairosError('daemon closed the connection with no response')
        response = json.loads(line)
        if error := response.get('error'):
            raise KairosError(f'{error.get("code")}: {error.get("message")}')
        return response.get('result', {})
