//! Browser tools over the running Tiller app's control socket, shared by the
//! `tiller_mcp` server and the `tiller` CLI. Tab operations the app answers itself,
//! and `cdp` calls go to a tab's DevTools agent.

use serde_json::{Value, json};
use std::{
    io::{BufRead, BufReader, Write},
    os::unix::net::UnixStream,
    thread,
    time::Duration,
};

/// How long navigate, new_tab and click wait for a page to finish loading.
const LOAD_TIMEOUT: Duration = Duration::from_secs(30);

/// How long a load gets to start after a click, a submit or a select before
/// the tool returns. Links start theirs at once; this catches the script that
/// navigates a moment later without making every other click wait.
const ACTION_GRACE_MS: u64 = 250;

/// The longest a read waits for a load in progress before reading the page
/// as it is. Long enough for the new page to show; a page still fetching
/// images or ads is worth reading already.
pub(crate) const READ_LOAD_WAIT: Duration = Duration::from_secs(3);

/// The script that reads and acts on pages, as `(op, arg) => result`.
pub(crate) const PAGE_JS: &str = include_str!("page.js");

/// What a tool returns.
pub enum Output {
    Json(Value),
    /// A base64 JPEG.
    Image(String),
}

/// Connection to the running app's control socket, opened on first use and
/// reopened if the app restarts.
#[derive(Default)]
pub struct Browser {
    /// The profile whose Tiller to talk to, by id or name. None means the
    /// one in TILLER_PROFILE, else the one used last.
    pub profile: Option<String>,
    /// Tells a long call, such as run_task, that it has been cancelled.
    pub cancelled: Option<Box<dyn Fn() -> bool>>,
    conn: Option<(UnixStream, BufReader<UnixStream>)>,
    next_id: u64,
}

