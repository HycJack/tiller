# Browser tools

Tiller exposes one set of browser tools two ways: as an MCP server for agents and as the `tiller` command-line tool for shells and scripts. The MCP server also has three tools for the [skill library](agent.md#tillers-skill-library) and four for [scheduled prompts](agent.md#scheduling-from-a-chat).

## MCP server

`build/Tiller.app/Contents/MacOS/tiller_mcp` is a stdio MCP server. It talks to the running app over a Unix socket at `control.sock` in the profile's folder (only your user can open it). Tiller gives its agents that path in `TILLER_SOCKET`. Started any other way, it picks the profile named by `TILLER_PROFILE` (an id or a name), or else the one used last. `TILLER_SOCKET` overrides both.

| Tool | What it does |
|---|---|
| `list_tabs` | Id, URL, title, loading state, whether the page is loaded, and selection of every tab |
| `new_tab` | Opens a URL or search in a new tab and waits for it to load. `background` leaves the selected tab in front |
| `select_tab` | Brings a tab to the front |
| `close_tab` | Closes a tab (the page may still ask to confirm) |
| `navigate` | Loads a URL or search and waits for the load |
| `read_page` | Page text plus numbered links, buttons and fields, with their labels, values, checked, selected or expanded state and a dropdown's options. `viewport` keeps to what is visible without scrolling |
| `click` | Real mouse click on an element's center by `ref` or CSS `selector` |
| `type` | Clicks a field and types into it, replacing its text unless `append` is set, optionally presses Enter |
| `select` | Picks a dropdown (`<select>`) option by its value or label |
| `go_back`, `go_forward` | Goes back or forward in the tab's history and waits for the load |
| `reload` | Reloads the tab and waits for the load |
| `find_text` | Counts where a text appears in the page's text, ignoring case, with the first `max_matches` (10) and the text around them |
| `zoom` | Zooms the page `in`, `out` or `reset`, kept per site as Cmd+= does, and returns the zoom in percent |
| `search_history` | Searches history by URL and title, best first, or lists the pages visited last without `query` |
| `run_task` | Hands a short task on the page, such as filling a search form, to TypeSafe's Jev (see [run_task](#run_task)) |
| `screenshot` | JPEG of the visible part of the tab, in CSS pixels, the units `click` uses |
| `eval_js` | Runs an expression in the page and returns the value as JSON |
| `list_skills` | Every skill agents can call: the library's, marked editable and on or off, then the CLIs' own |
| `read_skill` | A skill's `SKILL.md` and the other files in its folder |
| `save_skill` | Creates or updates a library skill from the whole `SKILL.md`, or its body plus a `description`, with optional `files` to write and `delete_files` to remove |
| `list_schedules` | Every scheduled prompt: id, name, prompt, agent, tools, rule, on or off, next run and last result |
| `save_schedule` | Creates a scheduled prompt, or changes the one with `id`, keeping fields not given. `rule` is one of `{"every_minutes": 30}`, `{"daily": "09:00"}`, `{"weekdays": "09:00"}` or `{"cron": "0 9 * * 1-5"}` |
| `delete_schedule` | Removes a scheduled prompt by `id` |
| `run_schedule` | Runs a scheduled prompt now, without moving its next run |

Tools act on the selected tab unless given `tab_id`, and work in background tabs without bringing them to the front, so agents can each work in a tab of their own while you use another. Only `select_tab` and `new_tab` without `background` change the selected tab.

The MCP server has only tools that read or drive pages, history search among them. Managing Tiller itself, its profiles, settings, extensions and the rest, is left to the [command-line tool](#command-line-tool).

Background tabs are hidden, and Chromium stops drawing hidden pages and stalls or drops their input. So `click`, `type`, `select`, `run_task` and `screenshot` wake their tab first: Tiller unhides it behind the selected tab, where it draws and takes input, and hides it again 30 seconds after the last of these calls. While awake, the page counts as visible, so its animations and videos run as in a front tab. `read_page` and `eval_js` don't need to wake a tab.

A tab's id stays the same for as long as the tab is open. Listing tabs doesn't load them: a tab restored at launch and not yet selected, or one [unloaded to save memory](browser.md#unloading-inactive-tabs), is listed with `loaded` false, and loads its page when a tool acts on it, which then waits for the load. Tabs an agent has used in the last few minutes count as in use, so they don't unload under it.

`read_page` numbers each element it lists with a ref, kept in the page against the element itself rather than written into it. An element keeps its ref while it stays on the page, so a later read gives it the same number, and a new element gets a new one; a new page starts again from 1. Acting on a ref whose element has gone, or has turned into something else (another role or label, as a button re-rendered with other text), fails with an error asking for a new read instead of acting on the wrong thing. Elements that are hidden, transparent, `inert`, under `aria-hidden` or disabled aren't listed, and a password field shows only whether it is `filled`.

`click`, `type` and `select` take `read: true` to return the page as `read_page` would, under `page`, once it has reacted: two frames, at most 50 ms, or after typing into a combobox, until its suggestions show, at most 200 ms. That saves the agent a call. After a click, a submit or a select, the tool gives a load 250 ms to start and waits for it if one does. Before reading, a tool waits up to 3 seconds for a load in progress, so it doesn't read the page being left.

`type` with a ref or selector clicks the field first, since some fields open their suggestions, or a field of their own, only when clicked. If the click puts the focus in another field, as a search box that opens a dialog with its own input, that field gets the text and the result says so.

How it's wired: tab operations (`tabs.*`, including `tabs.info`, `tabs.resolve`, which loads the tab a tool is about to act on if it isn't, `tabs.wake` and `tabs.wait_load`, which answers once a tab's load ends or a moment passes with none starting) skill operations (`skills.*`, in `AgentSkills.swift`) schedule operations (`schedules.*`, in `AgentSchedules.swift`) and run_task's model requests (`jev.*`, in `JevControl.swift`) are answered by the Swift app (`ControlServer.swift`). Everything that touches page content is a DevTools protocol command (`Runtime.evaluate`, `Input.dispatchMouseEvent`, `Input.insertText`, `Page.captureScreenshot`) that the Rust core sends straight to the tab (`core/src/ipc.rs`, `core/src/browser.rs`), found by its tab id; a tab that isn't loaded has no DevTools agent to send to. What runs in the page, reading it and finding, focusing and choosing elements, is one script, `mcp/src/page.js`.

To try it without an agent:

```sh
open build/Tiller.app
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_page","arguments":{}}}' \
  | build/Tiller.app/Contents/MacOS/tiller_mcp
```

## Command-line tool

`tiller` runs the same browser tools from a shell, so scripts and agents outside Tiller, such as Claude Code with its Bash tool, can drive the browser, and does what Tiller's menus and Settings do: profiles, history, downloads, the agent panel, skills, scheduled prompts, settings, site permissions, saved logins, extensions and the Chrome import. It ships at `build/Tiller.app/Contents/Helpers/tiller`, not next to `Tiller` in `Contents/MacOS`, where the two names would be one file on a case-insensitive disk. Tiller > Install Command Line Tool… links it as `~/.local/bin/tiller` and says if that folder isn't on your PATH. Install again after moving the app.

`tiller --help` lists the commands, and `tiller <area> --help` an area's, as `tiller agent --help`. Options can come before or after the command, and `--json` prints the raw result instead of text. Errors go to stderr with exit code 1, or 2 for bad arguments.

### Profiles and Tiller

A command acts on the profile `--profile` names, by name in any case or by id, or else on `TILLER_PROFILE`'s, or the one used last. When that profile isn't open, `tiller` opens it, in the background, and when Tiller isn't running it starts Tiller with it, then waits for the profile, up to 40 seconds. `TILLER_SOCKET` names a socket to use instead and turns this off.

```sh
tiller profiles                    # * marks the one used last; open ones show their tabs
tiller profile new Work            # creates it and opens it; --no-open only creates it
tiller profile open Work           # opens it, or brings its window forward
tiller profile rename Work Office
tiller profile color Office teal   # or auto for one from its place
tiller profile label Office 🚀     # no label brings the initials back
tiller profile move Office 1       # its place along the rail
tiller profile close Office
tiller profile delete Office       # moves its folders to the Trash; it has to be closed
tiller profile-tabs on             # every open profile in one window, with a rail
tiller tabs --all                  # every open profile's tabs
tiller --profile work read         # any command, on that profile
tiller status                      # version, data folder, profiles, app-wide settings
tiller show                        # brings the window forward
tiller show agent --chat <id>      # the agent panel, with that chat; --hide hides it
tiller show downloads              # also: show find <text>, show fullscreen, show settings Agent
tiller default-browser [--make]    # macOS asks to confirm
tiller update                      # in released builds
tiller quit
```

Profile requests go to any open profile's control socket, which answers for Tiller as a whole (`app.*`). `tiller profiles` reads `profiles.json` when Tiller isn't running.

### Pages and tabs

```sh
tiller tabs                        # * marks the selected tab
tiller new example.com             # opens a tab and waits for the load
tiller new --background example.com  # leaves the selected tab in front
tiller read                        # text, then [ref] lines for links, buttons and fields
tiller click 3
tiller type 5 "hello" --submit
tiller type --selector '#q' hi     # CSS selector instead of a ref
tiller choose 7 "Business"         # a dropdown's option, by label or value
tiller click 4 --read              # and print the page afterwards
tiller read --viewport             # only what is on screen
tiller find "free shipping"        # how often the text appears, with context
tiller run "Search flights from Zurich to London on 20 September"
tiller screenshot -o page.jpg      # prints the path; a temp file without -o
tiller pdf -o page.pdf             # the page as a PDF
tiller eval 'document.title'
tiller back                        # also forward, reload and stop
tiller zoom in                     # in, out or reset; without one, prints the zoom
tiller dup                         # duplicates the tab, after it
tiller move 4 1                    # tab 4 to the first place
tiller close 2                     # --others or --right closes those instead
tiller closed                      # the recently closed tabs
tiller reopen                      # the last one, where it was
tiller source                      # also devtools and print
```

| Command | Tool or request |
|---|---|
| `tabs` | `list_tabs` |
| `new [url] [--background]` | `new_tab` |
| `select <tab>` | `select_tab` |
| `close [tab] [--others \| --right]` | `close_tab`, or `tabs.close_others` and `tabs.close_right` |
| `go <url>` | `navigate` |
| `back`, `forward`, `reload` | `go_back`, `go_forward`, `reload` |
| `stop` | `tabs.stop` |
| `read [--max-chars N] [--viewport]` | `read_page` |
| `click <ref>` | `click` |
| `type [ref] <text> [--append] [--submit]` | `type`, into the focused element when no ref or selector is given |
| `choose <ref> <option>` | `select` |
| `find <text> [--max-matches N]` | `find_text` |
| `run <goal> [--max-steps N]` | `run_task`; prints each step, and exits 1 unless the task ends done |
| `screenshot [-o file]` | `screenshot` |
| `pdf [-o file]` | DevTools' `Page.printToPDF` |
| `eval <expression>` | `eval_js` |
| `zoom [in \| out \| reset]` | `zoom` |
| `dup [tab] [--background]` | `tabs.duplicate` |
| `move <tab> <place>` | `tabs.move` |
| `closed`, `reopen [--background]` | `tabs.closed`, `tabs.reopen` |
| `source [--background]`, `devtools`, `print` | `tabs.source`, `tabs.devtools`, `tabs.print` |

`--tab <id>` acts on another tab than the selected one. `--read` after `click`, `type` or `choose` prints the page afterwards. Refs are stored in the page, so a `read` in one call and a `click` in the next agree.

### History, downloads and settings

```sh
tiller history                     # the pages visited last; --limit N
tiller history github              # pages whose address or title has the text
tiller history top                 # the most visited sites
tiller history rm https://example.com/
tiller history clear               # also the recently closed tabs
tiller downloads                   # this run's, with ids
tiller downloads cancel 3          # also open, reveal (in the Finder) and clear
tiller settings                    # every setting, its value and what it takes
tiller settings get search_engine
tiller settings set tab_layout vertical
tiller settings set agent_model.claude opus
tiller sites                       # camera and microphone choices
tiller sites set meet.google.com --camera allow --microphone block
tiller sites rm meet.google.com
tiller passwords [list github]     # sites and usernames; passwords are never printed
tiller passwords fill              # fills the page's saved login; --username picks one
tiller passwords rm github.com --username me
tiller extensions                  # with their status
tiller extensions add ~/ext        # a folder or a .crx file
tiller extensions off "Dark Reader"  # also on, pin, unpin, options and rm, by name or id
tiller import chrome-profiles
tiller import chrome --from Work --only history,settings
```

`settings` covers the General, Agent and Jev panes and the settings every profile shares, which it marks: the homepage, launch and new-tab pages, tab layout and sidebar, tab unloading, search engine and suggestions, full URLs, the agent for new chats and its chat tabs, built-in tools, extra instructions, folder, each CLI's command and each agent's model, effort, context and fast mode, run_task's models, and the theme, appearance, accent, Profile Tabs, remote debugging and, in released builds, updates. Keys, such as providers' and run_task's, stay in Settings, as do custom providers and the agent's shortcut. Switches take `on` or `off`. A Settings window already open may show the old value until its pane is shown again.

The Chrome import asks macOS for your login password to read Chrome's cookies and passwords, and needs Full Disk Access to read Chrome's folder at all; without it, the command says so.

### The agent, skills and scheduled prompts

```sh
tiller agent send "Summarize this page"   # prints the answer once the turn ends
tiller agent send --agent codex --effort high "…"
echo "…" | tiller agent send       # the message from stdin
tiller agent send --chat <id> "And the next one?"
tiller agent send --no-wait "…"    # prints the chat's id and leaves it working
tiller agent chats                 # newest first, with ids; also `tiller agent`
tiller agent show <id>             # the transcript
tiller agent status <id>           # also stop and rm
tiller skills                      # the library's, on or off, then the CLIs' own
tiller skills add owner/repo       # a folder, a .zip or .skill file, or a Git repository
tiller skills save my-skill SKILL.md
tiller skills off my-skill         # also on, show and rm
tiller schedules
tiller schedules add "Check my inbox" --weekdays 09:00 --name Inbox --agent claude --tools read
tiller schedules edit <id> --every 2h
tiller schedules off <id>          # also on, run and rm
```

`agent send` sends the message in a new chat that runs in the background, taking no tab, as a scheduled run does, with the agent, model and tools of Settings unless `--agent`, `--model`, `--effort`, `--context`, `--fast` and `--tools` say otherwise. The agent gets the selected tab's details, as a message typed in the panel does. The chat stays in history, so `tiller show agent --chat <id>` opens it in the panel. `--chat` continues a chat with its own agent, model and tools, in its tab if one shows it. While the turn runs, `tiller` says how long it has taken on stderr; once it ends, it prints the agent's last text, and exits 1 unless the turn finished. Leaving `tiller` with Ctrl+C leaves the chat working.

`schedules add` takes the prompt and one of `--every` (minutes, or `30m`, `2h`), `--daily HH:MM`, `--weekdays HH:MM` or `--cron "<expr>"`, with `--off` to save it turned off. From a terminal, a schedule can have any built-in tools; from an agent's chat, the [chat's limits](agent.md#scheduling-from-a-chat) apply.

### From an agent's chat

Agents in the panel can run `tiller` with their shell tool, and get `TILLER_CHAT`, which `tiller` sends with each request. Tiller then answers the browser tools, history search, skills and schedules, with the per-chat limits on schedules, and refuses requests that manage Tiller: profiles, settings, sites, saved logins, extensions, the import, changing history or downloads, adding, turning off or removing skills, the window's panels, and starting or stopping agents. This keeps a page that steers an agent from changing Tiller through it; an agent that can run commands can still do anything you can in a shell.

### How it's wired

`tiller` talks to the profile's control socket like `tiller_mcp`. Requests that outlast the 60 seconds a reply may take, `agent.send`, the Chrome import, adding skills or a CRX file and making Tiller the default browser, answer at once with a job id, and `jobs.wait` answers once the job ends, or after 20 seconds with it still running, so `tiller` asks again. The requests are in `ControlServer.swift`, `AppControl.swift` (Tiller as a whole, extensions and jobs), `ProfileControl.swift` (history, downloads, settings, sites, logins, import) and `BrowserWindowController.swift` (tabs, the window and `agent.*`). The tool code is in `mcp/src/browser.rs`; `mcp/src/main.rs` wraps it as MCP and `mcp/src/bin/tiller/` as the CLI, a module per area.

## run_task

`run_task` hands a goal on the page, such as "search one-way flights from Zurich to London on 20 September for one adult", to [TypeSafe's Jev](https://docs.typesafe.ai/introduction), following [jev-ultrafast](https://github.com/browser-use/jev-ultrafast). Instead of writing each step, Jev chooses it: each turn Tiller reads the visible part of the page, numbers the controls a click can reach, and asks in one request which operation comes next (click, type, select, scroll up or down, wait, done or blocked) and which element each operation would act on, so a step takes a few hundred milliseconds. When Jev picks typing, a small text model writes the field's value from the goal. Settings > Jev holds the TypeSafe key, the text model's OpenAI-compatible URL, model and key (OpenRouter's `inception/mercury-2.5` unless changed), all kept in the profile, the keys in the Keychain. The keys stay in the app: `tiller_mcp` sends the requests to it as `jev.decide` and `jev.text`, and the app adds the key. Without a TypeSafe key, `tiller_mcp` leaves `run_task` out of its tools (it asks the app with `jev.status`), and agents aren't told about it; with one but no text model key, the tool says it can't type, and agents give it only goals that need no typing. Checking which keys are set doesn't read them, so it never makes macOS ask for the login password; a key is read the first time run_task uses it and kept in memory until Tiller quits. Agents see a change from their next start. `tiller run` is always there and says which key is missing.

The model only ever picks among the elements Tiller listed; it never writes selectors, coordinates or script, and the text model's answer has to be a JSON object with only `text`, which is typed and nothing else. Before acting, Tiller checks the decision is still about the page as it is: the element still there, with the same role and label, not covered, and the URL the same, or for typing, scrolling, waiting and done, the whole visible page unchanged. Otherwise it reads the page again and asks again. Nothing that acts on the page is tried twice: when it isn't known whether an action landed, the run stops.

A run ends `done` when Jev says every part of the goal is visibly met, which is its judgement and worth checking with `read_page`; `blocked` when Jev says so, when the text model finds no value for a field in the goal, when three actions in a row leave the page unchanged, or when the same action comes up three times in six steps; `out_of_steps` after `max_steps` actions (30 unless given, at most 60) or twice as many decisions; `stopped` when the call is cancelled or the agent goes away; and `error` when a model can't be reached or a key is missing. It answers with the status, each step (what it did, the text it typed, whether the page changed, and when), the URL and title it ended on and how long it took.

Jev reads only the visible page and the common HTML and ARIA controls: frames, shadow roots, canvas, file uploads, pop-up windows and widgets driven by the keyboard are out of its reach. The goal and the visible text of the page go to TypeSafe, and to the text model when it types.

## chrome-use and CDP

Turn on **Settings > General > Allow remote debugging (CDP)** and restart Tiller. Chromium then exposes CDP at `127.0.0.1:9222`:

```sh
chrome-use connect 9222
chrome-use open https://example.com
chrome-use snapshot
```

Pages opened through CDP appear in separate Chromium-style windows and stay outside the Tiller tab bar. To take over a Tiller tab, use `chrome-use tab adopt <url|targetId>`.

If another program is already using `127.0.0.1:9222`, Chromium falls back to the IPv6 loopback address `[::1]:9222`, while `chrome-use connect 9222` still reaches that program, not Tiller. Quit Tiller, then start it with another port:

```sh
open -a Tiller --args --remote-debugging-port=N
```

CDP gives any local process access to read and change pages and sign-in data in every profile, so leave the setting off when it is not needed.

## Debug launch arguments

Debug builds (`scripts/bundle.sh debug`) accept extra launch arguments.

Three arguments test the Chrome import: `-chromeDataDir <folder>` reads a Chrome data folder other than the real one, `-chromeSafeStoragePassword <password>` uses that password instead of the keychain's, and `-importChrome YES` imports everything from the last-used profile at launch and logs the result. `-importChrome extensions,history` imports only those kinds (`cookies`, `passwords`, `history`, `settings`, `extensions`).

`-addExtension <path>` adds an unpacked extension folder, or a CRX file when the path ends in `.crx`, and logs the result. It loads at the next launch.

Three arguments test the agent panel without typing: `-agentPrompt "..."` opens the panel and sends that message, `-agentStopAfter <seconds>` presses Stop after that many seconds, and `-agentPasteImage YES` pastes the clipboard into the field twice before sending the prompt three seconds later.

Debug builds also answer `ui.*` methods on the control socket, for driving the window from a script, such as for screenshots. Each takes `text`: `ui.agent` toggles the panel; `ui.agentAction` runs one of its buttons (`newChat`, `newTab`, `closeTab`, `history`, `tools`, `model`, `focus`, `enter`, `ctrlEnter`, or `tab1` to `tab9`); `ui.agentText` puts the text in the message field; `ui.find` searches for it; `ui.location` types it in the address bar; `ui.locationCommand` runs a text command there by selector name, such as `moveDown:` or `cancelOperation:`; `ui.status` shows it in the link plate; `ui.action` runs a menu action by selector name, such as `showDevTools:`; `ui.settings` opens that pane; `ui.appearance` forces `light` or `dark` until the Appearance setting next changes; `ui.tabLayout` puts the tabs `horizontal` or `vertical`; `ui.downloads`, `ui.sidebar` and `ui.focusPage` do what they say; `ui.unloadTabs` unloads the background tabs as critically low memory does; and `ui.resize` takes `width` and `height` instead. The socket speaks one JSON object per line, `{"id": 1, "method": "ui.find", "params": {"text": "tiller"}}`, and answers with one.
