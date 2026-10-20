//! Profiles and Tiller as a whole: `profile`, `profile-tabs`, `status`,
//! `show`, `default-browser`, `update` and `quit`.

use crate::args::{Error, failed, usage};
use crate::{Context, fields, help, no_command, on_off, plain, request, request_and_wait};
use serde_json::{Value, json};
use tiller_mcp::browser::{Browser, ProfileList};

const PROFILE_USAGE: &str = "\
Usage: tiller profile <command>

  list                      Every profile: * marks the one used last, and open
                            ones show their tab count (also `tiller profiles`)
  open <name>               Open a profile, or bring its window forward
  show <name>               The same
  new <name> [--no-open]    Create a profile and open it
  rename <name> <new name>  Rename a profile
  color <name> <color>      red, orange, yellow, green, teal, blue, purple, pink,
                            or auto for one from its place among the profiles
  label <name> [label]      One or two characters, or an emoji, in place of its
                            initials; none brings the initials back
  move <name> <place>       Move an open profile along the rail, from 1
  close <name>              Close a profile's window and tabs
  delete <name>             Move a closed profile's folders to the Trash

Names are profile names, in any case, or ids.
";

pub fn run(cx: &Context) -> Result<(), Error> {
    if cx.wants_help() {
        return help(PROFILE_USAGE);
    }
    let words = cx.words();
    if cx.args.words[0] == "profiles" || words.is_empty() || words == ["list"] {
        return list(cx);
    }
    let (method, params) = match words {
        [open, name] if open == "open" || open == "show" => {
            // Opening one starts Tiller with it when Tiller isn't running.
            if let Some(list) = ProfileList::read().map_err(failed)?
                && !list.profiles().iter().any(|p| list.is_open(p["id"].as_str().unwrap_or_default()))
            {
                let profile = list.resolve(Some(name)).map_err(failed)?;
                let mut browser = Browser::for_user(Some(profile));
                browser.ensure_open().map_err(failed)?;
                let value = request(&mut browser, "app.profile.show", json!({ "profile": name }))?;
                cx.emit(&value, print_profile);
                return Ok(());
            }
            ("app.profile.show", json!({ "profile": name }))
        }
        [new, name] if new == "new" => ("app.profile.new", json!({ "name": name, "open": !cx.args.has("no-open") })),
        [rename, name, new] if rename == "rename" => ("app.profile.rename", json!({ "profile": name, "name": new })),
        [color, name, value] if color == "color" => ("app.profile.color", json!({ "profile": name, "color": value })),
        [label, name] if label == "label" => ("app.profile.label", json!({ "profile": name, "label": "" })),
        [label, name, value] if label == "label" => ("app.profile.label", json!({ "profile": name, "label": value })),
        [command, name, place] if command == "move" => {
            ("app.profile.move", json!({ "profile": name, "index": crate::args::parse_number::<i64>(place, "place")? }))
        }
        [close, name] if close == "close" => ("app.profile.close", json!({ "profile": name })),
        [delete, name] if delete == "delete" || delete == "rm" => ("app.profile.delete", json!({ "profile": name })),
        _ => return Err(no_command("profile")),
    };
    let mut browser = cx.app_browser()?;
    let value = request(&mut browser, method, params)?;
    cx.emit(&value, |v| {
        if let Some(name) = v["deleted"].as_str().and(v["name"].as_str()) {
            println!("moved {name}'s folders to the Trash");
        } else if let Some(name) = v["closing"].as_str().and(v["name"].as_str()) {
            println!("closing {name}");
        } else if v["profiles"].is_array() {
            print_profiles(v);
        } else {
            print_profile(v);
        }
    });
    Ok(())
}

/// The profiles, from Tiller when it runs, else from `profiles.json`.
fn list(cx: &Context) -> Result<(), Error> {
    let running = match ProfileList::read().map_err(failed)? {
        Some(list) => list.profiles().iter().any(|p| list.is_open(p["id"].as_str().unwrap_or_default())),
        None => true,
    };
    let value = if running {
        let mut browser = cx.app_browser()?;
        request(&mut browser, "app.profiles", json!({}))?
    } else {
        let list = ProfileList::read().map_err(failed)?.ok_or_else(|| failed("Tiller has no profiles yet"))?;
        let last = list.last_used().unwrap_or_default().to_owned();
        let profiles: Vec<Value> = list
            .profiles()
            .iter()
            .map(|p| json!({ "id": p["id"], "name": p["name"], "open": false, "last_used": p["id"] == last.as_str(), "label": p["label"], "color": p["color"], "picked_color": p["color"] }))
            .collect();
        json!({ "profiles": profiles, "running": false })
    };
    cx.emit(&value, print_profiles);
    Ok(())
}

fn print_profiles(value: &Value) {
    for profile in value["profiles"].as_array().into_iter().flatten() {
        let mark = if profile["last_used"] == true { "*" } else { " " };
        println!("{mark} {}", profile_line(profile));
    }
}

