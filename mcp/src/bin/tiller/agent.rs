//! The agent panel's chats, the skill library and scheduled prompts:
//! `agent`, `skills` and `schedules`.

use crate::args::{Error, failed, list, parse_number, usage};
use crate::{Context, help, no_command, plain, request, request_and_wait};
use serde_json::{Value, json};
use std::{fs, io::Read};

const AGENT_USAGE: &str = "\
Usage: tiller agent <command>

  send <message>            Send a message in a new chat, in the background as a
                            scheduled run is, and print the agent's answer. The
                            agent gets the selected tab's details, as in the panel
    --agent <agent>         qodercli, claude, codex, agy, grok or a provider's
                            id; default as in Settings
    --model <id>, --effort <level>, --context <size>, --fast
                            The chat's model options; default as in Settings
    --tools <list>          Built-in tools: any of read, write and shell
    --chat <id>             Continue that chat instead, with its own agent,
                            model and tools
    --no-wait               Print the chat's id and leave the agent working
  chats [--limit <n>]       Chats, newest first, with their ids (also `agent`)
  show <id>                 A chat's transcript
  status <id>               Whether a chat is working
  stop <id>                 Stop a chat's turn
  rm <id>                   Delete a chat

`tiller show agent --chat <id>` opens a chat in the panel.
";

pub fn agent(cx: &Context) -> Result<(), Error> {
    if cx.wants_help() {
        return help(AGENT_USAGE);
    }
    match cx.words() {
        [] => chats(cx),
        [chats_word] if chats_word == "chats" => chats(cx),
        [command, message @ ..] if command == "send" => {
            let text = if message.is_empty() || message == ["-"] {
                let mut text = String::new();
                std::io::stdin().read_to_string(&mut text).map_err(|e| failed(format!("couldn't read the message: {e}")))?;
                text
            } else {
                message.join(" ")
            };
            if text.trim().is_empty() {
                return Err(usage("send needs a message, as words or on stdin"));
            }
            send(cx, text)
        }
        [command, id] => {
            let method = match command.as_str() {
                "show" => "agent.transcript",
                "status" => "agent.status",
                "stop" => "agent.stop",
                "rm" | "delete" => "agent.delete",
                _ => return Err(no_command("agent")),
            };
            let mut browser = cx.browser()?;
            let value = request(&mut browser, method, json!({ "chat": id }))?;
            cx.emit(&value, |v| match method {
                "agent.transcript" => print_transcript(v),
                "agent.status" => println!("{}", chat_line(v)),
                "agent.stop" => println!("stopping {}", plain(&v["stopping"])),
                _ => println!("deleted {}", plain(&v["deleted"])),
            });
            Ok(())
        }
        _ => Err(no_command("agent")),
    }
}

fn chats(cx: &Context) -> Result<(), Error> {
    let mut browser = cx.browser()?;
    let limit = cx.args.number::<u64>("limit")?.unwrap_or(25);
    let value = request(&mut browser, "agent.chats", json!({ "limit": limit }))?;
    cx.emit(&value, |v| {
        for chat in v["chats"].as_array().into_iter().flatten() {
            println!("{}", chat_line(chat));
        }
    });
    Ok(())
}

/// `<id>  2026-10-20  Claude Code  Title  (working, tab 2)`.
fn chat_line(chat: &Value) -> String {
    let mut notes = Vec::new();
    if chat["busy"] == true {
        notes.push("working".to_string());
    }
    match chat["tab"].as_u64() {
        Some(0) => notes.push("in the background".into()),
        Some(tab) => notes.push(format!("tab {tab}")),
        None => {}
    }
    if chat["scheduled"] == true {
        notes.push("scheduled".into());
    }
    let day: String = plain(&chat["updated"]).chars().take(10).collect();
    let notes = if notes.is_empty() { String::new() } else { format!("  ({})", notes.join(", ")) };
    format!("{}  {day}  {}  {}{notes}", plain(&chat["id"]), plain(&chat["agent_name"]), plain(&chat["title"]))
}

fn send(cx: &Context, text: String) -> Result<(), Error> {
    let args = cx.args;
    let mut params = json!({ "text": text });
    for key in ["agent", "model", "effort", "context", "chat"] {
        if let Some(value) = args.value(key) {
            params[key] = json!(value);
        }
    }
    if args.has("fast") {
        params["fast"] = json!(true);
    } else if args.has("no-fast") {
        params["fast"] = json!(false);
    }
    if let Some(tools) = args.value("tools") {
        params["tools"] = json!(if tools == "none" { vec![] } else { list(tools) });
    }
    let mut browser = cx.browser()?;
    let started = request(&mut browser, "agent.send", params)?;
    let chat = plain(&started["chat"]);
    if args.has("no-wait") {
        cx.emit(&started, |v| println!("{}", plain(&v["chat"])));
        return Ok(());
    }
    if !cx.json() {
        eprintln!("chat {chat}");
    }
    let job = started["job"].as_str().ok_or_else(|| failed("Tiller didn't start the chat"))?.to_owned();
    let value = wait(cx, &mut browser, &job)?;
    cx.emit(&value, |v| {
        let text = plain(&v["text"]);
        if !text.is_empty() {
            println!("{text}");
        }
    });
    match value["status"].as_str() {
        Some("done") => Ok(()),
        Some("failed") => Err(failed(format!("the agent failed: {}", plain(&value["error"])))),
        other => Err(failed(format!("the chat ended {}", other.unwrap_or("unexpectedly")))),
    }
}

