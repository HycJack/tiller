//! The browser tools, one command each, and the tab and page actions of
//! Tiller's menus.

use crate::args::{Error, failed, parse_number, usage};
use crate::{Context, USAGE, help, plain, request};
use serde_json::{Map, Value, json};
use std::{
    env, fs,
    path::PathBuf,
    time::{SystemTime, UNIX_EPOCH},
};
use tiller_mcp::browser::{Browser, Output, ProfileList};

pub fn run(cx: &Context) -> Result<(), Error> {
    if cx.wants_help() {
        return help(USAGE);
    }
    let args = cx.args;
    let command = args.words[0].as_str();
    let positional = args.rest(1);
    let tab = args.number::<i64>("tab")?;

    // Commands that aren't one of tiller_mcp's tools.
    match (command, positional) {
        ("tabs", []) if args.has("all") => return all_tabs(cx),
        ("close", [] | [_]) if args.has("others") || args.has("right") => {
            let tab = match positional {
                [id] => Some(parse_number::<i64>(id, "tab")?),
                _ => tab,
            };
            let mut browser = cx.browser()?;
            let method = if args.has("others") { "tabs.close_others" } else { "tabs.close_right" };
            let value = request(&mut browser, method, json!({ "tab_id": tab }))?;
            cx.emit(&value, |v| {
                let ids: Vec<String> = v["closing"].as_array().into_iter().flatten().map(Value::to_string).collect();
                println!("closing {}", if ids.is_empty() { "nothing".into() } else { ids.join(", ") });
            });
            return Ok(());
        }
        ("close", []) => {
            let mut browser = cx.browser()?;
            let value = request(&mut browser, "tabs.close", json!({ "tab_id": tab }))?;
            cx.emit(&value, |v| println!("closed {}", v["closing"]));
            return Ok(());
        }
        ("stop" | "devtools" | "print" | "source" | "dup" | "reopen", []) => {
            let mut browser = cx.browser()?;
            let method = match command {
                "stop" => "tabs.stop",
                "devtools" => "tabs.devtools",
                "print" => "tabs.print",
                "source" => "tabs.source",
                "dup" => "tabs.duplicate",
                _ => "tabs.reopen",
            };
            let mut params = json!({ "tab_id": tab });
            if matches!(command, "source" | "dup" | "reopen") {
                params["select"] = json!(!args.has("background"));
            }
            let mut value = request(&mut browser, method, params)?;
            // A new tab: print it once its page has loaded.
            if matches!(command, "source" | "dup" | "reopen")
                && let Some(id) = value["id"].as_i64()
            {
                value = browser.wait_for_load(id).map_err(failed)?;
            }
            cx.emit(&value, |v| println!("{}", tab_line(v)));
            return Ok(());
        }
        ("dup", [id]) => {
            let mut browser = cx.browser()?;
            let params = json!({ "tab_id": parse_number::<i64>(id, "tab")?, "select": !args.has("background") });
            let value = request(&mut browser, "tabs.duplicate", params)?;
            let value = match value["id"].as_i64() {
                Some(id) => browser.wait_for_load(id).map_err(failed)?,
                None => value,
            };
            cx.emit(&value, |v| println!("{}", tab_line(v)));
            return Ok(());
        }
        ("move", [id, place]) => {
            let mut browser = cx.browser()?;
            let params = json!({ "tab_id": parse_number::<i64>(id, "tab")?, "index": parse_number::<i64>(place, "place")? });
            let value = request(&mut browser, "tabs.move", params)?;
            cx.emit(&value, print_tabs);
            return Ok(());
        }
        ("closed", []) => {
            let mut browser = cx.browser()?;
            let value = request(&mut browser, "tabs.closed", json!({}))?;
            cx.emit(&value, |v| {
                for tab in v["tabs"].as_array().into_iter().flatten() {
                    println!("{}  {}", plain(&tab["title"]), plain(&tab["url"]));
                }
            });
            return Ok(());
        }
        ("pdf", []) => return pdf(cx, tab),
        _ => {}
    }

    let mut call = Map::new();
    if let Some(tab) = tab {
        call.insert("tab_id".into(), json!(tab));
    }
    let selector = args.value("selector");
    let tool = match (command, positional) {
        ("tabs", []) => "list_tabs",
        ("new", []) => "new_tab",
        ("new", [url]) => {
            call.insert("url".into(), json!(url));
            "new_tab"
        }
        ("select" | "close", [tab]) => {
            call.insert("tab_id".into(), json!(parse_number::<i64>(tab, "tab")?));
            if command == "select" { "select_tab" } else { "close_tab" }
        }
        ("go", [url]) => {
            call.insert("url".into(), json!(url));
            "navigate"
        }
        ("back", []) => "go_back",
        ("forward", []) => "go_forward",
        ("reload", []) => "reload",
        ("read", []) => {
            if let Some(max) = args.number::<u64>("max-chars")? {
                call.insert("max_chars".into(), json!(max));
            }
            "read_page"
        }
        ("click", [reference]) if selector.is_none() => {
            call.insert("ref".into(), json!(reference));
            "click"
        }
        ("click", []) if selector.is_some() => "click",
        ("type", [text]) => {
            call.insert("text".into(), json!(text));
            "type"
        }
        ("type", [reference, text]) if selector.is_none() => {
            call.insert("ref".into(), json!(reference));
            call.insert("text".into(), json!(text));
            "type"
        }
        ("choose", [reference, option]) if selector.is_none() => {
            call.insert("ref".into(), json!(reference));
            call.insert("option".into(), json!(option));
            "select"
        }
        ("choose", [option]) if selector.is_some() => {
            call.insert("option".into(), json!(option));
            "select"
        }
        ("find", [_, ..]) => {
            call.insert("text".into(), json!(positional.join(" ")));
            if let Some(max) = args.number::<u64>("max-matches")? {
                call.insert("max_matches".into(), json!(max));
            }
            "find_text"
        }
        ("zoom", []) => "zoom",
        ("zoom", [level]) => {
            call.insert("level".into(), json!(level));
            "zoom"
        }
        ("run", [_, ..]) => {
            call.insert("goal".into(), json!(positional.join(" ")));
            if let Some(max) = args.number::<u64>("max-steps")? {
                call.insert("max_steps".into(), json!(max));
            }
            "run_task"
        }
        ("screenshot", []) => "screenshot",
        ("eval", [_, ..]) => {
            call.insert("expression".into(), json!(positional.join(" ")));
            "eval_js"
        }
        (
            "tabs" | "new" | "select" | "close" | "go" | "back" | "forward" | "reload" | "read" | "click" | "type" | "choose" | "find"
            | "zoom" | "run" | "screenshot" | "eval" | "stop" | "devtools" | "print" | "source" | "dup" | "move" | "closed" | "reopen"
            | "pdf",
            _,
        ) => {
            return Err(usage(format!("wrong arguments for {command}")));
        }
        _ => return Err(usage(format!("unknown command {command:?}"))),
    };
    if let Some(selector) = selector {
        call.insert("selector".into(), json!(selector));
    }
    for (flag, key) in [("append", "append"), ("submit", "submit"), ("background", "background"), ("viewport", "viewport")] {
        if args.has(flag) {
            call.insert(key.into(), json!(true));
        }
    }
    if args.has("read") {
        call.insert("read".into(), json!(true));
        if let Some(max) = args.number::<u64>("max-chars")? {
            call.insert("max_chars".into(), json!(max));
        }
    }

    let mut browser = cx.browser()?;
    let output = browser.call_tool(tool, &Value::Object(call)).map_err(failed)?;
    let value = match output {
        Output::Json(value) => value,
        Output::Image(data) => {
            let path = save(args.value("output"), "screenshot", "jpg", &data)?;
            json!({ "path": path })
        }
    };

    if cx.json() {
        println!("{}", serde_json::to_string_pretty(&value).unwrap_or_default());
        return Ok(());
    }
    match tool {
        "list_tabs" => print_tabs(&value),
        "close_tab" => println!("closed {}", value["closing"]),
        "read_page" => print_page(&value),
        "type" if value.get("typed").is_some() => {
            println!("typed {} chars", value["typed"]);
            if let Some(note) = value["note"].as_str() {
                println!("note: {note}");
            }
        }
        "screenshot" => println!("{}", value["path"].as_str().unwrap_or_default()),
        "find_text" => {
            println!("{} matches for {}", value["count"], json!(value["query"]));
            for line in value["matches"].as_array().into_iter().flatten() {
                println!("  {}", plain(line));
            }
        }
        "zoom" => println!("{}%  {}", value["zoom"], tab_line(&value)),
        "run_task" => {
            for step in value["steps"].as_array().into_iter().flatten() {
                let changed = if step["page_changed"] == false { "  (page unchanged)" } else { "" };
                println!("{:>6} ms  {}{changed}", step["at_ms"], step["action"].as_str().unwrap_or_default());
            }
            let status = value["status"].as_str().unwrap_or_default();
            println!("{} ({} decisions)", tiller_mcp::jev::summary(&value), value["decisions"]);
            println!("{}  {}", value["title"].as_str().unwrap_or_default(), value["url"].as_str().unwrap_or_default());
            if status != "done" {
                return Err(failed(format!("the task ended {status}")));
            }
        }
        "eval_js" => match &value {
            Value::String(s) => println!("{s}"),
            Value::Null => println!("undefined"),
            other => println!("{}", serde_json::to_string_pretty(other).unwrap_or_default()),
        },
        // new_tab, select_tab, navigate, back, forward, reload, click, and
        // type with --submit return the tab's info.
        _ => {
            println!("{}", tab_line(&value));
            if let Some(selected) = value["selected"].as_str() {
                println!("selected {}", json!(selected));
            }
            if let Some(note) = value["note"].as_str() {
                println!("note: {note}");
            }
        }
    }
    if tool != "read_page" && value["page"].is_object() {
        println!();
        print_page(&value["page"]);
    }
    Ok(())
}

