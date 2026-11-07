# org-typora-math

Preview LaTeX formulas in Org mode with an editing interface inspired by [Typora](https://typora.io).

## What this package actually does

1. Move point into an inline formula to reveal its source and show a preview in a popup.
2. Move point into a display formula to highlight its source and show a centered preview below it.
3. Pause editing to compile the formula asynchronously and update the preview.
4. Leave the formula to display the image in place of its source.

## Requirements

- Emacs 29.1 or later with a graphical interface and SVG support
- Org 9.6 or later
- `latex` and `dvisvgm` on `PATH`

## Setup

The current version was tested with Emacs 31.1 and Org 9.8.7.

<details>
<summary>Vanilla Emacs</summary>

In `init.el` add:

```elisp
(add-to-list 'load-path
             (expand-file-name "/path/to/org-typora-math"))
(require 'org-typora-math)
```

Evaluate this configuration or restart Emacs.

</details>

<details>
<summary>Doom Emacs</summary>

In `packages.el` add:

```elisp
(package! org-typora-math
  :recipe (:host github :repo "minyez/org-typora-math"
           :files ("org-typora-math.el")))

;; or from a local checkout:
(package! org-typora-math
  :recipe (:local-repo "/path/to/org-typora-math"
           :files ("org-typora-math.el")))
```

In `config.el` add:

```elisp
(use-package! org-typora-math
  :commands (org-typora-math-mode
             org-typora-math-refresh
             org-typora-math-show-log))
```

Run `doom sync` in a terminal, then restart Emacs.

</details>

## Usage

Run `M-x org-typora-math-mode` in an Org buffer.
On first activation, the mode waits for the configured delay, then compiles all formulas in sequence, starting with the formula at point.

To enable it automatically in Org buffers, add:

```elisp
(add-hook 'org-mode-hook #'org-typora-math-mode t)
```

After `org-typora-math-idle-delay` seconds without edits, the package compiles changed formulas and updates their previews.
Further edits cancel the current compilation. If compilation fails, the last valid image stays visible and the package records the error.
Previews use overlays and child frames without changing the Org text or undo history.

## Customizable options

| Variable | Default | Description |
| --- | --- | --- |
| `org-typora-math-idle-delay` | `0.6` | Seconds to wait after the last text edit |
| `org-typora-math-scale` | `2.0` | SVG display scale, without another LaTeX compilation |
| `org-typora-math-inline-popup` | `t` | Use an inline popup, or set to `nil` for a preview below the source |
| `org-typora-math-process-timeout` | `15` | Maximum seconds for each external process stage |
| `org-typora-math-latex-program` | `"latex"` | Executable that produces DVI, optionally as an absolute path |
| `org-typora-math-dvisvgm-program` | `"dvisvgm"` | Executable that converts DVI to SVG |

Set the delay and image scale in your configuration:

```elisp
(setq org-typora-math-idle-delay 0.6
      org-typora-math-scale 2.0)
```

The `org-typora-math-source` face controls the source background.
After changing the scale, move point into or out of a formula to redraw the preview.

Previews use `org-format-latex-header`, Org's package lists for snippet previews, and the buffer's `#+LATEX_HEADER:` entries.
As with native Org previews, `#+LATEX_HEADER_EXTRA:` does not apply.
If the `dvisvgm` entry in `org-preview-latex-process-alist` has a `:latex-header` value, that preamble takes precedence.

## Commands

| Function | Description |
| --- | --- |
| `org-typora-math-mode` | Enable or disable previews in the current Org buffer. |
| `org-typora-math-refresh` | Clear the image cache and rebuild all previews, including failed formulas. Requires the mode to be enabled. |
| `org-typora-math-show-log` | Show compiler output for the current buffer. |

Use `org-typora-math-refresh` after changing the preamble, theme, or compiler.

## Implementation

- Org's syntax tree identifies formulas and excludes `$...$` inside source blocks from previews.
- Each buffer runs at most one LaTeX or dvisvgm subprocess. `make-process` and process sentinels handle the two compilation stages in sequence.
- SVG images are cached in memory. Each compilation uses a separate temporary directory, removed after completion or cancellation.
- Disabling the mode, killing the buffer, or changing the major mode cleans up processes, timers, overlays, and the popup.
- The inline popup appears in the selected window. If child frames are unavailable, the preview appears below the source.

## Limitations and compatibility

- Each formula compiles as a separate document, so equation numbers restart and references between formulas are not supported.
- The backend requires DVI output. It cannot directly use XeLaTeX or LuaLaTeX with PDF output.
- Compilation runs in a temporary directory. Use absolute paths for external files referenced by commands such as `\input` in the preamble.
- External compilation runs asynchronously, but Org buffer parsing is synchronous after the delay. The first preview pass can take time in long documents with many formulas.
- The memory cache has no capacity limit or eviction policy and retains each successful SVG version during edits. Disable the mode or run `org-typora-math-refresh` to clear it.
- Windows showing the same buffer share the state that controls source visibility.
- Enabling this mode clears native formula previews and temporarily disables `org-fragtog-mode` in the current buffer. Disabling it restores `org-fragtog-mode` only if that mode was previously active.
- The final `t` in the `org-mode-hook` example places this mode after existing ordinary hook functions, so it can disable `org-fragtog-mode` if an earlier hook enabled it. If a later hook or command enables `org-fragtog-mode` again, adjust the order to keep the two modes from running together.
- Use one automatic formula preview mode per buffer. `C-c C-x C-l` still calls native `org-latex-preview`, which can produce overlapping previews.

## Tests

Run these commands from the repository directory:

```sh
make test
make compile
```

Or invoke Emacs directly:

```sh
emacs --batch -Q -L . -l test/org-typora-math-test.el -f ert-run-tests-batch-and-exit
emacs --batch -Q -L . --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile org-typora-math.el
```

Tests cover real LaTeX/dvisvgm compilation, buffer macros, cache reuse, timer replacement after edits, and rejection of obsolete results.
They also check that failed compilations retain the previous image, buffer text and undo history stay unchanged, and processes and temporary directories are cleaned up.
Batch tests skip GUI drawing. Use `demo.el` to check the layout separately.

## References

- [Org formula previews](https://orgmode.org/manual/Previewing-LaTeX-fragments.html)
- [Emacs child frames](https://www.gnu.org/software/emacs/manual/html_node/elisp/Child-Frames.html)
- [Doom package management](https://github.com/doomemacs/core/blob/master/docs/getting_started.org#package-management)

## License

GNU GPL version 3 or later. See [LICENSE](LICENSE).
