# org-typora-math

Live LaTeX formula previews for Org mode, with an editing interface inspired by [Typora](https://typora.io).

- **Inline formula:** when point enters it, the source shows and a popup displays the preview.
- **Display formula:** when point enters it, the source is highlighted and a centered preview shows below it.
- **Live update:** when you stop typing, the formula compiles in the background and the preview updates.
- **Outside a formula:** the image replaces the source on the screen.

The Org text and the undo history do not change.

## Requirements

- Emacs 29.1 or later, graphical, with SVG support
- Org 9.6 or later
- `latex` and `dvisvgm` on `PATH`

Tested with Emacs 31.1 and Org 9.8.7.

## Installation

<details>
<summary>Vanilla Emacs</summary>

Add to `init.el`, then restart Emacs:

```elisp
(add-to-list 'load-path "/path/to/org-typora-math")
(require 'org-typora-math)
```

</details>

<details>
<summary>Doom Emacs</summary>

Add to `packages.el`:

```elisp
(package! org-typora-math
  :recipe (:host github :repo "minyez/org-typora-math"
           :files ("org-typora-math.el")))

;; or from a local checkout:
(package! org-typora-math
  :recipe (:local-repo "/path/to/org-typora-math"
           :files ("org-typora-math.el")))
```

Add to `config.el`:

```elisp
(use-package! org-typora-math
  :commands (org-typora-math-mode
             org-typora-math-refresh
             org-typora-math-show-log))
```

Run `doom sync`, then restart Emacs.

</details>

## Usage

Run `M-x org-typora-math-mode` in an Org buffer.
After `org-typora-math-idle-delay` seconds, the mode compiles all formulas one at a time, starting with the formula at point.

To enable the mode in all Org buffers:

```elisp
(add-hook 'org-mode-hook #'org-typora-math-mode t)
```

The final `t` adds the mode after other hook functions, so that it can turn off `org-fragtog-mode` (see [Compatibility](#compatibility)).

While you edit:

- A new edit stops the current compilation.
- If a compilation fails, the last good image stays.
  The error shows in the echo area and as a mouse tooltip, and `M-x org-typora-math-show-log` shows the compiler output.

### Commands

| Command | Description |
| --- | --- |
| `org-typora-math-mode` | Toggle previews in the current Org buffer. |
| `org-typora-math-refresh` | Ignore cached images, including the files on disk, and compile all formulas again, including failed ones. |
| `org-typora-math-clear-cache` | Delete the disk cache directory after a confirmation that shows its size. |
| `org-typora-math-show-log` | Show the compiler output for the current buffer. |

Run `org-typora-math-refresh` after you change files that the cache key does not see, for example a `#+SETUPFILE`, an `\input` file, or a TeX package.

### Options

| Variable | Default | Description |
| --- | --- | --- |
| `org-typora-math-cache-directory` | `user-emacs-directory/org-typora-math/` | Directory for the disk cache of SVG images; `nil` keeps images in memory only |
| `org-typora-math-idle-delay` | `0.6` | Seconds without edits before compilation starts |
| `org-typora-math-scale` | `2.0` | Display scale of the SVG images (no new compilation) |
| `org-typora-math-display-center` | `window` | Center of display previews: `window`, `fill-column` (column `fill-column`/2), an integer column, or a float fraction of the window width |
| `org-typora-math-inline-popup` | `t` | Popup for inline formulas; `nil` shows the preview below the source |
| `org-typora-math-process-timeout` | `15` | Maximum seconds for each compiler stage |
| `org-typora-math-latex-program` | `"latex"` | Program that makes DVI (a name or an absolute path) |
| `org-typora-math-dvisvgm-program` | `"dvisvgm"` | Program that converts DVI to SVG |

The `org-typora-math-source` face sets the background of the source that you edit.
After you change the scale, move point into or out of a formula to redraw the preview.

### Preamble

The preamble is the same as for native Org previews:

- `org-format-latex-header`
- the Org package lists for snippets
- the `#+LATEX_HEADER:` lines of the buffer (`#+LATEX_HEADER_EXTRA:` does not apply)

If the `dvisvgm` entry of `org-preview-latex-process-alist` has a `:latex-header` value, that value replaces all of the above.

## How it works

- Org's syntax tree finds the formulas, so `$...$` in source blocks is not previewed.
  As in native Org previews, only `$...$`, `$$...$$`, `\(...\)`, `\[...\]`, and LaTeX environments are previewed. Commands such as `\ref{...}` are not.
- Each buffer runs at most one `latex` or `dvisvgm` process at a time.
  Process sentinels run the two stages in sequence.
- Each compilation runs in its own temporary directory. The directory is deleted when the job ends or stops.
- SVG images are cached in memory for each buffer and on disk in `org-typora-math-cache-directory`.
  Each file is named after a hash of the full TeX document, so an image is reused only when the formula, the preamble, the text color, and the programs are the same.
  The disk cache stays after you disable the mode, revert the buffer, or restart Emacs.
- When you disable the mode, kill the buffer, or change the major mode, all processes, timers, overlays, and popups are removed.

## Limitations

### Compilation

- Each formula is a separate document. Equation numbers start again at each formula, and references between formulas do not work.
- Only DVI output is supported. You cannot use XeLaTeX or LuaLaTeX with PDF output.
- Compilation runs in a temporary directory. Use absolute paths for files that the preamble loads, for example with `\input`.
- Compilation is asynchronous, but the buffer scan after each pause is not. The first scan of a long document with many formulas can be slow, because Org builds its element cache. Later scans are faster.
- A buffer that no window shows does not compile. It starts when you first show it, so a background buffer may need a short time to show its previews.
- The preamble is cached, and the contents of a `#+SETUPFILE` are not watched. After you edit a setup file, run `org-typora-math-refresh`.
- The cache directory has no size limit and keeps each good SVG version while you edit. Use `org-typora-math-clear-cache` to delete it. Changes in `#+SETUPFILE` or `\input` files are not in the cache key, so run `org-typora-math-refresh` after them.

### Display

- All windows that show the same buffer share one state for source visibility.
- The popup shows only in the selected window. If child frames are not available, the preview shows below the source.

### Compatibility

- When the mode starts, it clears native formula previews and turns off `org-fragtog-mode` in the buffer.
  When the mode stops, it turns `org-fragtog-mode` on again only if it was on before.
- If a later hook or command turns `org-fragtog-mode` on again, change the hook order so that the two modes do not run together.
- `C-c C-x C-l` still runs the native `org-latex-preview`, which can put a second preview on top of this one.
  Use only one automatic preview mode in a buffer.

## Development

```sh
make test      # ERT tests, with real latex and dvisvgm compilation
make compile   # byte-compile; warnings are errors
```

The tests check compilation, `#+LATEX_HEADER:` macros, cache reuse, the edit timer, rejection of old results, failure handling, unchanged text and undo history, and cleanup of processes and temporary directories.
The tests do not draw the GUI. To check the layout, load `demo.el` in a graphical Emacs.

## References

- [Org formula previews](https://orgmode.org/manual/Previewing-LaTeX-fragments.html)
- [Emacs child frames](https://www.gnu.org/software/emacs/manual/html_node/elisp/Child-Frames.html)
- [Doom package management](https://github.com/doomemacs/core/blob/master/docs/getting_started.org#package-management)

## License

GNU GPL version 3 or later. See [LICENSE](LICENSE).