impl Browser {
    pub fn call_tool(&mut self, name: &str, args: &Value) -> Result<Output, String> {
        let tab = args["tab_id"].as_i64();
        match name {
            "list_tabs" => json_out(self.request("tabs.list", json!({}))?),
            "new_tab" => {
                let mut params = json!({ "select": !args["background"].as_bool().unwrap_or(false) });
                if let Some(url) = args["url"].as_str() {
                    params["url"] = json!(url);
                }
                let info = self.request("tabs.new", params)?;
                let id = info["id"].as_i64().ok_or("the app did not return a tab id")?;
                json_out(self.wait_for_load(id)?)
            }
            "select_tab" => json_out(self.request("tabs.select", json!({ "tab_id": tab.ok_or("tab_id is required")? }))?),
            "close_tab" => json_out(self.request("tabs.close", json!({ "tab_id": tab.ok_or("tab_id is required")? }))?),
            "navigate" => {
                let url = args["url"].as_str().ok_or("url is required")?;
                let info = self.request("tabs.navigate", json!({ "tab_id": tab, "url": url }))?;
                let id = info["id"].as_i64().ok_or("the app did not return a tab id")?;
                json_out(self.wait_for_load(id)?)
            }
            "read_page" => {
                let id = self.resolve(tab)?;
                json_out(self.read(id, args)?)
            }
            "click" => {
                let id = self.wake(tab)?;
                let target = target(args)?;
                let point = self.page(id, "locate", json!({ "target": target }))?;
                self.click_at(id, &point)?;
                let mut info = self.wait_for_load_within(id, ACTION_GRACE_MS)?;
                if point["covered"] == true {
                    info["note"] = json!("another element was on top of the target at its center and got the click");
                }
                json_out(self.read_after(id, Some(&target), false, args, info)?)
            }
            "type" => {
                let id = self.wake(tab)?;
                let value = args["text"].as_str().ok_or("text is required")?;
                let target = if args.get("ref").is_some() || args.get("selector").is_some() { Some(target(args)?) } else { None };
                let mut note = None;
                if let Some(target) = &target {
                    let point = self.page(id, "locate", json!({ "target": target }))?;
                    // A real click first: some fields open their suggestions,
                    // or a field of their own, only when clicked.
                    if point["covered"] != true {
                        self.click_at(id, &point)?;
                    }
                    let append = args["append"].as_bool().unwrap_or(false);
                    let focus = self.page(id, "focus", json!({ "target": target, "append": append }))?;
                    if focus["moved"] == true {
                        note = Some("clicking the field put the focus in another field, which got the text");
                    }
                }
                self.cdp(id, "Input.insertText", json!({ "text": value }))?;
                let mut info = if args["submit"].as_bool().unwrap_or(false) {
                    for kind in ["keyDown", "keyUp"] {
                        let mut key = json!({ "type": kind, "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13 });
                        if kind == "keyDown" {
                            key["text"] = json!("\r");
                        }
                        self.cdp(id, "Input.dispatchKeyEvent", key)?;
                    }
                    self.wait_for_load_within(id, ACTION_GRACE_MS)?
                } else {
                    json!({ "typed": value.chars().count() })
                };
                if let Some(note) = note {
                    info["note"] = json!(note);
                }
                json_out(self.read_after(id, target.as_ref(), true, args, info)?)
            }
            "select" => {
                let id = self.wake(tab)?;
                let target = target(args)?;
                let option = args["option"].as_str().ok_or("option is required")?;
                let chosen = self.page(id, "select", json!({ "target": target, "option": option }))?;
                // A page may load another on the change, as a language menu does.
                let mut info = self.wait_for_load_within(id, ACTION_GRACE_MS)?;
                info["selected"] = chosen["selected"].clone();
                info["value"] = chosen["value"].clone();
                json_out(self.read_after(id, Some(&target), false, args, info)?)
            }
            "screenshot" => {
                let id = self.wake(tab)?;
                // In CSS pixels, the units clicks take, rather than the
                // display's: a Retina screenshot has four times the bytes
                // to encode, send and read, and the model sees it no better.
                // The clip is in page coordinates, so it starts where the page
                // is scrolled to. A page whose script can't run just now, as
                // with an alert up, is captured at the display's scale.
                let mut params = json!({ "format": "jpeg", "quality": 80 });
                let viewport = self
                    .evaluate(id, "({ x: visualViewport.pageLeft, y: visualViewport.pageTop, w: visualViewport.width, h: visualViewport.height, dpr: devicePixelRatio })")
                    .unwrap_or(Value::Null);
                if let (Some(x), Some(y), Some(w), Some(h), Some(dpr)) = (
                    viewport["x"].as_f64(),
                    viewport["y"].as_f64(),
                    viewport["w"].as_f64(),
                    viewport["h"].as_f64(),
                    viewport["dpr"].as_f64(),
                ) && dpr > 1.0
                    && w > 0.0
                    && h > 0.0
                {
                    params["clip"] = json!({ "x": x, "y": y, "width": w, "height": h, "scale": 1.0 / dpr });
                }
                let mut shot = self.cdp(id, "Page.captureScreenshot", params)?;
                match shot["data"].take() {
                    Value::String(data) if !data.is_empty() => Ok(Output::Image(data)),
                    _ => Err("the screenshot came back empty".into()),
                }
            }
            "eval_js" => {
                let id = self.resolve(tab)?;
                let expression = args["expression"].as_str().ok_or("expression is required")?;
                json_out(self.evaluate(id, expression)?)
            }
            "run_task" => json_out(self.run_task(args)?),
            "list_skills" => json_out(self.request("skills.list", json!({}))?),
            "read_skill" => {
                let name = args["name"].as_str().ok_or("name is required")?;
                json_out(self.request("skills.read", json!({ "name": name }))?)
            }
            "save_skill" => json_out(self.request("skills.save", args.clone())?),
            "list_schedules" | "save_schedule" | "delete_schedule" | "run_schedule" => {
                let method = match name {
                    "list_schedules" => "schedules.list",
                    "save_schedule" => "schedules.save",
                    "delete_schedule" => "schedules.delete",
                    _ => "schedules.run",
                };
                // The app limits what a chat may do with schedules by the
                // chat's own tools, so it is told which chat asks.
                let mut params = if args.is_object() { args.clone() } else { json!({}) };
                if let Ok(chat) = std::env::var("TILLER_CHAT")
                    && !chat.is_empty()
                {
                    params["chat"] = json!(chat);
                }
                json_out(self.request(method, params)?)
            }
            _ => Err(format!("unknown tool: {name}")),
        }
    }

    /// The given tab, or the selected one, loaded. A tab that wasn't loaded,
    /// one restored at launch or unloaded to save memory, loads its page
    /// first. Only this tab: listing every tab doesn't load them.
    fn resolve(&mut self, tab: Option<i64>) -> Result<i64, String> {
        let info = self.request("tabs.resolve", json!({ "tab_id": tab }))?;
        let id = info["id"].as_i64().ok_or("the app did not return a tab id")?;
        if info["started"] == true {
            self.wait_for_load(id)?;
        }
        Ok(id)
    }

    /// Wakes the tab and returns its id. Background tabs are hidden, and
    /// Chromium stalls or drops mouse and key input to hidden pages, so the
    /// app keeps a woken tab drawing behind the selected one for a while.
    pub(crate) fn wake(&mut self, tab: Option<i64>) -> Result<i64, String> {
        let id = self.resolve(tab)?;
        let info = self.request("tabs.wake", json!({ "tab_id": id }))?;
        // Let the page become visible before input arrives. Not
        // Emulation.setFocusEmulationEnabled: it keeps the page visible after
        // the app hides it again.
        if info["woke"] == true {
            thread::sleep(Duration::from_millis(100));
        }
        Ok(id)
    }

    /// Waits until the tab stops loading, then returns its info. The app
    /// answers when the load ends, or once half a second passes with none
    /// starting.
    fn wait_for_load(&mut self, id: i64) -> Result<Value, String> {
        self.wait_for_load_within(id, 500)
    }

    /// Like `wait_for_load`, giving a load `grace` milliseconds to start. A
    /// click or a submitted form may run script before it navigates.
    pub(crate) fn wait_for_load_within(&mut self, id: i64, grace: u64) -> Result<Value, String> {
        self.wait_for_load_up_to(id, grace, LOAD_TIMEOUT)
    }

    pub(crate) fn wait_for_load_up_to(&mut self, id: i64, grace: u64, timeout: Duration) -> Result<Value, String> {
        self.request("tabs.wait_load", json!({ "tab_id": id, "grace_ms": grace, "timeout_ms": timeout.as_millis() as u64 }))
    }

    /// Before reading: waits, for at most READ_LOAD_WAIT, on a load in
    /// progress, since until it commits the old page is still there.
    pub(crate) fn wait_if_loading(&mut self, id: i64) -> Result<(), String> {
        if self.request("tabs.info", json!({ "tab_id": id }))?["loading"] == true {
            self.wait_for_load_up_to(id, 0, READ_LOAD_WAIT)?;
        }
        Ok(())
    }

    pub(crate) fn is_cancelled(&self) -> bool {
        self.cancelled.as_ref().is_some_and(|cancelled| cancelled())
    }

    /// Runs one of page.js's operations, failing with the error it returns.
    pub(crate) fn page(&mut self, id: i64, op: &str, arg: Value) -> Result<Value, String> {
        let value = self.evaluate(id, &format!("({PAGE_JS})({}, {arg})", json!(op)))?;
        match value["error"].as_str() {
            Some(error) => Err(error.to_string()),
            None => Ok(value),
        }
    }

    /// The page's text and elements, for read_page and `read`. Waits a moment
    /// for a load in progress first, and reads again once if a navigation took
    /// the page away mid-read.
    fn read(&mut self, id: i64, args: &Value) -> Result<Value, String> {
        let arg = json!({
            "max": args["max_chars"].as_u64().unwrap_or(20_000),
            "viewport": args["viewport"].as_bool().unwrap_or(false),
        });
        self.wait_if_loading(id)?;
        match self.page(id, "read", arg.clone()) {
            Ok(page) => Ok(page),
            Err(_) => {
                self.wait_for_load_up_to(id, 0, READ_LOAD_WAIT)?;
                self.page(id, "read", arg)
            }
        }
    }

    /// With `read` set, lets the page react to the input and adds the page as
    /// it is now to `info`, saving the agent a read_page.
    fn read_after(&mut self, id: i64, target: Option<&Value>, typed: bool, args: &Value, mut info: Value) -> Result<Value, String> {
        if args["read"].as_bool().unwrap_or(false) {
            // A navigation may have taken the page away: then there is nothing to settle.
            let _ = self.page(id, "settle", json!({ "target": target, "typed": typed }));
            info["page"] = self.read(id, args)?;
        }
        Ok(info)
    }

    /// A left click at the point `locate` returned.
    pub(crate) fn click_at(&mut self, id: i64, point: &Value) -> Result<(), String> {
        let (Some(x), Some(y)) = (point["x"].as_f64(), point["y"].as_f64()) else {
            return Err("the element has no position on the page".into());
        };
        self.mouse(id, "mouseMoved", x, y)?;
        self.mouse(id, "mousePressed", x, y)?;
        self.mouse(id, "mouseReleased", x, y)?;
        Ok(())
    }

    fn mouse(&mut self, id: i64, kind: &str, x: f64, y: f64) -> Result<Value, String> {
        let mut event = json!({ "type": kind, "x": x, "y": y });
        if kind != "mouseMoved" {
            event["button"] = json!("left");
            event["clickCount"] = json!(1);
        }
        self.cdp(id, "Input.dispatchMouseEvent", event)
    }

    /// Runs `expression` in the page and returns its value.
    pub(crate) fn evaluate(&mut self, id: i64, expression: &str) -> Result<Value, String> {
        let reply = self.cdp(id, "Runtime.evaluate", json!({
            "expression": expression,
            "returnByValue": true,
            "awaitPromise": true,
            "userGesture": true,
        }))?;
        if let Some(details) = reply.get("exceptionDetails") {
            let message = details["exception"]["description"].as_str().or(details["text"].as_str()).unwrap_or("script threw");
            return Err(message.to_string());
        }
        Ok(reply["result"].get("value").cloned().unwrap_or(Value::Null))
    }

    pub(crate) fn cdp(&mut self, id: i64, method: &str, params: Value) -> Result<Value, String> {
        self.request("cdp", json!({ "tab_id": id, "method": method, "params": params }))
    }

    /// One request to the app. Retries once on a fresh connection, in case the
    /// app restarted since the last call.
    pub(crate) fn request(&mut self, method: &str, params: Value) -> Result<Value, String> {
        match self.try_request(method, &params) {
            Err(Failure::Connection(_)) => {
                self.conn = None;
                self.try_request(method, &params)
            }
            // The reply may still come, and the next request must not read
            // it as its own: the connection goes, without a retry.
            Err(Failure::Timeout(message)) => {
                self.conn = None;
                Err(Failure::Timeout(message))
            }
            other => other,
        }
        .map_err(|f| match f {
            Failure::Connection(e) => format!("Tiller is not running or its control socket is unavailable ({e})"),
            Failure::App(message) | Failure::Timeout(message) => message,
        })
    }

    fn try_request(&mut self, method: &str, params: &Value) -> Result<Value, Failure> {
        if self.conn.is_none() {
            let path = socket_path(self.profile.as_deref()).map_err(Failure::App)?;
            let stream = UnixStream::connect(path).map_err(|e| Failure::Connection(e.to_string()))?;
            // The app gives up on a request after 60 seconds; this only
            // catches an app that stopped answering altogether.
            let _ = stream.set_read_timeout(Some(Duration::from_secs(90)));
            let reader = BufReader::new(stream.try_clone().map_err(|e| Failure::Connection(e.to_string()))?);
            self.conn = Some((stream, reader));
        }
        let (stream, reader) = self.conn.as_mut().unwrap();
        self.next_id += 1;
        // One write per request. Formatting straight into the socket would
        // make a system call of every token.
        let mut line = json!({ "id": self.next_id, "method": method, "params": params }).to_string();
        line.push('\n');
        stream.write_all(line.as_bytes()).map_err(|e| Failure::Connection(e.to_string()))?;
        loop {
            let mut reply = String::new();
            // A timeout is the app not answering, not a connection to retry
            // on: sending a click or keystroke again could apply it twice.
            let read = reader.read_line(&mut reply).map_err(|e| match e.kind() {
                std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock => {
                    Failure::Timeout("Tiller did not answer within 90 seconds".into())
                }
                _ => Failure::Connection(e.to_string()),
            })?;
            if read == 0 {
                return Err(Failure::Connection("connection closed".into()));
            }
            let mut reply: Value =
                serde_json::from_str(&reply).map_err(|e| Failure::App(format!("bad reply from Tiller: {e}")))?;
            // A reply to an earlier request isn't this one's answer.
            if reply.get("id").and_then(Value::as_u64).is_some_and(|id| id != self.next_id) {
                continue;
            }
            return match reply.get("error") {
                Some(error) => Err(Failure::App(error.as_str().unwrap_or("error").to_string())),
                None => Ok(reply["result"].take()),
            };
        }
    }
}

enum Failure {
    Connection(String),
    App(String),
    /// The app took too long; its reply may still be on its way.
    Timeout(String),
}

/// TILLER_SOCKET, or `control.sock` in the folder of the profile named by
/// `profile` or TILLER_PROFILE (an id or a name), else of the one used last.
/// Profiles are listed in `profiles.json` in the root folder, which is
/// TILLER_DATA_DIR or the app's folder, as in Profile.swift.
fn socket_path(profile: Option<&str>) -> Result<String, String> {
    let var = |name: &str| std::env::var(name).ok().filter(|v| !v.is_empty());
    if let Some(path) = var("TILLER_SOCKET") {
        return Ok(path);
    }
    let root = var("TILLER_DATA_DIR").unwrap_or_else(|| {
        format!("{}/Library/Application Support/Tiller", std::env::var("HOME").unwrap_or_default())
    });
    let wanted = profile.map(str::to_owned).or_else(|| var("TILLER_PROFILE"));
    let list: Value = match std::fs::read(format!("{root}/profiles.json")) {
        Ok(data) => serde_json::from_slice(&data).unwrap_or(Value::Null),
        // A Tiller from before profiles keeps its socket in the root folder.
        Err(_) if wanted.is_none() => return Ok(format!("{root}/control.sock")),
        Err(e) => return Err(format!("can't read the profiles in {root}: {e}")),
    };
    let profiles = list["profiles"].as_array().map(Vec::as_slice).unwrap_or_default();
    let id = match &wanted {
        Some(wanted) => {
            let lower = wanted.to_lowercase();
            let found = profiles.iter().find(|p| p["id"] == wanted.as_str()).or_else(|| {
                profiles.iter().find(|p| p["name"].as_str().is_some_and(|name| name.to_lowercase() == lower))
            });
            match found.and_then(|p| p["id"].as_str()) {
                Some(id) => id,
                None => {
                    let names: Vec<&str> = profiles.iter().filter_map(|p| p["name"].as_str()).collect();
                    return Err(format!("no profile named {wanted:?}. Profiles: {}", names.join(", ")));
                }
            }
        }
        None => list["lastUsed"].as_str().or_else(|| profiles.first().and_then(|p| p["id"].as_str())).unwrap_or("default"),
    };
    Ok(format!("{root}/Profiles/{id}/control.sock"))
}

fn json_out(value: Value) -> Result<Output, String> {
    Ok(Output::Json(value))
}

/// The element a tool's `ref` or `selector` argument names, as page.js takes it.
fn target(args: &Value) -> Result<Value, String> {
    match (&args["ref"], args["selector"].as_str()) {
        (Value::String(r), _) => Ok(json!({ "ref": r.trim().trim_start_matches('[').trim_end_matches(']') })),
        (Value::Number(n), _) => Ok(json!({ "ref": n.to_string() })),
        (_, Some(s)) => Ok(json!({ "selector": s })),
        _ => Err("give either ref or selector".into()),
    }
}
