//! Pure read-time reducer for the dashboard. Takes the daemon's already-computed
//! attributed segments plus per-activity detail and folds them into the three
//! shapes the dashboard renders: a per-source timeline (adaptive buckets, with a
//! summed total), a client→project summary tree, and a paged list of raw rows.
//!
//! Pure and platform-agnostic: no I/O, no FFI, no clock. The daemon runs
//! attribution (events → segments) in Swift, marshals the result across the C
//! ABI (`ffi/`), and this crate reduces it before it crosses the wire — so a
//! year of segments never ships raw. Output structs are `Serialize`; the `ffi/`
//! layer emits them as JSON (small, aggregated), while the *input* arrives as a
//! flat binary buffer (large).

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

/// One attributed time block (a `focus` segment piece). `seconds == end - start`
/// — attribution already subtracted afk/pause/ai-grind holes, so each piece is
/// contiguous and its length is its attributed time.
#[derive(Debug, Clone)]
pub struct Segment {
    pub activity_id: i64,
    pub start: f64,
    pub end: f64,
    pub seconds: f64,
}

/// The per-activity detail a segment resolves to. `source` is the series slug
/// (stable identity); `display_name` is the human label (the plugin owns it).
/// Field names are snake_case so it deserializes straight from the FFI's
/// activities JSON (no separate wire DTO needed).
#[derive(Debug, Clone, Deserialize)]
pub struct Activity {
    pub source: String,
    pub display_name: String,
    pub project: Option<String>,
    pub title: Option<String>,
    pub client_id: Option<i64>,
    pub client_name: Option<String>,
    pub billable: bool,
}

// --- overview (chart + summary tree + totals) ---

#[derive(Debug, Serialize, PartialEq)]
pub struct SeriesMeta {
    pub source: String,
    pub display_name: String,
}