/// `tabs --all`: every open profile's tabs, under its name.
fn all_tabs(cx: &Context) -> Result<(), Error> {
    let Some(list) = ProfileList::read().map_err(failed)? else {
        let mut browser = cx.browser()?;
        let value = request(&mut browser, "tabs.list", json!({}))?;
        cx.emit(&value, print_tabs);
        return Ok(());
    };
    let mut all = Vec::new();
    for profile in list.profiles() {
        let Some(id) = profile["id"].as_str() else { continue };
        if !list.is_open(id) {
            continue;
        }
        let mut browser = Browser::for_user(Some(id.to_owned()));
        let tabs = request(&mut browser, "tabs.list", json!({}))?;
        all.push(json!({ "profile": id, "name": profile["name"], "tabs": tabs["tabs"] }));
    }
    let value = json!({ "profiles": all });
    cx.emit(&value, |v| {
        for (index, profile) in v["profiles"].as_array().into_iter().flatten().enumerate() {
            if index > 0 {
                println!();
            }
            println!("{} ({})", plain(&profile["name"]), plain(&profile["profile"]));
            print_tabs(profile);
        }
    });
    Ok(())
}

/// Saves the page as a PDF, through DevTools' Page.printToPDF.
fn pdf(cx: &Context, tab: Option<i64>) -> Result<(), Error> {
    let mut browser = cx.browser()?;
    let id = browser.resolve(tab).map_err(failed)?;
    let reply = browser
        .cdp(id, "Page.printToPDF", json!({ "printBackground": true, "preferCSSPageSize": true }))
        .map_err(failed)?;
    let data = reply["data"].as_str().filter(|d| !d.is_empty()).ok_or_else(|| failed("the PDF came back empty"))?;
    let path = save(cx.args.value("output"), "page", "pdf", data)?;
    cx.emit(&json!({ "path": path }), |v| println!("{}", plain(&v["path"])));
    Ok(())
}

