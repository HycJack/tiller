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

`tiller` runs the same browser tools from a shell, so scripts and agents outside Tiller, such as Claude Code with its Bash tool, can drive the browser. It ships at `build/Tiller.app/Contents/Helpers/tiller`, not next to `Tiller` in `Contents/MacOS`, where the two names would be one file on a case-insensitive disk. Tiller > Install Command Line Tool… links it as `~/.local/bin/tiller` and says if that folder isn't on your PATH. Install again after moving the app.

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
tiller run "Search flights from Zurich to London on 20 September"
tiller screenshot -o page.jpg      # prints the path; a temp file without -o
tiller eval 'document.title'
tiller close 2
tiller --profile work tabs         # another open profile's tabs
```

| Command | Tool |
|---|---|
| `tabs` | `list_tabs` |
| `new [url] [--background]` | `new_tab` |
| `select <tab>` | `select_tab` |
| `close <tab>` | `close_tab` |
| `go <url>` | `navigate` |
| `read [--max-chars N] [--viewport]` | `read_page` |
| `click <ref>` | `click` |
| `type [ref] <text> [--append] [--submit]` | `type`, into the focused element when no ref or selector is given |
| `choose <ref> <option>` | `select` |
| `run <goal> [--max-steps N]` | `run_task`; prints each step, and exits 1 unless the task ends done |
| `screenshot [-o file]` | `screenshot` |
| `eval <expression>` | `eval_js` |

`--profile <name>` controls that profile instead of the one used last, and takes an id too. The profile has to be open. `--tab <id>` acts on another tab than the selected one, and `--json` prints the raw result instead of text. Options can come before or after the command. `--read` after `click`, `type` or `choose` prints the page afterwards. Refs are stored in the page, so a `read` in one call and a `click` in the next agree. Errors go to stderr with exit code 1, or 2 for bad arguments. Like `tiller_mcp`, it needs Tiller running, with the profile open, and honors `TILLER_SOCKET` and `TILLER_PROFILE`.

The tool code is in `mcp/src/browser.rs`. `mcp/src/main.rs` wraps it as MCP and `mcp/src/bin/tiller.rs` as the CLI.

## run_task

`run_task` hands a goal on the page, such as "search one-way flights from Zurich to London on 20 September for one adult", to [TypeSafe's Jev](https://docs.typesafe.ai/introduction), following [jev-ultrafast](https://github.com/browser-use/jev-ultrafast). Instead of writing each step, Jev chooses it: each turn Tiller reads the visible part of the page, numbers the controls a click can reach, and asks in one request which operation comes next (click, type, select, scroll up or down, wait, done or blocked) and which element each operation would act on, so a step takes a few hundred milliseconds. When Jev picks typing, a small text model writes the field's value from the goal. Settings > Jev holds the TypeSafe key, the text model's OpenAI-compatible URL, model and key (OpenRouter's `inception/mercury-2.5` unless changed), all kept in the profile, the keys in the Keychain. The keys stay in the app: `tiller_mcp` sends the requests to it as `jev.decide` and `jev.text`, and the app adds the key. Without a TypeSafe key, `tiller_mcp` leaves `run_task` out of its tools (it asks the app with `jev.status`), and agents aren't told about it; with one but no text model key, the tool says it can't type, and agents give it only goals that need no typing. Agents see a change from their next start. `tiller run` is always there and says which key is missing.

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

Debug builds also answer `ui.*` methods on the control socket, for driving the window from a script, such as for screenshots. Each takes `text`: `ui.agent` toggles the panel; `ui.agentAction` runs one of its buttons (`newChat`, `newTab`, `closeTab`, `history`, `tools`, `model`, `focus`, `enter`, `ctrlEnter`, or `tab1` to `tab9`); `ui.agentText` puts the text in the message field; `ui.find` searches for it; `ui.location` types it in the address bar; `ui.status` shows it in the link plate; `ui.action` runs a menu action by selector name, such as `showDevTools:`; `ui.settings` opens that pane; `ui.appearance` forces `light` or `dark` until the Appearance setting next changes; `ui.tabLayout` puts the tabs `horizontal` or `vertical`; `ui.downloads`, `ui.sidebar` and `ui.focusPage` do what they say; `ui.unloadTabs` unloads the background tabs as critically low memory does; and `ui.resize` takes `width` and `height` instead. The socket speaks one JSON object per line, `{"id": 1, "method": "ui.find", "params": {"text": "tiller"}}`, and answers with one.
