# Changelog

The update window and the GitHub release show the section of the version
they offer. Write notes under `## Unreleased`; `scripts/bump.sh` turns it
into `## <version>` for a release, and refuses to bump without notes. A
beta shows what `## Unreleased` holds at the time.

## Unreleased

- The agent chat fades out under its header and above the message field
  as it scrolls, instead of cutting a line in half at the edge.
- The start page's tiles line up from the left when there are fewer than
  four, rather than spreading out with gaps between them.
- Address suggestions line up their icons and titles with the address
  field's icon and text.
- Small polish: Copy and download buttons light up under the mouse, a
  tab's close button and the skill picker fade in, steps fold away with a
  fade when a turn ends, queued messages show a press, the find bar's
  close button has a round plate, chat history dates are easier to read,
  and Remote debugging moves to the end of Settings → General.
- Chats in background tabs or a hidden panel no longer redraw streamed
  text 20 times a second; they catch up when shown.
- Scrolling a long tab sidebar only moves the tabs in view, and resizing
  the window lays out the toolbar once, when the drag ends.
- The Downloads list no longer updates while closed, and the first
  message to an agent no longer freezes the window while a login shell
  looks for its command.
- Importing a long Chrome history no longer holds up the address bar's
  suggestions and the start page until it finishes.

## 0.2.0

- Background tabs left unused for 30 minutes unload to free their memory,
  and sooner when the Mac runs low on memory. An unloaded tab keeps its
  place, shows a dimmed title and icon, and loads again when selected.
  Tabs playing media, using the camera or microphone, or asking before
  you leave stay loaded. Settings → General turns it off or sets the delay.
- Agents and the `tiller` tool no longer load every tab restored at launch.
  They load only the tab they act on, and `list_tabs` says whether each
  tab is loaded. Tab ids stay the same while a tab is unloaded.
- Fixed a crash in the agent chat with a mouse attached, when a
  conversation grew to about one screen tall.
- Back and forward mouse side buttons now navigate the selected tab,
  including Logitech mice with standard button assignments.

## 0.1.5

- Settings → Providers takes Codex too, so Codex can run on a provider you
  added, such as a relay's Responses API, without a Codex login or any
  change to `~/.codex`.
- A setting lets chrome-use and other tools drive Tiller over the Chrome
  DevTools Protocol on port 9222. It is off by default, as it exposes every
  profile's sign-ins to local processes, and takes effect on the next
  launch.
- Opening an extension's popup from the toolbar no longer crashes Tiller,
  and popups such as Bitwarden's no longer collapse to a narrow strip.
- The tabs, or the address bar with the tabs in the sidebar, fit the
  toolbar on every macOS version, without a wide gap before the trailing
  buttons or pushing them into the overflow menu.
- The address bar keeps a faint fill in light mode, long agent answers
  stream more smoothly, and the start page's tiles stay centered under
  their heading.

## 0.1.4

- **Run commands** lifts Codex's sandbox, so its shell can write anywhere
  and reach the network, as Claude Code's Bash does. Allowing only writing
  keeps it to the workspace.

## 0.1.3

- Fixes profiles that Chromium refused or that raced each other to create
  the same databases at startup.

## 0.1.2

- Tiller runs on macOS 14 and later. Before macOS 26, glass falls back to
  a tinted blur.
- While the agent thinks, a bobbing boat and a sailing phrase replace the
  spinner, and hold still when the system asks for less motion.
- Agent responses have a Copy button and show when they came.
- View Source opens in a tab after the current one, as in Chrome.

## 0.1.1

- Every profile runs in one process under one Dock icon.