/// Writes base64 `data` to `output`, or to a temp file named after `stem`,
/// and returns the path.
fn save(output: Option<&str>, stem: &str, extension: &str, data: &str) -> Result<String, Error> {
    let path = output.map(PathBuf::from).unwrap_or_else(|| {
        let millis = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or_default();
        env::temp_dir().join(format!("tiller-{stem}-{millis}.{extension}"))
    });
    let bytes = decode_base64(data).ok_or_else(|| failed(format!("the {stem} was not valid base64")))?;
    fs::write(&path, bytes).map_err(|e| failed(format!("could not write {}: {e}", path.display())))?;
    Ok(path.display().to_string())
}

/// One line per tab, `*` on the selected one.
pub fn print_tabs(value: &Value) {
    for tab in value["tabs"].as_array().into_iter().flatten() {
        println!("{} {}", if tab["selected"] == true { "*" } else { " " }, tab_line(tab));
    }
}

/// `12  Title  https://…`, with `(loading)` while it loads and `(not loaded)`
/// while it waits to load.
pub fn tab_line(tab: &Value) -> String {
    let title = tab["title"].as_str().unwrap_or_default();
    let url = tab["url"].as_str().unwrap_or_default();
    let state = if tab["loaded"] == false {
        "  (not loaded)"
    } else if tab["loading"] == true {
        "  (loading)"
    } else {
        ""
    };
    format!("{}  {title}  {url}{state}", tab["id"])
}

