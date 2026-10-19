//! File downloads. Each goes to ~/Downloads under a name no file there has
//! yet, and every change of state is reported to the app, which shows them.
//! Everything here runs on the CEF UI thread, the main thread.

use cef::*;
use std::{
    cell::{Cell, RefCell},
    collections::{HashMap, HashSet},
    ffi::{CString, c_char, c_void},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

/// Mirrors `TillerDownloadCallback` in tiller_core.h: the tab's browser id,
/// the download's profile (its request context's id) and id, path, url, the url before redirects, bytes received,
/// bytes in all (-1 when unknown), and a state: 0 in progress, 1 complete,
/// 2 canceled, 3 failed.
pub type Callback =
    unsafe extern "C" fn(*mut c_void, i32, i32, u32, *const c_char, *const c_char, *const c_char, i64, i64, i32);

/// Each profile has its own download manager, which numbers its downloads
/// from 1, so a download is known by its request context's id (see
/// `browser::context_of`) and its own.
type Key = (i32, u32);

thread_local! {
    static HANDLER: Cell<Option<(*mut c_void, Callback)>> = const { Cell::new(None) };
    /// The callback last handed over for each download still under way.
    static CALLBACKS: RefCell<HashMap<Key, DownloadItemCallback>> = RefCell::new(HashMap::new());
    /// Downloads asked to cancel, until they end. A callback kept from an
    /// earlier report doesn't cancel, so each new report's does it.
    static CANCELING: RefCell<HashSet<Key>> = RefCell::new(HashSet::new());
    /// Paths handed to downloads still under way, which don't exist on disk
    /// yet, so a second download of the same file gets another name.
    static RESERVED: RefCell<HashMap<Key, PathBuf>> = RefCell::new(HashMap::new());
    /// For each download under way: when its progress was last reported,
    /// and the latest report held back since, waiting for its turn.
    static THROTTLE: RefCell<HashMap<Key, Throttle>> = RefCell::new(HashMap::new());
}

/// Chromium reports progress for every chunk received, far more often than
/// a progress ring can show. Progress is passed on at most this often; a
/// change of state always is, and a report held back goes out when the
/// interval is up, so a download that then stalls isn't shown behind.
const PROGRESS_INTERVAL: Duration = Duration::from_millis(100);

struct Throttle {
    last: Instant,
    /// The most recent report not passed on, if any.
    held: Option<Report>,
    /// Whether a task to send the held report is on its way.
    scheduled: bool,
}

/// What the app is told about a download, as `report` sends it.
#[derive(Clone)]
struct Report {
    browser_id: i32,
    context: i32,
    id: u32,
    path: CString,
    url: CString,
    original: CString,
    received: i64,
    total: i64,
    state: i32,
}

impl Report {
    fn of(context: i32, browser: Option<&mut Browser>, item: &DownloadItem) -> Report {
        let state = if item.is_complete() != 0 {
            1
        } else if item.is_canceled() != 0 {
            2
        } else if item.is_interrupted() != 0 {
            3
        } else {
            0
        };
        Report {
            browser_id: browser.map_or(-1, |b| b.identifier()),
            context,
            id: item.id(),
            path: to_cstring(CefString::from(&item.full_path()).to_string()),
            url: to_cstring(CefString::from(&item.url()).to_string()),
            original: to_cstring(CefString::from(&item.original_url()).to_string()),
            received: item.received_bytes(),
            total: item.total_bytes(),
            state,
        }
    }

    fn send(&self) {
        let Some((ctx, handler)) = HANDLER.get() else { return };
        unsafe {
            handler(
                ctx,
                self.browser_id,
                self.context,
                self.id,
                self.path.as_ptr(),
                self.url.as_ptr(),
                self.original.as_ptr(),
                self.received,
                self.total,
                self.state,
            )
        };
    }
}

// Sends the report held back for a download once the interval is up.
wrap_task! {
    struct HeldReportTask {
        context: i32,
        id: u32,
    }

    impl Task {
        fn execute(&self) {
            let held = THROTTLE.with_borrow_mut(|map| {
                let entry = map.get_mut(&(self.context, self.id))?;
                entry.scheduled = false;
                let held = entry.held.take()?;
                entry.last = Instant::now();
                Some(held)
            });
            if let Some(report) = held {
                report.send();
            }
        }
    }
}

pub fn set_handler(ctx: *mut c_void, handler: Option<Callback>) {
    HANDLER.set(handler.map(|h| (ctx, h)));
}

/// Cancels download `id` of the profile whose request context is `context`.
/// The download's next report cancels it with the callback that comes with
/// it; the kept one is tried too, for a download that has stalled.
pub fn cancel(context: i32, id: u32) {
    let key = (context, id);
    let Some(callback) = CALLBACKS.with_borrow(|map| map.get(&key).cloned()) else { return };
    CANCELING.with_borrow_mut(|set| set.insert(key));
    callback.cancel();
}

fn downloads_folder() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home).join("Downloads")
}