/// Waits for a job that is still running, saying so on stderr.
fn wait(cx: &Context, browser: &mut tiller_mcp::browser::Browser, job: &str) -> Result<Value, Error> {
    loop {
        let state = request(browser, "jobs.wait", json!({ "id": job, "timeout_ms": 20_000 }))?;
        match state["status"].as_str() {
            Some("done") => return Ok(state["result"].clone()),
            Some("failed") => return Err(failed(plain(&state["error"]))),
            _ => {
                if !cx.json() {
                    eprintln!("agent working ({}s)", state["seconds"].as_f64().unwrap_or_default().round());
                }
            }
        }
    }
}

/// A chat's messages, its agent's answers, tool calls and notes.
fn print_transcript(chat: &Value) {
    println!("{}  {}", plain(&chat["title"]), plain(&chat["agent_name"]));
    for record in chat["records"].as_array().into_iter().flatten() {
        // Each record is one case of AgentRecord, as {"case": {fields}}.
        let Some((kind, body)) = record.as_object().and_then(|o| o.iter().next()) else { continue };
        match kind.as_str() {
            "user" => println!("\n> {}", plain(&body["text"]).replace('\n', "\n> ")),
            "text" => println!("\n{}", plain(&body["_0"])),
            "tool" => {
                let mark = match &body["isError"] {
                    Value::Bool(true) => "✗",
                    Value::Bool(false) => "✓",
                    _ => "…",
                };
                println!("  {mark} {} {}", plain(&body["name"]), plain(&body["detail"]));
            }
            "reasoning" => {}
            "note" => println!("  [{}]", plain(&body["_0"])),
            "error" => println!("  error: {}", plain(&body["_0"])),
            _ => {}
        }
    }
}

const SKILLS_USAGE: &str = "\
Usage: tiller skills [command]

  (nothing)                 Every skill agents can call: the library's, marked
                            on or off, then the CLIs' own
  show <name>               A skill's SKILL.md and its files
  add <source>              Add skills from a folder, a .zip or .skill archive,
                            or a Git repository (URL, owner/repo, or a GitHub
                            folder link)
  save <name> <file|->      Create or update a library skill from a SKILL.md
  on <name>, off <name>     Turn a library skill on or off
  rm <name>                 Remove a library skill and its folder
";

pub fn skills(cx: &Context) -> Result<(), Error> {
    if cx.wants_help() {
        return help(SKILLS_USAGE);
    }
    let (method, params) = match cx.words() {
        [] => ("skills.list", json!({})),
        [show, name] if show == "show" => ("skills.read", json!({ "name": name })),
        [add, source] if add == "add" => {
            // A local path goes to the app as an absolute one.
            let source = fs::canonicalize(source).map(|p| p.display().to_string()).unwrap_or_else(|_| source.clone());
            ("skills.add", json!({ "source": source }))
        }
        [save, name, file] if save == "save" => {
            let mut content = String::new();
            if file == "-" {
                std::io::stdin().read_to_string(&mut content).map_err(|e| failed(format!("couldn't read SKILL.md: {e}")))?;
            } else {
                content = fs::read_to_string(file).map_err(|e| failed(format!("couldn't read {file}: {e}")))?;
            }
            ("skills.save", json!({ "name": name, "content": content }))
        }
        [command, name] if command == "on" || command == "off" => ("skills.toggle", json!({ "name": name, "on": command == "on" })),
        [rm, name] if rm == "rm" || rm == "remove" => ("skills.remove", json!({ "name": name })),
        _ => return Err(no_command("skills")),
    };
    let mut browser = cx.browser()?;
    let value = request_and_wait(cx, &mut browser, method, params, "adding")?;
    cx.emit(&value, |v| match method {
        "skills.list" => {
            for skill in v["skills"].as_array().into_iter().flatten() {
                let state = match (skill["editable"] == true, skill["enabled"] == true) {
                    (true, true) => "library",
                    (true, false) => "library, off",
                    _ => "CLI",
                };
                println!("{}  ({state})  {}", plain(&skill["name"]), plain(&skill["description"]));
            }
        }
        "skills.read" => {
            println!("{}", plain(&v["path"]));
            println!("{}", plain(&v["content"]));
            let files: Vec<String> = v["files"].as_array().into_iter().flatten().map(plain).filter(|f| f != "SKILL.md").collect();
            if !files.is_empty() {
                println!("files: {}", files.join(", "));
            }
        }
        "skills.add" => {
            let names: Vec<String> = v["added"].as_array().into_iter().flatten().map(plain).collect();
            println!("added {}. {}", names.join(", "), plain(&v["note"]));
        }
        "skills.save" => println!("saved {} at {}. {}", plain(&v["saved"]), plain(&v["path"]), plain(&v["note"])),
        "skills.remove" => println!("removed {}", plain(&v["removed"])),
        _ => println!("{} {}", plain(&v["name"]), if v["enabled"] == true { "on" } else { "off" }),
    });
    Ok(())
}