/// A single time bucket. `values` is aligned to `Timeline::series` order (one
/// entry per source, explicitly `0.0` when idle so the area never breaks);
/// `total` is their sum (the overlaid line).
#[derive(Debug, Serialize, PartialEq)]
pub struct Bucket {
    pub start: f64,
    pub values: Vec<f64>,
    pub total: f64,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct Timeline {
    pub bucket_seconds: f64,
    pub series: Vec<SeriesMeta>,
    pub buckets: Vec<Bucket>,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct ProjectRow {
    /// `None` = the "no project" bucket within a client.
    pub project: Option<String>,
    pub total_seconds: f64,
    pub billable_seconds: f64,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct ClientGroup {
    /// `None` = the "unassigned client" bucket.
    pub client_id: Option<i64>,
    pub client_name: Option<String>,
    pub total_seconds: f64,
    pub billable_seconds: f64,
    pub projects: Vec<ProjectRow>,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct Overview {
    pub timeline: Timeline,
    pub summary: Vec<ClientGroup>,
    pub total: usize,
    pub total_seconds: f64,
}

// --- paged raw rows (tab1) ---

#[derive(Debug, Serialize, PartialEq)]
pub struct SegmentRow {
    pub start: f64,
    pub seconds: f64,
    /// The source's human label (not the slug).
    pub source: String,
    pub project: Option<String>,
    pub client: Option<String>,
    pub title: Option<String>,
    pub billable: bool,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct SegmentsPage {
    pub segments: Vec<SegmentRow>,
    pub total: usize,
}

/// Adaptive bucket width (seconds): the smallest ladder step that keeps the
/// point count at or under `MAX_BUCKETS`, so a day reads hourly and a month
/// daily without ever drawing hundreds of points.
const MAX_BUCKETS: usize = 90;
const WIDTH_LADDER: &[f64] = &[
    300.0,    // 5m
    900.0,    // 15m
    3600.0,   // 1h  → a day reads hourly (24 pts)
    10800.0,  // 3h  → a week reads 3-hourly (56 pts)
    21600.0,  // 6h
    86400.0,  // 1d  → a month reads daily (30 pts)
    604800.0, // 1w  → a half-year reads weekly
];

fn bucket_width(span: f64) -> f64 {
    if span <= 0.0 {
        return WIDTH_LADDER[0];
    }
    WIDTH_LADDER
        .iter()
        .copied()
        .find(|&w| (span / w).ceil() as usize <= MAX_BUCKETS)
        .unwrap_or_else(|| *WIDTH_LADDER.last().unwrap())
}

/// Human label per source slug, resolved to the most recent activity's name
/// (largest id ≈ latest) when a slug carries more than one over the range.
fn display_names(activities: &HashMap<i64, Activity>) -> HashMap<&str, &str> {
    let mut best: HashMap<&str, (i64, &str)> = HashMap::new();
    for (&id, a) in activities {
        let entry = best.entry(a.source.as_str()).or_insert((i64::MIN, a.display_name.as_str()));
        if id >= entry.0 {
            *entry = (id, a.display_name.as_str());
        }
    }
    best.into_iter().map(|(k, (_, name))| (k, name)).collect()
}

fn timeline(segments: &[Segment], activities: &HashMap<i64, Activity>, from: f64, to: f64) -> Timeline {
    let width = bucket_width(to - from);
    let n = (((to - from) / width).ceil() as usize).max(1);

    let names = display_names(activities);
    // Series = distinct sources present, sorted by slug for stable colouring.
    let mut sources: Vec<&str> = segments
        .iter()
        .filter_map(|s| activities.get(&s.activity_id).map(|a| a.source.as_str()))
        .collect();
    sources.sort_unstable();
    sources.dedup();
    let index: HashMap<&str, usize> = sources.iter().enumerate().map(|(i, &s)| (s, i)).collect();

    let mut buckets: Vec<Bucket> = (0..n)
        .map(|i| Bucket { start: from + i as f64 * width, values: vec![0.0; sources.len()], total: 0.0 })
        .collect();

    for seg in segments {
        let Some(a) = activities.get(&seg.activity_id) else { continue };
        let si = index[a.source.as_str()];
        let first = (((seg.start - from) / width).floor() as isize).max(0) as usize;
        let last = (((seg.end - from) / width).floor() as isize).clamp(0, n as isize - 1) as usize;
        for b in first..=last.min(n - 1) {
            let bs = from + b as f64 * width;
            let overlap = seg.end.min(bs + width) - seg.start.max(bs);
            if overlap > 0.0 {
                buckets[b].values[si] += overlap;
                buckets[b].total += overlap;
            }
        }
    }

    let series = sources
        .iter()
        .map(|&s| SeriesMeta { source: s.to_string(), display_name: names.get(s).copied().unwrap_or(s).to_string() })
        .collect();
    Timeline { bucket_seconds: width, series, buckets }
}

/// Build the client/project summary tree and the range totals in a single pass
/// over resolvable segments.
fn summarize(segments: &[Segment], activities: &HashMap<i64, Activity>) -> (Vec<ClientGroup>, usize, f64) {
    // client_id → (client_name, project → (total, billable))
    struct Acc {
        name: Option<String>,
        total: f64,
        billable: f64,
        projects: HashMap<Option<String>, (f64, f64)>,
    }
    let mut clients: HashMap<Option<i64>, Acc> = HashMap::new();
    let mut total = 0usize;
    let mut total_seconds = 0.0;

    for seg in segments {
        let Some(a) = activities.get(&seg.activity_id) else { continue };
        total += 1;
        total_seconds += seg.seconds;
        let acc = clients.entry(a.client_id).or_insert_with(|| Acc {
            name: a.client_name.clone(),
            total: 0.0,
            billable: 0.0,
            projects: HashMap::new(),
        });
        acc.total += seg.seconds;
        let (pt, pb) = acc.projects.entry(a.project.clone()).or_insert((0.0, 0.0));
        *pt += seg.seconds;
        if a.billable {
            acc.billable += seg.seconds;
            *pb += seg.seconds;
        }
    }

    let mut groups: Vec<ClientGroup> = clients
        .into_iter()
        .map(|(client_id, acc)| {
            let mut projects: Vec<ProjectRow> = acc
                .projects
                .into_iter()
                .map(|(project, (total, billable))| ProjectRow { project, total_seconds: total, billable_seconds: billable })
                .collect();
            // Total desc; the "no project" bucket always last.
            projects.sort_by(|a, b| a.project.is_none().cmp(&b.project.is_none()).then(cmp_desc(a.total_seconds, b.total_seconds)));
            ClientGroup {
                client_id,
                client_name: acc.name,
                total_seconds: acc.total,
                billable_seconds: acc.billable,
                projects,
            }
        })
        .collect();
    // Total desc; the "unassigned client" bucket always last.
    groups.sort_by(|a, b| a.client_id.is_none().cmp(&b.client_id.is_none()).then(cmp_desc(a.total_seconds, b.total_seconds)));
    (groups, total, total_seconds)
}

fn cmp_desc(a: f64, b: f64) -> std::cmp::Ordering {
    b.partial_cmp(&a).unwrap_or(std::cmp::Ordering::Equal)
}

/// Reduce to the overview: chart timeline + summary tree + range totals.
pub fn overview(segments: &[Segment], activities: &HashMap<i64, Activity>, from: f64, to: f64) -> Overview {
    let (summary, total, total_seconds) = summarize(segments, activities);
    Overview {
        timeline: timeline(segments, activities, from, to),
        summary,
        total,
        total_seconds,
    }
}

/// One page of raw rows, newest first. `total` is the full resolvable count so
/// the frontend can page without a second query.
pub fn segments_page(segments: &[Segment], activities: &HashMap<i64, Activity>, offset: usize, limit: usize) -> SegmentsPage {
    let mut rows: Vec<(&Segment, &Activity)> = segments
        .iter()
        .filter_map(|s| activities.get(&s.activity_id).map(|a| (s, a)))
        .collect();
    // Start desc, id desc as a deterministic tiebreak.
    rows.sort_by(|(a, _), (b, _)| cmp_desc(a.start, b.start).then(b.activity_id.cmp(&a.activity_id)));

    let total = rows.len();
    let segments = rows
        .into_iter()
        .skip(offset)
        .take(limit)
        .map(|(s, a)| SegmentRow {
            start: s.start,
            seconds: s.seconds,
            source: a.display_name.clone(),
            project: a.project.clone(),
            client: a.client_name.clone(),
            title: a.title.clone(),
            billable: a.billable,
        })
        .collect();
    SegmentsPage { segments, total }
}
