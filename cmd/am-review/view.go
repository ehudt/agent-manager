package main

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/charmbracelet/x/ansi"

	"github.com/ehud-tamir/agent-manager/internal/sessions"
)

// hunk is one @@ block of a unified diff: where it starts in the parsed line
// list and the new-side line range it covers (for review comments).
type hunk struct {
	Start    int // index into diffDoc.Lines of the @@ header
	End      int // index one past the hunk's last line
	NewStart int // first new-side line number
	NewCount int
	Header   string
}

// diffDoc is one file's unified diff, split into lines with hunk boundaries.
type diffDoc struct {
	Path  string
	Lines []string
	Hunks []hunk
}

// parseDiff splits git's unified output into lines and hunks. Tabs are
// expanded so column widths are predictable in the viewport.
func parseDiff(path, text string) diffDoc {
	doc := diffDoc{Path: path}
	if strings.TrimSpace(text) == "" {
		return doc
	}
	doc.Lines = strings.Split(strings.TrimRight(text, "\n"), "\n")
	for i, l := range doc.Lines {
		doc.Lines[i] = strings.ReplaceAll(l, "\t", "    ")
		if strings.HasPrefix(l, "@@") {
			if n := len(doc.Hunks); n > 0 {
				doc.Hunks[n-1].End = i
			}
			h := hunk{Start: i, End: len(doc.Lines), Header: l}
			h.NewStart, h.NewCount = hunkNewRange(l)
			doc.Hunks = append(doc.Hunks, h)
		}
	}
	return doc
}

// hunkNewRange reads "+c,d" out of "@@ -a,b +c,d @@ ..." (d defaults to 1).
func hunkNewRange(header string) (int, int) {
	fields := strings.Fields(header)
	for _, f := range fields[1:] {
		if !strings.HasPrefix(f, "+") {
			continue
		}
		spec := strings.TrimPrefix(f, "+")
		start, count := spec, "1"
		if i := strings.IndexByte(spec, ','); i >= 0 {
			start, count = spec[:i], spec[i+1:]
		}
		s, _ := strconv.Atoi(start)
		c, _ := strconv.Atoi(count)
		return s, c
	}
	return 0, 0
}

// hunkAt is the index of the hunk containing line (or the last hunk that
// starts before it); -1 when the document has no hunks or line precedes them.
func (d diffDoc) hunkAt(line int) int {
	idx := -1
	for i, h := range d.Hunks {
		if h.Start <= line {
			idx = i
		}
	}
	return idx
}

// hunkText is the hunk's lines (header included), capped to limit lines with a
// trailing "…" marker when cut.
func (d diffDoc) hunkText(i, limit int) string {
	if i < 0 || i >= len(d.Hunks) {
		return ""
	}
	h := d.Hunks[i]
	lines := d.Lines[h.Start:h.End]
	if limit > 0 && len(lines) > limit {
		lines = append(append([]string{}, lines[:limit]...), "…")
	}
	return strings.Join(lines, "\n")
}

// lineRange renders the hunk's new-side span as "L12" or "L12-40".
func (h hunk) lineRange() string {
	if h.NewCount <= 1 {
		return "L" + strconv.Itoa(h.NewStart)
	}
	return "L" + strconv.Itoa(h.NewStart) + "-" + strconv.Itoa(h.NewStart+h.NewCount-1)
}

// truncRunes cuts s to at most w cells (rune-counted), marking the cut with
// a 1-col ellipsis. w <= 0 yields "".
func truncRunes(s string, w int) string {
	if w <= 0 {
		return ""
	}
	r := []rune(s)
	if len(r) <= w {
		return s
	}
	if w == 1 {
		return "…"
	}
	return string(r[:w-1]) + "…"
}

// truncStyled truncates a string that carries ANSI styling to w columns with
// a 1-col `…`. truncRunes counts escape bytes as columns, so on styled text
// it cut early (the footer lost its hunk position on a 95-col pane) and could
// split an escape sequence.
func truncStyled(s string, w int) string {
	if w <= 0 {
		return ""
	}
	if ansi.StringWidth(s) <= w {
		return s
	}
	return ansi.Truncate(s, w, "…")
}

