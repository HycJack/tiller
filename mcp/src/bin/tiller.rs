//! Command-line front end to the running Tiller app: the same browser tools as
//! tiller_mcp, one per command, printed as short text or, with --json, as the
//! raw result.

use tiller_mcp::browser::{Browser, Output};
use serde_json::{Map, Value, json};
use std::{
    env, fs,
    path::PathBuf,
    process::ExitCode,
    time::{SystemTime, UNIX_EPOCH},
};

const USAGE: &str = "\
Usage: tiller <command> [options]

Controls the running Tiller browser.

Commands:
  tabs                      List open tabs. * marks the selected one.
  new [url]                 Open a URL or search in a new tab and wait for it to load
  select <tab>              Bring a tab to the front
  close <tab>               Close a tab
  go <url>                  Load a URL or search and wait for it to load
  read                      Page text and numbered links, buttons and fields
  click <ref>               Click an element from the latest read
  type [ref] <text>         Type into an element, or into whatever has focus
  choose <ref> <option>     Pick an option of a dropdown by its value or label
  run <goal>                Hand a task on the page to Jev and print its steps
  screenshot                Save a JPEG of the visible part of the tab
  eval <expression>         Run JavaScript in the page and print the value

Options:
  --profile <name>          Control this open profile instead of the one used last
  --tab <id>                Act on this tab instead of the selected one
  --background              new: leave the selected tab in front
  --selector <css>          Target an element by CSS selector instead of a ref
  --append                  type: keep the field's current text
  --submit                  type: press Enter afterwards
  --max-chars <n>           read: longest text to return (default 20000)
  --viewport                read: only what is visible without scrolling
  --read                    click, type, choose: print the page afterwards
  --max-steps <n>           run: most actions to take (default 30, at most 60)
  -o, --output <file>       screenshot: where to save (default: a temp file)
  --json                    Print the raw result as JSON
  -h, --help                Show this help
";

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.is_empty() || args.iter().any(|a| a == "-h" || a == "--help") {
        print!("{USAGE}");
        return ExitCode::SUCCESS;
    }
    match run(args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(Error::Usage(message)) => {
            eprintln!("tiller: {message}\nRun `tiller --help` for usage.");
            ExitCode::from(2)
        }
        Err(Error::Failed(message)) => {
            eprintln!("tiller: {message}");
            ExitCode::FAILURE
        }
    }
}

enum Error {
    /// Bad arguments. Exit code 2.
    Usage(String),
    /// The browser or the tool failed. Exit code 1.
    Failed(String),
}

fn usage(message: impl Into<String>) -> Error {
    Error::Usage(message.into())
}

#[derive(Default)]
struct Options {
    positional: Vec<String>,
    profile: Option<String>,
    tab: Option<i64>,
    selector: Option<String>,
    append: bool,
    submit: bool,
    background: bool,
    viewport: bool,
    read: bool,
    max_chars: Option<u64>,
    max_steps: Option<u64>,
    output: Option<PathBuf>,
    json: bool,
}

fn parse(args: impl IntoIterator<Item = String>) -> Result<Options, Error> {
    let mut options = Options::default();
    let mut args = args.into_iter();
    while let Some(arg) = args.next() {
        let mut value = |flag: &str| args.next().ok_or_else(|| usage(format!("{flag} needs a value")));
        match arg.as_str() {
            "--profile" => options.profile = Some(value("--profile")?),
            "--tab" => options.tab = Some(number(&value("--tab")?, "--tab")?),
            "--selector" => options.selector = Some(value("--selector")?),
            "--max-chars" => options.max_chars = Some(number(&value("--max-chars")?, "--max-chars")?),
            "--max-steps" => options.max_steps = Some(number(&value("--max-steps")?, "--max-steps")?),
            "-o" | "--output" => options.output = Some(value("--output")?.into()),
            "--append" => options.append = true,
            "--submit" => options.submit = true,
            "--background" => options.background = true,
            "--viewport" => options.viewport = true,
            "--read" => options.read = true,
            "--json" => options.json = true,
            // Everything after -- is positional, for text that starts with a dash.
            "--" => options.positional.extend(args.by_ref()),
            flag if flag.starts_with("--") => return Err(usage(format!("unknown option {flag}"))),
            _ => options.positional.push(arg),
        }
    }
    Ok(options)
}

fn number<T: std::str::FromStr>(text: &str, flag: &str) -> Result<T, Error> {
    text.parse().map_err(|_| usage(format!("{flag} needs a number, not {text:?}")))
}

