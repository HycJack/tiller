//! A profile's stores and Tiller's Settings: `history`, `downloads`,
//! `settings`, `sites`, `passwords`, `extensions` and `import`.

use crate::args::{Error, failed, list, parse_number, usage};
use crate::{Context, help, no_command, plain, request, request_and_wait};
use serde_json::{Value, json};

const HISTORY_USAGE: &str = "\
Usage: tiller history [command]

  (nothing)                 The pages visited most recently
  <text>                    Pages whose address or title has the text, best first
  top                       The most visited sites, as the start page shows them
  rm <url>                  Remove a page, and its http/https and www. twins
  clear                     Clear all history and the recently closed tabs

  --limit <n>               How many to list (default 25)
";

pub fn history(cx: &Context) -> Result<(), Error> {
    if cx.wants_help() {
        return help(HISTORY_USAGE);
    }
    let limit = cx.args.number::<u64>("limit")?.unwrap_or(25);
    let words = cx.words();
    let (method, params) = match words {
        [] => ("history.recent", json!({ "limit": limit })),
        [top] if top == "top" => ("history.top", json!({ "limit": limit })),
        [rm, url] if rm == "rm" || rm == "remove" => ("history.remove", json!({ "url": url })),
        [clear] if clear == "clear" => ("history.clear", json!({})),
        query => ("history.search", json!({ "query": query.join(" "), "limit": limit })),
    };
    let mut browser = cx.browser()?;
    let value = request(&mut browser, method, params)?;
    cx.emit(&value, |v| match method {
        "history.remove" => println!("removed {}", plain(&v["removed"])),
        "history.clear" => println!("history cleared"),
        "history.top" => {
            for site in v["sites"].as_array().into_iter().flatten() {
                println!("{}  {}", plain(&site["host"]), plain(&site["url"]));
            }
        }
        _ => {
            for page in v["pages"].as_array().into_iter().flatten() {
                let day = plain(&page["last_visit"]).chars().take(10).collect::<String>();
                println!("{day}  {:>4}×  {}  {}", page["visits"], plain(&page["title"]), plain(&page["url"]));
            }
        }
    });
    Ok(())
}

const DOWNLOADS_USAGE: &str = "\
Usage: tiller downloads [command]

  (nothing)                 This run's downloads, newest first
  cancel <id>               Stop a download
  open <id>                 Open a finished download
  reveal <id>               Show a finished download in the Finder
  clear                     Forget the finished downloads
";

pub fn downloads(cx: &Context) -> Result<(), Error> {
    if cx.wants_help() {
        return help(DOWNLOADS_USAGE);
    }
    let (method, params) = match cx.words() {
        [] => ("downloads.list", json!({})),
        [clear] if clear == "clear" => ("downloads.clear", json!({})),
        [command, id] if ["cancel", "open", "reveal"].contains(&command.as_str()) => {
            (match command.as_str() {
                "cancel" => "downloads.cancel",
                "open" => "downloads.open",
                _ => "downloads.reveal",
            }, json!({ "id": parse_number::<u64>(id, "id")? }))
        }
        _ => return Err(no_command("downloads")),
    };
    let mut browser = cx.browser()?;
    let value = request(&mut browser, method, params)?;
    cx.emit(&value, |v| match method {
        "downloads.list" => {
            for download in v["downloads"].as_array().into_iter().flatten() {
                println!("{}", download_line(download));
            }
        }
        "downloads.clear" => println!("cleared"),
        _ => println!("{}", download_line(v)),
    });
    Ok(())
}

/// `3  report.pdf  done  1.2 MB  ~/Downloads/report.pdf`.
fn download_line(download: &Value) -> String {
    let received = download["received"].as_i64().unwrap_or_default();
    let size = match download["total"].as_i64() {
        Some(total) if download["state"] == "downloading" => format!("{} of {}", bytes(received), bytes(total)),
        _ => bytes(received),
    };
    format!("{}  {}  {}  {size}  {}", download["id"], plain(&download["name"]), plain(&download["state"]), plain(&download["path"]))
}

fn bytes(count: i64) -> String {
    let count = count as f64;
    match count {
        c if c >= 1e9 => format!("{:.1} GB", c / 1e9),
        c if c >= 1e6 => format!("{:.1} MB", c / 1e6),
        c if c >= 1e3 => format!("{:.0} KB", c / 1e3),
        c => format!("{c} bytes"),
    }
}

const SETTINGS_USAGE: &str = "\
Usage: tiller settings [command]

  (nothing)                 Every setting with its value and what it takes
  get <key>                 One setting's value
  set <key> <value>         Change a setting; an empty value goes back to the default
                            where the setting has one

Settings marked (shared) apply to every profile; the others to --profile's.
";

