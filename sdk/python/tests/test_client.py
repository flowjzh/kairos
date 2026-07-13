import json
import socket
import tempfile
import threading

import pytest

from kairos_sdk import Kairos, KairosError


@pytest.fixture
def sock_path():
    # A short /tmp path — macOS caps AF_UNIX paths at ~104 chars, and pytest's
    # tmp_path is too long.
    with tempfile.TemporaryDirectory(dir='/tmp') as d:
        yield f'{d}/d.sock'


def serve_once(sock_path: str, response_line: bytes, captured: list) -> threading.Thread:
    '''A one-shot Unix server mimicking the daemon: read one request line,
    write one response line, close.'''
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(sock_path)
    server.listen(1)

    def run():
        conn, _ = server.accept()
        with conn:
            buf = bytearray()
            while b'\n' not in buf:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                buf += chunk
            captured.append(bytes(buf).split(b'\n', 1)[0])
            conn.sendall(response_line)
        server.close()

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return thread


def test_segments_sends_request_and_parses(sock_path):

    response = {'result': {
        'segments': [{'activity_id': 1, 'start': 10.0, 'end': 40.0, 'seconds': 30.0, 'rule': 'ai'}],
        'activities': {'1': {'source': 'claude-code', 'billable': True,
                             'metadata': {'transcript_path': '/tmp/t.jsonl'}}},
    }}
    captured: list = []
    thread = serve_once(sock_path, json.dumps(response).encode() + b'\n', captured)

    segs = Kairos(sock_path).segments(10, 100, project='kairos', client=3)
    thread.join(timeout=2)

    request = json.loads(captured[0])
    assert request['method'] == 'segments.get'
    assert request['params'] == {'from': 10, 'to': 100, 'project': 'kairos', 'client': 3}
    assert len(segs) == 1 and segs[0].seconds == 30.0


def test_daemon_error_raises(sock_path):

    response = {'error': {'code': 'bad_request', 'message': 'ts in the future'}}
    thread = serve_once(sock_path, json.dumps(response).encode() + b'\n', [])

    with pytest.raises(KairosError, match='bad_request'):
        Kairos(sock_path).segments(0, 1)
    thread.join(timeout=2)


def test_unreachable_socket_raises(sock_path):
    with pytest.raises(KairosError, match='cannot reach daemon'):
        Kairos(sock_path + ".missing").segments(0, 1)