/// `name` in `folder`, or the first of `name-2`, `name-3`… that no file has
/// and no download under way is about to make.
fn unique_path(folder: &Path, name: &str) -> PathBuf {
    let name = if name.is_empty() { "download" } else { name };
    let taken = |path: &PathBuf| path.exists() || RESERVED.with_borrow(|map| map.values().any(|p| p == path));
    let first = folder.join(name);
    if !taken(&first) {
        return first;
    }
    let (stem, extension) = match name.rsplit_once('.') {
        Some((stem, extension)) if !stem.is_empty() => (stem, format!(".{extension}")),
        _ => (name, String::new()),
    };
    (2..)
        .map(|n| folder.join(format!("{stem}-{n}{extension}")))
        .find(|path| !taken(path))
        .expect("an unused name")
}

fn to_cstring(s: String) -> CString {
    CString::new(s).unwrap_or_else(|e| {
        let mut bytes = e.into_vec();
        bytes.retain(|&b| b != 0);
        CString::new(bytes).unwrap_or_default()
    })
}

fn report(context: i32, browser: Option<&mut Browser>, item: &DownloadItem) {
    if HANDLER.get().is_some() {
        Report::of(context, browser, item).send();
    }
}

fn context_of(browser: &Option<&mut Browser>) -> i32 {
    browser.as_deref().map_or(0, crate::browser::context_of)
}

wrap_download_handler! {
    pub struct TillerDownloadHandler;

    impl DownloadHandler {
        fn can_download(&self, _browser: Option<&mut Browser>, _url: Option<&CefString>, _request_method: Option<&CefString>) -> i32 {
            1
        }

        /// Picks the file's path. Without this CEF drops the download.
        fn on_before_download(
            &self,
            browser: Option<&mut Browser>,
            download_item: Option<&mut DownloadItem>,
            suggested_name: Option<&CefString>,
            callback: Option<&mut BeforeDownloadCallback>,
        ) -> i32 {
            let (Some(item), Some(callback)) = (download_item, callback) else { return 0 };
            let folder = downloads_folder();
            let _ = std::fs::create_dir_all(&folder);
            let path = unique_path(&folder, &suggested_name.map(|s| s.to_string()).unwrap_or_default());
            let context = context_of(&browser);
            RESERVED.with_borrow_mut(|map| map.insert((context, item.id()), path.clone()));
            callback.cont(Some(&CefString::from(path.to_string_lossy().as_ref())), 0);
            report(context, browser, item);
            1
        }

        fn on_download_updated(
            &self,
            browser: Option<&mut Browser>,
            download_item: Option<&mut DownloadItem>,
            callback: Option<&mut DownloadItemCallback>,
        ) {
            let Some(item) = download_item else { return };
            let context = context_of(&browser);
            let key = (context, item.id());
            if item.is_in_progress() != 0 {
                if let Some(callback) = callback {
                    if CANCELING.with_borrow(|set| set.contains(&key)) {
                        callback.cancel();
                    }
                    CALLBACKS.with_borrow_mut(|map| map.insert(key, callback.clone()));
                }
                if HANDLER.get().is_none() {
                    return;
                }
                let now = Instant::now();
                // Too soon after the last one: hold it, and have it sent
                // once the interval is up unless a newer one replaces it.
                // Chromium calls this for every chunk, so a report already
                // held only takes the new byte counts: its path and addresses
                // don't change while the download runs.
                let schedule = THROTTLE.with_borrow_mut(|map| {
                    let entry = map.entry(key).or_insert(Throttle { last: now - PROGRESS_INTERVAL, held: None, scheduled: false });
                    if now.duration_since(entry.last) >= PROGRESS_INTERVAL {
                        entry.last = now;
                        entry.held = None;
                        Ok(Report::of(context, browser, item))
                    } else {
                        match &mut entry.held {
                            Some(held) => {
                                held.received = item.received_bytes();
                                held.total = item.total_bytes();
                            }
                            None => entry.held = Some(Report::of(context, browser, item)),
                        }
                        let schedule = !entry.scheduled;
                        entry.scheduled = true;
                        Err(schedule)
                    }
                });
                match schedule {
                    Ok(report) => report.send(),
                    Err(true) => {
                        let mut task = HeldReportTask::new(context, key.1);
                        post_delayed_task(ThreadId::UI, Some(&mut task), PROGRESS_INTERVAL.as_millis() as i64);
                    }
                    Err(false) => {}
                }
                return;
            }
            CALLBACKS.with_borrow_mut(|map| map.remove(&key));
            CANCELING.with_borrow_mut(|set| set.remove(&key));
            let first = RESERVED.with_borrow_mut(|map| map.remove(&key)).is_some();
            THROTTLE.with_borrow_mut(|map| map.remove(&key));
            if first && item.is_complete() != 0 {
                bounce_downloads_stack(&CefString::from(&item.full_path()).to_string());
            }
            report(context, browser, item);
        }
    }
}

/// Tells the Dock that `path` finished downloading, as Safari and Chrome do,
/// which bounces the Downloads stack.
fn bounce_downloads_stack(path: &str) {
    use objc2_foundation::{NSDistributedNotificationCenter, NSString};
    let name = NSString::from_str("com.apple.DownloadFileFinished");
    let path = NSString::from_str(path);
    unsafe { NSDistributedNotificationCenter::defaultCenter().postNotificationName_object(&name, Some(&path)) };
}
