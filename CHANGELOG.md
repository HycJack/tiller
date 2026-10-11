# Changelog

The update window and the GitHub release show the section of the version
they offer. Write notes under `## Unreleased`; `scripts/bump.sh` turns it
into `## <version>` for a release, and refuses to bump without notes. A
beta shows what `## Unreleased` holds at the time.

## Unreleased

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
