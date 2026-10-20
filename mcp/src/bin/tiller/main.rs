//! Command-line front end to the running Tiller app: the browser tools of
//! tiller_mcp, one per command, and what Tiller's menus and Settings do, by
//! area: profiles, history, downloads, the agent, skills, schedules,
//! settings, sites, saved logins, extensions and the Chrome import. Results
//! print as short text or, with --json, as the raw result.

mod agent;
mod args;
mod manage;
mod page;
mod profile;

use args::{Args, Error, failed, usage};
use serde_json::{Value, json};
use std::{env, process::ExitCode};
use tiller_mcp::browser::{Browser, ProfileList};

const USAGE: &str = "\
Usage: tiller <command> [options]

Controls the running Tiller browser. Starts Tiller, or opens the profile,
when it isn't running or open. Run `tiller <area> --help` for an area's
commands, such as `tiller agent --help`.

Pages and tabs:
  tabs [--all]              List open tabs. * marks the selected one
  new [url]                 Open a URL or search in a new tab and wait for it to load
  select <tab>              Bring a tab to the front
  close [tab]               Close a tab; --others or --right closes those instead
  go <url>                  Load a URL or search and wait for it to load
  back, forward             Go back or forward in the tab's history
  reload, stop              Reload the page, or stop loading it
  read                      Page text and numbered links, buttons and fields
  click <ref>               Click an element from the latest read
  type [ref] <text>         Type into an element, or into whatever has focus
  choose <ref> <option>     Pick an option of a dropdown by its value or label
  find <text>               Count where the text appears in the page
  run <goal>                Hand a task on the page to Jev and print its steps
  screenshot                Save a JPEG of the visible part of the tab
  pdf                       Save the page as a PDF
  eval <expression>         Run JavaScript in the page and print the value
  zoom [in|out|reset]       Zoom the page, or print its zoom
  dup [tab]                 Duplicate a tab
  move <tab> <place>        Move a tab to a place in the tab row, from 1
  closed                    List recently closed tabs
  reopen                    Reopen the last closed tab
  source, devtools, print   View the page's source, open Developer Tools, print

Tiller:
  status                    Version, profiles and app-wide state
  profile ...               List, open, show, create, rename, color, label,
                            move, close and delete profiles
  profile-tabs [on|off]     Every open profile in one window, with a rail
  show [what]               Bring the window forward, or show the agent panel,
                            downloads, find bar, full screen or a Settings pane
  history ...               Search, list, remove and clear history
  downloads ...             List, cancel, open, reveal and clear downloads
  agent ...                 Send a message to an agent, list and read chats
  skills ...                The skill library
  schedules ...             Scheduled prompts
  settings ...              Read and change settings
  sites ...                 Camera and microphone choices per site
  passwords ...             Saved logins: list, fill into the page, remove
  extensions ...            Add, remove, turn on or off and pin extensions
  import ...                Import from Chrome
  default-browser [--make]  Whether Tiller is the default browser, or make it so
  update                    Check for updates
  quit                      Quit Tiller

Options:
  --profile <name>          Use this profile instead of the one used last; it
                            opens if it isn't open
  --tab <id>                Act on this tab instead of the selected one
  --background              new, dup, reopen, source: leave the selected tab in front
  --selector <css>          Target an element by CSS selector instead of a ref
  --append                  type: keep the field's current text
  --submit                  type: press Enter afterwards
  --max-chars <n>           read: longest text to return (default 20000)
  --viewport                read: only what is visible without scrolling
  --read                    click, type, choose: print the page afterwards
  --max-steps <n>           run: most actions to take (default 30, at most 60)
  -o, --output <file>       screenshot, pdf: where to save (default: a temp file)
  --json                    Print the raw result as JSON
  -h, --help                Show this help
";

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    let args = match Args::parse(args) {
        Ok(args) => args,
        Err(error) => return report(error),
    };
    if args.words.is_empty() {
        print!("{USAGE}");
        return ExitCode::SUCCESS;
    }
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => report(error),
    }
}

fn report(error: Error) -> ExitCode {
    match error {
        Error::Usage(message) => {
            eprintln!("tiller: {message}\nRun `tiller --help` for usage.");
            ExitCode::from(2)
        }
        Error::Failed(message) => {
            eprintln!("tiller: {message}");
            ExitCode::FAILURE
        }
    }
}

