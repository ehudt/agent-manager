# Form Keyboard Navigation Design

**Goal:** Replace the ad-hoc per-field-type key handling with a coherent two-mode input model (Navigate / Edit), and add directory suggestion scrolling.

**Scope:** Keyboard interaction and input only. Visual design (colors, box drawing, layout) is a separate project.

## Modes

The form has two modes: **Navigate** and **Edit**.

- Form starts in Navigate mode.
- Only `text` and `directory` fields are editable (enter Edit mode).
- `checkbox` and `select` fields are toggled/cycled inline in Navigate mode.

### Navigate mode

| Key | Action |
|-----|--------|
| Up / Down | Move field cursor |
| Enter | text/directory: enter Edit mode. checkbox: toggle. select: cycle. `[ Create ]` row: submit |
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

- Typing filters the suggestion list in real-time.
- Up/Down moves a highlight index through visible suggestions (currently hardcoded to first; will track `_FORM_DIR_HIGHLIGHT`).
- Tab accepts the highlighted suggestion into the field value.
- Enter exits Edit mode with the current field value.

## Submit row

A `[ Create ]` pseudo-field at the bottom of the field list. In Navigate mode, arrow down to it and press Enter to submit. Ctrl-S also submits from anywhere.

## Visual indicators (minimal, just enough for mode clarity)

- Navigate, focused field: `> Label:  value`
- Edit mode field: `» Label:  value█` (different prefix + block cursor)
- Directory suggestions: cyan for highlighted, dim for others. Highlight follows Up/Down.

## Esc behavior

- Edit mode → Navigate mode (does not cancel form).
- Navigate mode → cancel form.
- Two presses to fully cancel (standard pattern: vim, fzf, etc.).