pub fn settings(cx: &Context) -> Result<(), Error> {
    if cx.wants_help() {
        return help(SETTINGS_USAGE);
    }
    let (method, params) = match cx.words() {
        [] => ("settings.get", json!({})),
        [get, key] if get == "get" => ("settings.get", json!({ "key": key })),
        [set, key, value @ ..] if set == "set" => ("settings.set", json!({ "key": key, "value": value.join(" ") })),
        _ => return Err(no_command("settings")),
    };
    let mut browser = cx.browser()?;
    let value = request(&mut browser, method, params)?;
    cx.emit(&value, |v| {
        if let Some(settings) = v["settings"].as_array() {
            for setting in settings {
                let shared = if setting["shared"] == true { " (shared)" } else { "" };
                let values = setting["values"].as_array().map(|values| {
                    format!("  [{}]", values.iter().map(plain).collect::<Vec<_>>().join("|"))
                });
                println!("{} = {}{shared}{}", plain(&setting["key"]), json!(setting_value(&setting["value"])), values.unwrap_or_default());
                println!("    {}", plain(&setting["summary"]));
            }
        } else if method == "settings.get" {
            println!("{}", setting_value(&v["value"]));
        } else {
            println!("{} = {}", plain(&v["key"]), json!(setting_value(&v["value"])));
        }
    });
    Ok(())
}

/// A setting's value as `set` takes it: on or off for a switch.
fn setting_value(value: &Value) -> String {
    match value {
        Value::Bool(on) => if *on { "on" } else { "off" }.into(),
        other => plain(other),
    }
}

const SITES_USAGE: &str = "\
Usage: tiller sites [command]

  (nothing)                 Sites with a saved camera or microphone choice
  set <site> [--camera <choice>] [--microphone <choice>]
                            Save a choice: ask, allow or block
  rm <site>                 Forget a site's choices
";

pub fn sites(cx: &Context) -> Result<(), Error> {
    if cx.wants_help() {
        return help(SITES_USAGE);
    }
    let (method, params) = match cx.words() {
        [] => ("sites.list", json!({})),
        [set, site] if set == "set" => {
            let mut params = json!({ "site": site });
            for device in ["camera", "microphone"] {
                if let Some(choice) = cx.args.value(device) {
                    params[device] = json!(choice);
                }
            }
            ("sites.set", params)
        }
        [rm, site] if rm == "rm" || rm == "remove" => ("sites.remove", json!({ "site": site })),
        _ => return Err(no_command("sites")),
    };
    let mut browser = cx.browser()?;
    let value = request(&mut browser, method, params)?;
    let line = |site: &Value| {
        let choice = |device: &str| site[device].as_str().unwrap_or("ask").to_owned();
        println!("{}  camera {}  microphone {}", plain(&site["site"]), choice("camera"), choice("microphone"));
    };
    cx.emit(&value, |v| match method {
        "sites.list" => v["sites"].as_array().into_iter().flatten().for_each(line),
        "sites.remove" => println!("removed {}", plain(&v["removed"])),
        _ => line(v),
    });
    Ok(())
}

const PASSWORDS_USAGE: &str = "\
Usage: tiller passwords [command]

  (nothing) or list [text]  Saved logins, by site and username, optionally those
                            whose site or username has the text. Passwords are
                            never printed
  fill [--username <name>]  Fill the page's saved login into it (--tab for another tab)
  rm <site> [--username <name>] [--all]
                            Remove a site's login, or with --all every one it has
";

pub fn passwords(cx: &Context) -> Result<(), Error> {
    if cx.wants_help() {
        return help(PASSWORDS_USAGE);
    }
    let username = cx.args.value("username");
    let (method, params) = match cx.words() {
        [] => ("passwords.list", json!({})),
        [list, query @ ..] if list == "list" => ("passwords.list", json!({ "query": query.join(" ") })),
        [fill] if fill == "fill" => {
            let mut params = json!({ "tab_id": cx.args.number::<i64>("tab")? });
            if let Some(username) = username {
                params["username"] = json!(username);
            }
            ("tabs.fill_password", params)
        }
        [rm, site] if rm == "rm" || rm == "remove" => {
            let mut params = json!({ "site": site, "all": cx.args.has("all") });
            if let Some(username) = username {
                params["username"] = json!(username);
            }
            ("passwords.remove", params)
        }
        _ => return Err(no_command("passwords")),
    };
    let mut browser = cx.browser()?;
    let value = request(&mut browser, method, params)?;
    cx.emit(&value, |v| match method {
        "passwords.list" => {
            for login in v["logins"].as_array().into_iter().flatten() {
                println!("{}  {}", plain(&login["site"]), plain(&login["username"]));
            }
        }
        "tabs.fill_password" => println!("filling {}'s login for {}", plain(&v["filling"]), plain(&v["site"])),
        _ => {
            for login in v["removed"].as_array().into_iter().flatten() {
                println!("removed {}  {}", plain(&login["site"]), plain(&login["username"]));
            }
        }
    });
    Ok(())
}