fn run(args: Vec<String>) -> Result<(), Error> {
    // Options may come before the command too, as in `tiller --profile work tabs`.
    let mut options = parse(args)?;
    if options.positional.is_empty() {
        return Err(usage("no command given"));
    }
    let command = options.positional.remove(0);
    let positional = options.positional.as_slice();

    let mut call = Map::new();
    if let Some(tab) = options.tab {
        call.insert("tab_id".into(), json!(tab));
    }
    let tool = match (command.as_str(), positional) {
        ("tabs", []) => "list_tabs",
        ("new", []) => "new_tab",
        ("new", [url]) => {
            call.insert("url".into(), json!(url));
            "new_tab"
        }
        ("select" | "close", [tab]) => {
            call.insert("tab_id".into(), json!(number::<i64>(tab, "tab")?));
            if command == "select" { "select_tab" } else { "close_tab" }
        }
        ("go", [url]) => {
            call.insert("url".into(), json!(url));
            "navigate"
        }
        ("read", []) => {
            if let Some(max) = options.max_chars {
                call.insert("max_chars".into(), json!(max));
            }
            "read_page"
        }
        ("click", [reference]) if options.selector.is_none() => {
            call.insert("ref".into(), json!(reference));
            "click"
        }
        ("click", []) if options.selector.is_some() => "click",
        ("type", [text]) => {
            call.insert("text".into(), json!(text));
            "type"
        }
        ("type", [reference, text]) if options.selector.is_none() => {
            call.insert("ref".into(), json!(reference));
            call.insert("text".into(), json!(text));
            "type"
        }
        ("choose", [reference, option]) if options.selector.is_none() => {
            call.insert("ref".into(), json!(reference));
            call.insert("option".into(), json!(option));
            "select"
        }
        ("choose", [option]) if options.selector.is_some() => {
            call.insert("option".into(), json!(option));
            "select"
        }
        ("run", [_, ..]) => {
            call.insert("goal".into(), json!(positional.join(" ")));
            if let Some(max) = options.max_steps {
                call.insert("max_steps".into(), json!(max));
            }
            "run_task"
        }
        ("screenshot", []) => "screenshot",
        ("eval", [_, ..]) => {
            call.insert("expression".into(), json!(positional.join(" ")));
            "eval_js"
        }
        ("tabs" | "new" | "select" | "close" | "go" | "read" | "click" | "type" | "choose" | "run" | "screenshot" | "eval", _) => {
            return Err(usage(format!("wrong arguments for {command}")));
        }
        _ => return Err(usage(format!("unknown command {command:?}"))),
    };
    if let Some(selector) = &options.selector {
        call.insert("selector".into(), json!(selector));
    }
    if options.append {
        call.insert("append".into(), json!(true));
    }
    if options.submit {
        call.insert("submit".into(), json!(true));
    }
    if options.background {
        call.insert("background".into(), json!(true));
    }
    if options.viewport {
        call.insert("viewport".into(), json!(true));
    }
    if options.read {
        call.insert("read".into(), json!(true));
        if let Some(max) = options.max_chars {
            call.insert("max_chars".into(), json!(max));
        }
    }

    let mut browser = Browser::default();
    browser.profile = options.profile.clone();
    let output = browser.call_tool(tool, &Value::Object(call)).map_err(Error::Failed)?;
    let value = match output {
        Output::Json(value) => value,
        Output::Image(data) => {
            let path = options.output.clone().unwrap_or_else(|| {
                let millis = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or_default();
                env::temp_dir().join(format!("tiller-screenshot-{millis}.jpg"))
            });
            let bytes = decode_base64(&data).ok_or_else(|| Error::Failed("the screenshot was not valid base64".into()))?;
            fs::write(&path, bytes).map_err(|e| Error::Failed(format!("could not write {}: {e}", path.display())))?;
            json!({ "path": path.display().to_string() })
        }
    };

    if options.json {
        println!("{}", serde_json::to_string_pretty(&value).unwrap_or_default());
        return Ok(());
    }
    match tool {
        "list_tabs" => {
            for tab in value["tabs"].as_array().into_iter().flatten() {
                println!("{} {}", if tab["selected"] == true { "*" } else { " " }, tab_line(tab));
            }
        }
        "close_tab" => println!("closed {}", value["closing"]),
        "read_page" => print_page(&value),
        "type" if value.get("typed").is_some() => {
            println!("typed {} chars", value["typed"]);
            if let Some(note) = value["note"].as_str() {
                println!("note: {note}");
            }
        }
        "screenshot" => println!("{}", value["path"].as_str().unwrap_or_default()),
        "run_task" => {
            for step in value["steps"].as_array().into_iter().flatten() {
                let changed = if step["page_changed"] == false { "  (page unchanged)" } else { "" };
                println!("{:>6} ms  {}{changed}", step["at_ms"], step["action"].as_str().unwrap_or_default());
            }
            let status = value["status"].as_str().unwrap_or_default();
            println!("{} ({} decisions)", tiller_mcp::jev::summary(&value), value["decisions"]);
            println!("{}  {}", value["title"].as_str().unwrap_or_default(), value["url"].as_str().unwrap_or_default());
            if status != "done" {
                return Err(Error::Failed(format!("the task ended {status}")));
            }
        }
        "eval_js" => match &value {
            Value::String(s) => println!("{s}"),
            Value::Null => println!("undefined"),
            other => println!("{}", serde_json::to_string_pretty(other).unwrap_or_default()),
        },
        // new_tab, select_tab, navigate, click, and type with --submit return
        // the tab's info.
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

/// `12  Title  https://…`, with `(loading)` while it loads and `(not loaded)`
/// while it waits to load.
fn tab_line(tab: &Value) -> String {
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

/// Standard base64, as DevTools returns screenshots.
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