fn print_profile(value: &Value) {
    println!("{}", profile_line(value));
}

/// `Work  (3f2a9c1e)  blue  open, 4 tabs`.
fn profile_line(profile: &Value) -> String {
    let mut line = format!("{}  ({})", plain(&profile["name"]), plain(&profile["id"]));
    let color = plain(&profile["color"]);
    if !color.is_empty() {
        line += &format!("  {color}");
    }
    if let Some(label) = profile["label"].as_str() {
        line += &format!("  label {label}");
    }
    if profile["open"] == true {
        line += "  open";
        if let Some(place) = profile["position"].as_u64() {
            line += &format!(" #{place}");
        }
        if let Some(tabs) = profile["tabs"].as_u64() {
            line += &format!(", {tabs} tab{}", if tabs == 1 { "" } else { "s" });
        }
        if profile["agent_busy"] == true {
            line += ", agent working";
        }
    }
    line
}

pub fn profile_tabs(cx: &Context) -> Result<(), Error> {
    let params = match cx.words() {
        [] => json!({}),
        [word] => json!({ "on": on_off(word)? }),
        _ => return Err(usage("profile-tabs takes on or off")),
    };
    let mut browser = cx.app_browser()?;
    let value = request(&mut browser, "app.profile_tabs", params)?;
    cx.emit(&value, |v| println!("Profile Tabs {}", if v["profile_tabs"] == true { "on" } else { "off" }));
    Ok(())
}

pub fn status(cx: &Context) -> Result<(), Error> {
    let mut browser = cx.app_browser()?;
    let value = request(&mut browser, "app.status", json!({}))?;
    cx.emit(&value, |v| {
        println!("Tiller {} (build {})", plain(&v["version"]), plain(&v["build"]));
        fields(v, &["app", "data_folder", "profile_tabs", "default_browser", "remote_debugging"]);
        println!();
        print_profiles(v);
    });
    Ok(())
}

const SHOW_USAGE: &str = "\
Usage: tiller show [what]

  (nothing)                 Bring the profile's window forward, with --tab's tab
  agent [--chat <id>]       Show the agent panel, with that chat; --hide hides it
  downloads                 Show the downloads list
  find <text>               Show the find bar searching for the text
  fullscreen                Enter or leave full screen
  settings [pane]           Open Settings, on a pane such as Agent or Profiles
";

pub fn show(cx: &Context) -> Result<(), Error> {
    if cx.wants_help() {
        return help(SHOW_USAGE);
    }
    let tab = cx.args.number::<i64>("tab")?;
    let words = cx.words();
    let (method, params) = match words {
        [] => ("window.show", json!({ "tab_id": tab })),
        [what] if what == "agent" => {
            let mut params = json!({ "show": !cx.args.has("hide") });
            if let Some(chat) = cx.args.value("chat") {
                params["chat"] = json!(chat);
            }
            ("window.agent", params)
        }
        [what] if what == "downloads" => ("window.downloads", json!({})),
        [what] if what == "fullscreen" => ("window.fullscreen", json!({})),
        [what, rest @ ..] if what == "find" && !rest.is_empty() => ("window.find", json!({ "tab_id": tab, "text": rest.join(" ") })),
        [what] if what == "settings" => ("window.settings", json!({})),
        [what, pane] if what == "settings" => ("window.settings", json!({ "pane": pane })),
        _ => return Err(no_command("show")),
    };
    let mut browser = cx.browser()?;
    let value = request(&mut browser, method, params)?;
    cx.emit(&value, |_| {});
    Ok(())
}

pub fn app(cx: &Context, command: &str) -> Result<(), Error> {
    match command {
        "quit" => {
            // Nothing to quit when no profile is open.
            if let Some(list) = ProfileList::read().map_err(failed)?
                && !list.profiles().iter().any(|p| list.is_open(p["id"].as_str().unwrap_or_default()))
            {
                return Err(failed("Tiller isn't running"));
            }
            let mut browser = cx.app_browser()?;
            let value = request(&mut browser, "app.quit", json!({}))?;
            cx.emit(&value, |_| println!("quitting Tiller"));
        }
        "update" => {
            let mut browser = cx.app_browser()?;
            let value = request(&mut browser, "app.update", json!({}))?;
            cx.emit(&value, |_| println!("checking for updates; Tiller shows what it finds"));
        }
        _ => {
            let mut browser = cx.app_browser()?;
            let value = if cx.args.has("make") {
                request_and_wait(cx, &mut browser, "app.default_browser", json!({ "make": true }), "waiting for macOS to confirm")?
            } else {
                request(&mut browser, "app.default_browser", json!({}))?
            };
            cx.emit(&value, |v| {
                println!("{}", if v["default_browser"] == true { "Tiller is the default browser" } else { "Tiller isn't the default browser" })
            });
            if cx.args.has("make") && value["default_browser"] != true {
                return Err(failed("Tiller wasn't made the default browser"));
            }
        }
    }
    Ok(())
}