const SCHEDULES_USAGE: &str = "\
Usage: tiller schedules [command]

  (nothing)                 Every scheduled prompt, with its id and next run
  add <prompt> <when>       Schedule a prompt; <when> is one of
                              --every <minutes, or 30m, 2h>
                              --daily <HH:MM>   --weekdays <HH:MM>
                              --cron <\"min hour day month weekday\">
    --name <name>, --agent <agent>, --model <id>, --effort <level>,
    --context <size>, --fast, --tools <list>, --off
  edit <id> [--prompt <text>] [<when>] [the options of add] [--on|--off]
  on <id>, off <id>         Turn a schedule on or off
  run <id>                  Run it now, without moving its next run
  rm <id>                   Remove it; chats from its runs stay
";

pub fn schedules(cx: &Context) -> Result<(), Error> {
    if cx.wants_help() {
        return help(SCHEDULES_USAGE);
    }
    let args = cx.args;
    let (method, params) = match cx.words() {
        [] => ("schedules.list", json!({})),
        [add, prompt @ ..] if add == "add" && !prompt.is_empty() => {
            let mut params = schedule_options(cx)?;
            if params.get("rule").is_none() {
                return Err(usage("add needs when it runs: --every, --daily, --weekdays or --cron"));
            }
            params["prompt"] = json!(prompt.join(" "));
            if args.has("off") {
                params["enabled"] = json!(false);
            }
            ("schedules.save", params)
        }
        [edit, id] if edit == "edit" => {
            let mut params = schedule_options(cx)?;
            params["id"] = json!(id);
            if let Some(prompt) = args.value("prompt") {
                params["prompt"] = json!(prompt);
            }
            if args.has("on") || args.has("off") {
                params["enabled"] = json!(args.has("on"));
            }
            ("schedules.save", params)
        }
        [command, id] if command == "on" || command == "off" => ("schedules.save", json!({ "id": id, "enabled": command == "on" })),
        [run, id] if run == "run" => ("schedules.run", json!({ "id": id })),
        [rm, id] if rm == "rm" || rm == "remove" || rm == "delete" => ("schedules.delete", json!({ "id": id })),
        _ => return Err(no_command("schedules")),
    };
    let mut browser = cx.browser()?;
    let value = request(&mut browser, method, params)?;
    cx.emit(&value, |v| match method {
        "schedules.list" => {
            for schedule in v["schedules"].as_array().into_iter().flatten() {
                println!("{}", schedule_line(schedule));
            }
        }
        "schedules.delete" => println!("removed {}", plain(&v["deleted"])),
        "schedules.run" => println!("ran {}: {}", plain(&v["ran"]), plain(&v["result"])),
        _ => println!("{}", schedule_line(v)),
    });
    Ok(())
}

/// `<id>  Name  every day at 09:00  claude  next 2026-10-21T09:00  (off)`.
fn schedule_line(schedule: &Value) -> String {
    let mut line = format!(
        "{}  {}  {}  {}",
        plain(&schedule["id"]),
        plain(&schedule["name"]),
        plain(&schedule["rule"]["text"]),
        plain(&schedule["agent"])
    );
    if let Some(next) = schedule["next_run"].as_str() {
        line += &format!("  next {next}");
    }
    if let Some(last) = schedule["last_result"].as_str() {
        line += &format!("  last: {last}");
    }
    if schedule["enabled"] == false {
        line += "  (off)";
    }
    line
}

/// The rule, name, agent, model options and tools that `add` and `edit` take.
fn schedule_options(cx: &Context) -> Result<Value, Error> {
    let args = cx.args;
    let mut params = json!({});
    let rules: Vec<(&str, &str)> =
        ["every", "daily", "weekdays", "cron"].into_iter().filter_map(|key| args.value(key).map(|v| (key, v))).collect();
    match rules.as_slice() {
        [] => {}
        [("every", every)] => params["rule"] = json!({ "every_minutes": minutes(every)? }),
        [(key, value)] => params["rule"] = json!({ *key: value }),
        _ => return Err(usage("give only one of --every, --daily, --weekdays and --cron")),
    }
    for key in ["name", "agent", "model", "effort", "context"] {
        if let Some(value) = args.value(key) {
            params[key] = json!(value);
        }
    }
    if args.has("fast") {
        params["fast"] = json!(true);
    } else if args.has("no-fast") {
        params["fast"] = json!(false);
    }
    if let Some(tools) = args.value("tools") {
        params["tools"] = json!(if tools == "none" { vec![] } else { list(tools) });
    }
    Ok(params)
}

/// `30`, `30m` or `2h` as minutes.
fn minutes(text: &str) -> Result<u64, Error> {
    let text = text.trim();
    if let Some(hours) = text.strip_suffix('h') {
        return Ok(parse_number::<u64>(hours, "--every")? * 60);
    }
    parse_number(text.strip_suffix('m').unwrap_or(text), "--every")
}
