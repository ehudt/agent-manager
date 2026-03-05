# Form Keyboard Navigation Design

**Goal:** Replace the ad-hoc per-field-type key handling with a coherent two-mode input model (Navigate / Edit), and add directory suggestion scrolling.

**Scope:** Keyboard interaction and input only. Visual design (colors, box drawing, layout) is a separate project.

**Status:** Implemented. Feature-flagged behind `new_form` config option (default off).

## Modes

The form has two modes: **Navigate** and **Edit**.

- Form starts in Navigate mode.
- Only `text` and `directory` fields are editable (enter Edit mode).
- `checkbox` and `select` fields are toggled/cycled with Space in Navigate mode.

### Navigate mode

| Key | Action |
|-----|--------|
| Up / Down | Move field cursor |
| Enter | text/directory: enter Edit mode. checkbox/select/submit: submit form |
| Space | Toggle checkbox / cycle select. No-op on text/directory |
| Ctrl-S | Submit from anywhere |
| Esc | Cancel form |

### Edit mode

| Key | Action |
|-----|--------|
| Printable chars | Type into field (including spaces) |
| Backspace | Delete last char |
| Tab | Directory: accept highlighted suggestion. Text: no-op |
| Up / Down | Directory: scroll suggestion highlight. Text: no-op |
| Enter | Exit Edit mode → Navigate |
| Esc | Exit Edit mode → Navigate |

Left/right cursor movement within text is a stretch goal — not in scope for v1.

## Directory field in Edit mode

- Typing filters the suggestion list in real-time (from zoxide/frecent cache, loaded once lazily).
- Up/Down moves `_FORM_DIR_HIGHLIGHT` through visible suggestions.
- Tab accepts the highlighted suggestion into the field value.
- Typing or backspace resets highlight to 0.
- Enter exits Edit mode with the current field value.

## Submit row

A `[ Create ]` pseudo-field at the bottom of the field list. In Navigate mode, arrow down to it and press Enter to submit. Ctrl-S also submits from anywhere. Enter on any non-text field also submits.

## Visual indicators

- Navigate, focused field: `> Label:  value`
- Edit mode field: `» Label:  value█` (different prefix + block cursor)
- Directory suggestions: cyan for highlighted, dim for others. Highlight follows Up/Down.
- Submit row: blank line above, `> [ Create ]` when focused.

## Esc behavior

- Edit mode → Navigate mode (does not cancel form).
- Navigate mode → cancel form.
- Two presses to fully cancel (standard pattern: vim, fzf, etc.).

## Implementation notes

- All ANSI sequences pre-cached as variables to avoid forking per frame.
- All rendering buffered into `_FORM_BUF` string, written in a single `printf` to `/dev/tty`.
- `stty -ixon` disables terminal flow control so Ctrl-S reaches the form (restored on cleanup).
- Form runs inside `$()` capture — all rendering goes to `/dev/tty`, all input from `/dev/tty`, output contract on stdout.
