use std::collections::HashMap;

use kairos_report::*;

fn act(source: &str, project: Option<&str>, client: Option<(i64, &str)>, billable: bool) -> Activity {
    Activity {
        source: source.to_string(),
        display_name: source.to_uppercase(),
        project: project.map(str::to_string),
        title: None,
        client_id: client.map(|(id, _)| id),
        client_name: client.map(|(_, n)| n.to_string()),
        billable,
    }
}

fn seg(activity_id: i64, start: f64, end: f64) -> Segment {
    Segment { activity_id, start, end, seconds: end - start }
}

#[test]
fn timeline_splits_across_buckets_and_zero_fills() {
    // 10-min span → 5-min ladder step → two buckets [0,300),[300,600).
    let activities = HashMap::from([(1, act("a", None, None, true)), (2, act("b", None, None, true))]);
    let segments = [seg(1, 100.0, 400.0), seg(2, 0.0, 300.0)];

    let t = timeline_of(&segments, &activities);
    assert_eq!(t.bucket_seconds, 300.0);
    assert_eq!(t.buckets.len(), 2);
    assert_eq!(t.series, vec![
        SeriesMeta { source: "a".into(), display_name: "A".into() },
        SeriesMeta { source: "b".into(), display_name: "B".into() },
    ]);
    // a: 200 in bucket0, 100 in bucket1; b: 300 in bucket0 only (zero-filled after).
    assert_eq!(t.buckets[0].values, vec![200.0, 300.0]);
    assert_eq!(t.buckets[0].total, 500.0);
    assert_eq!(t.buckets[1].values, vec![100.0, 0.0]);
    assert_eq!(t.buckets[1].total, 100.0);
}

#[test]
fn adaptive_width_scales_with_span() {
    let a = HashMap::from([(1, act("a", None, None, true))]);
    let s = [seg(1, 0.0, 1.0)];
    // day → hourly (86400/3600 = 24 ≤ 90); month → daily (2_592_000/86400 = 30).
    assert_eq!(overview(&s, &a, 0.0, 86_400.0).timeline.bucket_seconds, 3600.0);
    assert_eq!(overview(&s, &a, 0.0, 2_592_000.0).timeline.bucket_seconds, 86_400.0);
}

#[test]
fn summary_groups_sorts_and_buckets_unassigned_last() {
    let activities = HashMap::from([
        (1, act("x", Some("p1"), Some((1, "Acme")), true)),
        (2, act("x", None, Some((1, "Acme")), false)),
        (3, act("y", Some("p2"), None, true)),
    ]);
    let segments = [seg(1, 0.0, 300.0), seg(2, 0.0, 120.0), seg(3, 0.0, 60.0)];

    let groups = overview(&segments, &activities, 0.0, 600.0).summary;
    // Acme (420) before unassigned (60); unassigned always last.
    assert_eq!(groups[0].client_id, Some(1));
    assert_eq!(groups[0].total_seconds, 420.0);
    assert_eq!(groups[0].billable_seconds, 300.0);
    // Within Acme: p1 (300) then the no-project bucket (120) last.
    assert_eq!(groups[0].projects[0].project, Some("p1".into()));
    assert_eq!(groups[0].projects[1].project, None);
    assert_eq!(groups[0].projects[1].billable_seconds, 0.0);

    assert_eq!(groups[1].client_id, None);
    assert_eq!(groups[1].total_seconds, 60.0);
}

#[test]
fn segments_page_is_newest_first_and_paged() {
    let activities = HashMap::from([(1, act("a", Some("p"), Some((1, "Acme")), true))]);
    let segments = [seg(1, 100.0, 200.0), seg(1, 500.0, 560.0), seg(1, 300.0, 330.0)];

    let page = segments_page(&segments, &activities, 0, 2);
    assert_eq!(page.total, 3);
    assert_eq!(page.segments.len(), 2);
    assert_eq!(page.segments[0].start, 500.0); // newest first
    assert_eq!(page.segments[1].start, 300.0);
    assert_eq!(page.segments[0].source, "A");
    assert_eq!(page.segments[0].client, Some("Acme".into()));

    let page2 = segments_page(&segments, &activities, 2, 2);
    assert_eq!(page2.segments.len(), 1);
    assert_eq!(page2.segments[0].start, 100.0);
}

#[test]
fn unresolvable_segments_are_skipped() {
    let activities = HashMap::from([(1, act("a", None, None, true))]);
    let segments = [seg(1, 0.0, 100.0), seg(99, 0.0, 100.0)]; // 99 has no activity
    let o = overview(&segments, &activities, 0.0, 600.0);
    assert_eq!(o.total, 1);
    assert_eq!(o.total_seconds, 100.0);
}

// Small helper: pull just the timeline for the fixed 0..600 window used above.
fn timeline_of(segments: &[Segment], activities: &HashMap<i64, Activity>) -> Timeline {
    overview(segments, activities, 0.0, 600.0).timeline
}
