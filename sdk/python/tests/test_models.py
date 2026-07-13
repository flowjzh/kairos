from kairos_sdk import parse_segments_result


def sample_result() -> dict:
    return {
        'segments': [
            {'activity_id': 7, 'start': 200.0, 'end': 260.0, 'seconds': 60.0, 'rule': 'explicit'},
            {'activity_id': 4, 'start': 100.0, 'end': 190.0, 'seconds': 90.0, 'rule': 'ai'},
        ],
        'activities': {
            '4': {'source': 'claude-code', 'external_id': 's4', 'project': 'kairos',
                  'billable': True,
                  'metadata': {'transcript_path': '/tmp/t.jsonl', 'cwd': '/x'}},
            '7': {'source': 'manual', 'title': 'Client Meeting', 'billable': True,
                  'client': {'id': 1, 'name': 'Acme'}},
        },
    }


def test_joins_and_orders_by_start():
    segs = parse_segments_result(sample_result())
    # ordered by start: activity 4 (100) before 7 (200)
    assert [s.activity_id for s in segs] == [4, 7]
    assert segs[0].seconds == 90.0
    assert segs[0].activity.project == 'kairos'


def test_ai_activity_exposes_transcript():
    segs = parse_segments_result(sample_result())
    ai = next(s for s in segs if s.activity_id == 4)
    assert ai.activity.is_ai
    assert ai.activity.transcript_path == '/tmp/t.jsonl'


def test_manual_activity_has_client_no_transcript():
    segs = parse_segments_result(sample_result())
    meeting = next(s for s in segs if s.activity_id == 7)
    assert not meeting.activity.is_ai
    assert meeting.activity.transcript_path is None
    assert meeting.activity.client.name == 'Acme'
    assert meeting.activity.title == 'Client Meeting'


def test_empty_result():
    assert parse_segments_result({}) == []
