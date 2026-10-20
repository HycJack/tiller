//! Command-line arguments: the command's words, and the options anywhere
//! among them, as `tiller --profile work tabs` or `tiller tabs --profile work`.

use std::collections::{HashMap, HashSet};

pub enum Error {
    /// Bad arguments. Exit code 2.
    Usage(String),
    /// The browser or the tool failed. Exit code 1.
    Failed(String),
}

pub fn usage(message: impl Into<String>) -> Error {
    Error::Usage(message.into())
}

pub fn failed(message: impl Into<String>) -> Error {
    Error::Failed(message.into())
}

/// Options that take a value. `-o` is `--output`.
const VALUED: &[&str] = &[
    "profile", "tab", "selector", "max-chars", "max-steps", "output", "limit", "agent", "model", "effort", "context",
    "tools", "chat", "name", "prompt", "every", "daily", "weekdays", "cron", "camera", "microphone", "username", "from",
    "only", "max-matches",
];

/// Options that are on or off.
const SWITCHES: &[&str] = &[
    "append", "submit", "background", "viewport", "read", "json", "all", "others", "right", "fast", "no-fast", "no-wait",
    "show", "hide", "no-open", "on", "off", "make", "help",
];

#[derive(Default)]
pub struct Args {
    pub words: Vec<String>,
    values: HashMap<String, String>,
    switches: HashSet<String>,
}

impl Args {
    pub fn parse(args: impl IntoIterator<Item = String>) -> Result<Args, Error> {
        let mut parsed = Args::default();
        let mut args = args.into_iter();
        while let Some(arg) = args.next() {
            let name = match arg.as_str() {
                // Everything after -- is a word, for text that starts with a dash.
                "--" => {
                    parsed.words.extend(args.by_ref());
                    break;
                }
                "-o" => "output".to_string(),
                "-h" => "help".to_string(),
                flag if flag.starts_with("--") => flag[2..].to_string(),
                _ => {
                    parsed.words.push(arg);
                    continue;
                }
            };
            // --name=value as well as --name value.
            let (name, inline) = match name.split_once('=') {
                Some((name, value)) => (name.to_string(), Some(value.to_string())),
                None => (name, None),
            };
            if VALUED.contains(&name.as_str()) {
                let value = match inline {
                    Some(value) => value,
                    None => args.next().ok_or_else(|| usage(format!("--{name} needs a value")))?,
                };
                parsed.values.insert(name, value);
            } else if SWITCHES.contains(&name.as_str()) && inline.is_none() {
                parsed.switches.insert(name);
            } else {
                return Err(usage(format!("unknown option --{name}")));
            }
        }
        Ok(parsed)
    }

    pub fn value(&self, name: &str) -> Option<&str> {
        self.values.get(name).map(String::as_str)
    }

    pub fn has(&self, name: &str) -> bool {
        self.switches.contains(name)
    }

    pub fn number<T: std::str::FromStr>(&self, name: &str) -> Result<Option<T>, Error> {
        self.value(name).map(|text| parse_number(text, &format!("--{name}"))).transpose()
    }

    /// The command's words after the first `skip`.
    pub fn rest(&self, skip: usize) -> &[String] {
        self.words.get(skip..).unwrap_or_default()
    }
}

pub fn parse_number<T: std::str::FromStr>(text: &str, what: &str) -> Result<T, Error> {
    text.parse().map_err(|_| usage(format!("{what} needs a number, not {text:?}")))
}

/// A comma-separated list, such as `--tools read,shell`.
pub fn list(text: &str) -> Vec<String> {
    text.split(',').map(str::trim).filter(|s| !s.is_empty()).map(str::to_owned).collect()
}