fn run(args: &Args) -> Result<(), Error> {
    let command = args.words[0].as_str();
    let cx = Context { args };
    match command {
        "profile" | "profiles" => profile::run(&cx),
        "profile-tabs" => profile::profile_tabs(&cx),
        "status" => profile::status(&cx),
        "show" => profile::show(&cx),
        "default-browser" | "update" | "quit" => profile::app(&cx, command),
        "history" => manage::history(&cx),
        "downloads" => manage::downloads(&cx),
        "settings" => manage::settings(&cx),
        "sites" => manage::sites(&cx),
        "passwords" | "password" => manage::passwords(&cx),
        "extensions" | "extension" => manage::extensions(&cx),
        "import" => manage::import(&cx),
        "agent" => agent::agent(&cx),
        "skills" | "skill" => agent::skills(&cx),
        "schedules" | "schedule" => agent::schedules(&cx),
        _ => page::run(&cx),
    }
}

pub struct Context<'a> {
    pub args: &'a Args,
}

impl Context<'_> {
    pub fn json(&self) -> bool {
        self.args.has("json")
    }

    /// Whether to print an area's usage instead of running the command.
    pub fn wants_help(&self) -> bool {
        self.args.has("help")
    }

    /// The command's words after the area's name.
    pub fn words(&self) -> &[String] {
        self.args.rest(1)
    }

    /// The browser of the profile --profile names, or the one used last,
    /// opened if need be.
    pub fn browser(&self) -> Result<Browser, Error> {
        let mut browser = Browser::for_user(self.args.value("profile").map(str::to_owned));
        browser.ensure_open().map_err(failed)?;
        Ok(browser)
    }

    /// A browser for requests about Tiller as a whole, which any open
    /// profile answers: the one --profile names or the one used last when
    /// open, else any open one, else Tiller is started.
    pub fn app_browser(&self) -> Result<Browser, Error> {
        let wanted = self.args.value("profile").map(str::to_owned);
        if env::var("TILLER_SOCKET").is_ok_and(|s| !s.is_empty()) {
            return Ok(Browser::for_user(wanted));
        }
        if let Some(list) = ProfileList::read().map_err(failed)? {
            let first = list.resolve(wanted.as_deref()).map_err(failed)?;
            let ids: Vec<String> = list.profiles().iter().filter_map(|p| p["id"].as_str().map(str::to_owned)).collect();
            if let Some(open) = std::iter::once(first.clone()).chain(ids).find(|id| list.is_open(id)) {
                return Ok(Browser::for_user(Some(open)));
            }
        }
        self.browser()
    }

    /// Prints `value` as JSON with --json, else as `text` prints it.
    pub fn emit(&self, value: &Value, text: impl FnOnce(&Value)) {
        if self.json() {
            println!("{}", serde_json::to_string_pretty(value).unwrap_or_default());
        } else {
            text(value);
        }
    }
}

/// One request, its error made the CLI's.
pub fn request(browser: &mut Browser, method: &str, params: Value) -> Result<Value, Error> {
    browser.request(method, params).map_err(failed)
}

/// One request whose answer may be a job, waited on, saying on stderr how
/// long it has taken while it runs, unless with --json.
pub fn request_and_wait(cx: &Context, browser: &mut Browser, method: &str, params: Value, waiting: &str) -> Result<Value, Error> {
    let quiet = cx.json();
    browser
        .request_and_wait(method, params, |seconds| {
            if !quiet {
                eprintln!("{waiting} ({}s)", seconds.round());
            }
        })
        .map_err(failed)
}

/// `name: value` lines for an object's fields, in a fixed order, skipping
/// missing ones.
pub fn fields(value: &Value, keys: &[&str]) {
    for key in keys {
        match &value[*key] {
            Value::Null => {}
            Value::String(s) => println!("{key}: {s}"),
            other => println!("{key}: {other}"),
        }
    }
}

/// Text for a JSON value in a line: strings bare, the rest as JSON.
pub fn plain(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

/// `on` or `off` as a bool, for commands like `profile-tabs on`.
pub fn on_off(word: &str) -> Result<bool, Error> {
    match word {
        "on" => Ok(true),
        "off" => Ok(false),
        other => Err(usage(format!("expected on or off, not {other:?}"))),
    }
}

/// Prints an area's usage and succeeds.
pub fn help(text: &str) -> Result<(), Error> {
    print!("{text}");
    Ok(())
}

pub fn no_command(area: &str) -> Error {
    usage(format!("unknown {area} command. Run `tiller {area} --help` for its commands."))
}

pub fn json_object(pairs: &[(&str, Option<Value>)]) -> Value {
    let mut object = json!({});
    for (key, value) in pairs {
        if let Some(value) = value {
            object[*key] = value.clone();
        }
    }
    object
}