const EXTENSIONS_USAGE: &str = "\
Usage: tiller extensions [command]

  (nothing)                 Every extension with its status
  add <folder or .crx>      Add an unpacked folder or a CRX package
  on <id>, off <id>         Turn an extension on or off
  pin <id>, unpin <id>      Keep its button in the toolbar, or not
  options <id>              Open its options page in a new tab
  rm <id>                   Remove it

<id> is the extension's id or its name. Changes load at Tiller's next launch,
for every profile.
";

pub fn extensions(cx: &Context) -> Result<(), Error> {
    if cx.wants_help() {
        return help(EXTENSIONS_USAGE);
    }
    let (method, params) = match cx.words() {
        [] => ("extensions.list", json!({})),
        [add, path] if add == "add" => {
            let full = std::fs::canonicalize(path).map(|p| p.display().to_string()).unwrap_or_else(|_| path.clone());
            ("extensions.add", json!({ "path": full }))
        }
        [command, id] => match command.as_str() {
            "on" | "off" => ("extensions.enable", json!({ "id": id, "on": command == "on" })),
            "pin" | "unpin" => ("extensions.pin", json!({ "id": id, "on": command == "pin" })),
            "options" => ("extensions.options", json!({ "id": id, "background": cx.args.has("background") })),
            "rm" | "remove" => ("extensions.remove", json!({ "id": id })),
            _ => return Err(no_command("extensions")),
        },
        _ => return Err(no_command("extensions")),
    };
    let mut browser = cx.app_browser()?;
    let value = if method == "extensions.add" || method == "extensions.options" {
        // Options open in a tab of --profile's window.
        let mut browser = if method == "extensions.options" { cx.browser()? } else { browser };
        request_and_wait(cx, &mut browser, method, params, "unpacking")?
    } else {
        request(&mut browser, method, params)?
    };
    let line = |e: &Value| {
        let pinned = if e["pinned"] == true { ", pinned" } else { "" };
        println!("{}  {}  {}  {}{pinned}", plain(&e["name"]), plain(&e["version"]), plain(&e["id"]), plain(&e["status"]));
    };
    cx.emit(&value, |v| match method {
        "extensions.list" => {
            v["extensions"].as_array().into_iter().flatten().for_each(line);
            if v["needs_restart"] == true {
                println!("Changes load the next time Tiller opens.");
            }
        }
        "extensions.add" => println!("added {} ({}). {}", plain(&v["added"]), plain(&v["id"]), plain(&v["note"])),
        "extensions.remove" => println!("removed {}", plain(&v["removed"])),
        "extensions.options" => println!("opened {}", plain(&v["opened"])),
        _ => line(v),
    });
    Ok(())
}

const IMPORT_USAGE: &str = "\
Usage: tiller import <command>

  chrome-profiles           Chrome's profiles
  chrome [--from <profile>] [--only <kinds>]
                            Import from a Chrome profile, the one Chrome used last
                            unless --from names one. --only takes any of cookies,
                            passwords, history, settings and extensions, comma-
                            separated; all of them by default. macOS asks for your
                            login password to read Chrome's cookies and passwords
";

pub fn import(cx: &Context) -> Result<(), Error> {
    if cx.wants_help() {
        return help(IMPORT_USAGE);
    }
    let (method, params) = match cx.words() {
        [what] if what == "chrome-profiles" => ("import.chrome_profiles", json!({})),
        [what] if what == "chrome" => {
            let mut params = json!({});
            if let Some(from) = cx.args.value("from") {
                params["chrome_profile"] = json!(from);
            }
            if let Some(only) = cx.args.value("only") {
                params["kinds"] = json!(list(only));
            }
            ("import.chrome", params)
        }
        [] => return Err(usage("import needs chrome or chrome-profiles")),
        _ => return Err(no_command("import")),
    };
    let mut browser = cx.browser()?;
    let value = request_and_wait(cx, &mut browser, method, params, "importing")?;
    let mut failures = 0;
    cx.emit(&value, |v| {
        for profile in v["profiles"].as_array().into_iter().flatten() {
            let mark = if profile["last_used"] == true { "*" } else { " " };
            println!("{mark} {}  ({})", plain(&profile["name"]), plain(&profile["directory"]));
        }
        if let Some(results) = v["results"].as_array() {
            println!("from Chrome's {}", plain(&v["chrome_profile"]));
            for result in results {
                match result["error"].as_str() {
                    Some(error) => println!("{}: {error}", plain(&result["title"])),
                    None => println!("{}: {}", plain(&result["title"]), plain(&result["detail"])),
                }
            }
        }
    });
    failures += value["results"].as_array().into_iter().flatten().filter(|r| r["error"].is_string()).count();
    if failures > 0 {
        return Err(failed(format!("{failures} part{} of the import failed", if failures == 1 { "" } else { "s" })));
    }
    Ok(())
}