/// Title and URL, the text, then one line per element: `[3] button "Sign in"`.
fn print_page(page: &Value) {
    println!("{}", page["title"].as_str().unwrap_or_default());
    println!("{}", page["url"].as_str().unwrap_or_default());
    let text = page["text"].as_str().unwrap_or_default().trim();
    if !text.is_empty() {
        println!("\n{text}");
    }
    if page["truncated"] == true {
        println!("[text truncated, raise --max-chars to see more]");
    }
    let elements = page["elements"].as_array().map(Vec::as_slice).unwrap_or_default();
    if !elements.is_empty() {
        println!();
    }
    for element in elements {
        let mut line = format!("[{}] {}", element["ref"].as_str().unwrap_or_default(), element["tag"].as_str().unwrap_or_default());
        if let Some(kind) = element["type"].as_str() {
            line += &format!(" type={kind}");
        }
        if let Some(role) = element["role"].as_str() {
            line += &format!(" role={role}");
        }
        line += &format!(" {}", json!(element["text"].as_str().unwrap_or_default()));
        if let Some(href) = element["href"].as_str() {
            line += &format!(" → {href}");
        }
        if let Some(value) = element.get("value") {
            line += &format!(" value={value}");
        }
        if element["filled"] == true {
            line += " (filled)";
        }
        for key in ["checked", "selected", "expanded", "pressed"] {
            match &element[key] {
                Value::Bool(true) => line += &format!(" ({key})"),
                Value::Bool(false) => line += &format!(" (not {key})"),
                Value::String(s) => line += &format!(" ({key}={s})"),
                _ => {}
            }
        }
        if element["offscreen"] == true {
            line += " (offscreen)";
        }
        println!("{line}");
        let options = element["options"].as_array().map(Vec::as_slice).unwrap_or_default();
        if !options.is_empty() {
            let labels: Vec<String> = options
                .iter()
                .filter(|o| o["disabled"] != true)
                .map(|o| format!("{}{}", json!(o["label"].as_str().unwrap_or_default()), if o["selected"] == true { "*" } else { "" }))
                .collect();
            let more = element["more_options"].as_u64().map(|n| format!(" and {n} more")).unwrap_or_default();
            println!("    options: {}{more}", labels.join(", "));
        }
    }
    if let Some(more) = page["more_elements"].as_u64() {
        println!("[{more} more elements not listed]");
    }
    if let Some(scroll) = page["scroll"].as_object() {
        println!("[scrolled to {} of {}, {} tall]", scroll["y"], scroll["height"], scroll["viewport"]);
    }
}

/// Standard base64, as DevTools returns screenshots and PDFs.
fn decode_base64(text: &str) -> Option<Vec<u8>> {
    let mut bytes = Vec::with_capacity(text.len() * 3 / 4);
    let (mut buffer, mut bits) = (0u32, 0);
    for c in text.bytes().filter(|&c| c != b'=' && !c.is_ascii_whitespace()) {
        let value = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        };
        buffer = (buffer << 6) | value as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            bytes.push((buffer >> bits) as u8);
            buffer &= (1 << bits) - 1;
        }
    }
    Some(bytes)
}