// fitHints lays out the footer: key hints joined by two spaces, dropping
// trailing (least important) hints until the line fits in w columns, with
// pos (the hunk position) right-aligned when there is room. A hint is never
// cut mid-word. With pos and few hints competing for a narrow pane, pos wins
// once at least the three navigation hints are shown.
func fitHints(parts []string, pos string, w int) string {
	pw := ansi.StringWidth(pos)
	if pos != "" {
		for n := len(parts); n >= 3 && n <= len(parts); n-- {
			line := strings.Join(parts[:n], "  ")
			if lw := ansi.StringWidth(line); lw+2+pw <= w {
				return line + strings.Repeat(" ", w-lw-pw) + pos
			}
		}
	}
	for n := len(parts); n >= 0; n-- {
		line := strings.Join(parts[:n], "  ")
		if ansi.StringWidth(line) <= w {
			return line
		}
	}
	return ""
}

// checkpointHeader / checkpointRow render the picker's table: mark, id, kind,
// the change the row would show (checkpoint tree → worktree), HEAD, age,
// branch — the `am diff --list` columns plus the delta, branch last because it
// is the column a narrow pane can spare. The mark is `*` for the baseline and
// `>` for the base the pane shows now (when it is not the baseline).
func checkpointHeader() string {
	return fmt.Sprintf("  %-8s %-7s %-17s %-8s %-8s %s", "ID", "KIND", "CHANGE SINCE", "HEAD", "WHEN", "BRANCH")
}

func checkpointRow(cp sessions.Checkpoint, rs sessions.ReviewStat, baselineID, shownID string, now int64) string {
	mark := " "
	switch {
	case cp.ID == baselineID:
		mark = "*"
	case cp.ID == shownID:
		mark = ">"
	}
	branch := cp.Branch
	if branch == "" {
		if cp.Kind == "commit" || cp.Kind == "pick" {
			branch = "-"
		} else {
			branch = "(detached)"
		}
	}
	head := "-"
	if c := cp.AnchorCommit(); c != "" {
		head = shortID(c)
	}
	return fmt.Sprintf("%s %-8s %-7s %-17s %-8s %-8s %s", mark, shortID(cp.ID), cp.Kind, deltaCell(rs), head, ago(cp.Time, now), tailPath(branch, 24))
}

// deltaCell is the picker's change column: `Δ7 +212 −48`, `Δ0` for a base
// equal to the worktree, `?` when the row was not measured.
func deltaCell(rs sessions.ReviewStat) string {
	if rs.BaseTree == "" {
		return "?"
	}
	if rs.Files == 0 {
		return "Δ0"
	}
	return fmt.Sprintf("Δ%d +%d −%d", rs.Files, rs.Added, rs.Deleted)
}

// padRight pads s with spaces to w runes (never truncates).
func padRight(s string, w int) string {
	n := len([]rune(s))
	if n >= w {
		return s
	}
	return s + strings.Repeat(" ", w-n)
}

// tailPath keeps the end of a path when it is wider than w, prefixing "…".
func tailPath(p string, w int) string {
	r := []rune(p)
	if len(r) <= w {
		return p
	}
	if w <= 1 {
		return "…"
	}
	return "…" + string(r[len(r)-(w-1):])
}

// statLine is "7 files +212 −48" or "no changes".
func statLine(files, added, deleted int) string {
	if files == 0 {
		return "no changes"
	}
	noun := "files"
	if files == 1 {
		noun = "file"
	}
	return strconv.Itoa(files) + " " + noun + " +" + strconv.Itoa(added) + " −" + strconv.Itoa(deleted)
}

// ago renders a unix timestamp's age like the bash format_time_ago.
func ago(then, now int64) string {
	d := now - then
	if d < 0 {
		d = 0
	}
	switch {
	case d < 60:
		return strconv.FormatInt(d, 10) + "s ago"
	case d < 3600:
		return strconv.FormatInt(d/60, 10) + "m ago"
	case d < 86400:
		return strconv.FormatInt(d/3600, 10) + "h ago"
	default:
		return strconv.FormatInt(d/86400, 10) + "d ago"
	}
}
