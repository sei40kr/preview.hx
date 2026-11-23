# preview.hx

A [Steel](https://github.com/mattwparas/steel) plugin for Helix that runs a live preview tool chosen by the language of the current buffer and opens its URL in the browser.

## Supported languages

| Language | Preview tool |
|---|---|
| Markdown | [mdp](https://github.com/sei40kr/mdp) |

Other languages can be added with `preview-register!` (see [Configuration](#configuration)).

## Requirements

- Helix built with Steel ([mattwparas/helix](https://github.com/mattwparas/helix), branch `steel-event-system`)
- The preview tool for each language you use, on `PATH`

## Install

```sh
forge pkg install --git https://github.com/sei40kr/preview.hx
```

In `~/.config/helix/helix.scm`:

```scheme
(require "preview-hx/preview.scm")
(provide preview preview-stop)
```

## Commands

- `:preview` starts the tool for the current buffer and opens the preview URL in the browser. If the tool is already running, it opens the URL again.
- `:preview-stop` stops the tool for the current buffer.

Closing a buffer stops its tool.

## Configuration

Register a tool for a Helix language id. `{file}` is replaced with the absolute path of the buffer's file, and the tool runs in that file's directory. Turn off the tool's own browser opening; the plugin opens the URL itself.

```scheme
(require "preview-hx/preview.scm")

;; The default.
(preview-register! "markdown" '("mdp" "--no-open" "{file}"))

;; #:url picks the URL from a stdout line (default: the first http(s):// word).
;; #:timeout is how many seconds to wait for the URL (default: 10).
(preview-register! "foo" '("foo-preview" "{file}")
  #:url (lambda (line) (and (starts-with? line "Local: ") (substring line 7 (string-length line))))
  #:timeout 30)

;; Command that opens the URL (default: xdg-open, or open on macOS).
(preview-set-open-command! "firefox")
```

The tool's stdout is searched for the URL; stderr is discarded. If the tool exits or no URL appears within the timeout, it is stopped and an error is shown.

## Caveats

> [!WARNING]
> Helix has no hook for quitting the editor, so tools still running when Helix exits are left behind. Stop them with `:preview-stop` before quitting, or kill them yourself.

> [!NOTE]
> A stopped tool is killed, but shows up as `<defunct>` in `ps` until Helix exits.
