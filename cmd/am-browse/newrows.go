package main

// The "New session" section of the browser list: launch targets matched by
// the same query that filters the sessions. Recent directories, path
// completions, the dir_provider's `@spec` suggestions, and the saved presets
// are rows; Enter on one prints the protocol line
// __NEW_SESSION__␟directory␟agent␟flags, parsed by cmd_browse and cmd_new.
// flags carries --preset=<name> for a preset row. A directory or spec row launches
// with the list's agent (Tab / Shift-Tab), a preset row with its own. `am
// new` with no arguments (--new) opens the same list with the cursor here.
// Replaced the two-stage new-session form in 0.40.

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/ehud-tamir/agent-manager/internal/sessions"
)

type newKind int

const (
	newDir    newKind = iota // a directory: recent, typed, completed, or the Ctrl-N seed
	newSpec                  // an @spec the dir_provider resolves at launch
	newPreset                // a saved preset (am preset save)
)

// newRow is one launch target.
type newRow struct {
	kind   newKind
	value  string // a path (as typed: ~ and relative allowed) or an @spec; a preset's directory
	label  string // dim annotation: branch · N running, the provider's label, a preset's summary
	preset string // newPreset: the preset name
	tier   int    // match quality against the query (matchTier), for the cursor placement
}

func (r newRow) key() string {
	return fmt.Sprintf("new:%d:%s:%s", r.kind, r.preset, r.value)
}

// frecentMsg delivers the recent directory list (loaded once, off the UI
// thread).
type frecentMsg struct{ paths []string }

// providerMsg delivers the provider's suggestions for one `@` query.
type providerMsg struct {
	query string
	rows  []sessions.DirSuggestion
}

const (
	newMaxRows    = 50 // directory rows a query shows
	newIdleRecent = 3  // recent directories under an empty query
)

// launcher is the state behind the New session section.
type launcher struct {
	cfg    sessions.Config
	amDir  string
	home   string
	agents []string // manifest order
	agent  string   // the agent of directory and @spec rows
	seed   string   // Ctrl-N on a session row: its directory, first until the query changes

	frecent         []string
	frecentLoaded   bool
	providerCache   map[string][]sessions.DirSuggestion // by query, with the @
	providerPending map[string]bool
	suggest         func(partial string) []sessions.DirSuggestion
	branches        map[string]string // GitHeadBranch by directory
}

// newLauncher builds the section's state; agent falls back to the
// configured default, an unknown one to the first manifest type.
func newLauncher(cfg sessions.Config, amDir, home, agent string) launcher {
	l := launcher{
		cfg:             cfg,
		amDir:           amDir,
		home:            home,
		agents:          sessions.AgentTypes(),
		providerCache:  map[string][]sessions.DirSuggestion{},
		providerPending: map[string]bool{},
		branches:        map[string]string{},
	}
	if agent == "" {
		agent = cfg.DefaultAgentType()
	}
	agent = sessions.NormalizeAgent(agent)
	if _, ok := sessions.Agent(agent); !ok && len(l.agents) > 0 {
		agent = l.agents[0]
	}
	l.agent = agent
	provider := cfg.DirProviderCmd()
	l.suggest = func(partial string) []sessions.DirSuggestion {
		return sessions.DirProviderSuggest(amDir, provider, partial, sessions.DirSuggestTimeout())
	}
	return l
}

// loadFrecent loads the recent directory list.
func (l launcher) loadFrecent() tea.Cmd {
	if l.frecentLoaded {
		return nil
	}
	amDir, home := l.amDir, l.home
	return func() tea.Msg {
		return frecentMsg{paths: sessions.FrecentDirs(amDir, home)}
	}
}

// cycleAgent moves the agent choice by step (+1 / -1), wrapping.
func (l *launcher) cycleAgent(step int) {
	if len(l.agents) == 0 {
		return
	}
	next := l.agents[0]
	for i, a := range l.agents {
		if a == l.agent {
			next = l.agents[(i+step+len(l.agents))%len(l.agents)]
			break
		}
	}
	l.agent = next
}

// isPathQuery reports a query that names a path (`/`, `~`, `.`).
func isPathQuery(q string) bool {
	return q != "" && (q[0] == '/' || q[0] == '~' || q[0] == '.')
}

// isPlaceQuery reports a query that asks for a place to launch in: a path or
// an @spec. The cursor lands on the New session section for these.
func isPlaceQuery(q string) bool {
	return isPathQuery(q) || strings.HasPrefix(q, "@")
}

// expand is a value with a leading ~ expanded.
func (l launcher) expand(v string) string {
	if strings.HasPrefix(v, "~") {
		return l.home + v[1:]
	}
	return v
}

// absPath is a path query as an absolute path, for matching it against
// session directories.
func (l launcher) absPath(q string) string {
	p := l.expand(q)
	if strings.HasPrefix(p, ".") {
		if abs, err := filepath.Abs(p); err == nil {
			return abs
		}
	}
	return p
}

// abbrev shows a path under $HOME with ~.
func (l launcher) abbrev(p string) string {
	if l.home != "" && (p == l.home || strings.HasPrefix(p, l.home+"/")) {
		return "~" + p[len(l.home):]
	}
	return p
}

// rows builds the section for the query (as typed). live counts the running
// sessions per directory, for the annotation. The Cmd is a provider fetch
// when an `@` query has no answer yet (one run per distinct query; while it
// runs, and when it finds nothing, the typed spec is the one row, so Enter
// still resolves it).
func (l *launcher) rows(q string, live map[string]int) ([]newRow, tea.Cmd) {
	var out []newRow
	seen := map[string]bool{}
	dirs := 0
	addDir := func(value string, tier int) {
		path := l.expand(value)
		if dirs >= newMaxRows || seen[path] {
			return
		}
		seen[path] = true
		dirs++
		out = append(out, newRow{kind: newDir, value: value, label: l.dirLabel(path, live), tier: tier})
	}
	if l.seed != "" {
		addDir(l.seed, 0)
	}

	if strings.HasPrefix(q, "@") {
		rows, cached := l.providerCache[q]
		if cached && len(rows) > 0 {
			for i, r := range rows {
				if i >= newMaxRows {
					break
				}
				out = append(out, newRow{kind: newSpec, value: "@" + r.Spec, label: r.Label, tier: 4})
			}
			return out, nil
		}
		out = append(out, newRow{kind: newSpec, value: q, label: "resolve with dir_provider", tier: 4})
		if cached || l.providerPending[q] {
			return out, nil
		}
		if l.cfg.DirProviderCmd() == "" {
			l.providerCache[q] = nil
			return out, nil
		}
		l.providerPending[q] = true
		suggest := l.suggest
		return out, func() tea.Msg {
			return providerMsg{query: q, rows: suggest(strings.TrimPrefix(q, "@"))}
		}
	}

	if isPathQuery(q) {
		// The directory the query names first (Enter must not pick a child),
		// then recent ones under it, then the filesystem completions.
		if isDir(l.expand(q)) {
			addDir(q, 4)
		}
		abs := strings.ToLower(l.absPath(q))
		for _, p := range l.frecent {
			if strings.Contains(strings.ToLower(p), abs) {
				addDir(p, 2)
			}
		}
		for _, p := range sessions.PathCompletions(q, l.home) {
			addDir(p, 2)
		}
		return out, nil
	}

	// Recent directories: the first few under an empty query, else every
	// substring match, best tier first (recency order within a tier). The
	// tier counts the basename like the path's start, since a session's
	// display starts with it: a project name ties the directory with its
	// sessions, and the list order breaks the tie (running, new, inactive).
	lq := strings.ToLower(q)
	var recent []newRow
	for _, p := range l.frecent {
		if q == "" && len(recent) >= newIdleRecent {
			break
		}
		if seen[p] {
			continue
		}
		tier := 4
		if q != "" {
			short, full := strings.ToLower(l.abbrev(p)), strings.ToLower(p)
			if !strings.Contains(short, lq) && !strings.Contains(full, lq) {
				continue
			}
			tier = maxInt(maxInt(matchTier(short, lq), matchTier(strings.ToLower(filepath.Base(p)), lq)), 2)
		}
		seen[p] = true
		recent = append(recent, newRow{kind: newDir, value: p, label: l.dirLabel(p, live), tier: tier})
		if len(recent)+dirs >= newMaxRows {
			break
		}
	}
	sort.SliceStable(recent, func(a, b int) bool { return recent[a].tier > recent[b].tier })
	out = append(out, recent...)

	for _, name := range l.cfg.PresetNames() {
		p := l.cfg.Presets[name]
		tier := 4
		if q != "" {
			tier = matchTier(strings.ToLower(name+" "+p.Directory+" "+p.Agent), lq)
		}
		if tier == 0 {
			continue
		}
		out = append(out, newRow{kind: newPreset, value: p.Directory, preset: name, label: l.presetLabel(p), tier: tier})
	}
	return out, nil
}

// dirLabel is a directory row's annotation: its branch and how many running
// sessions work there.
func (l launcher) dirLabel(path string, live map[string]int) string {
	branch, ok := l.branches[path]
	if !ok {
		branch = sessions.GitHeadBranch(path)
		l.branches[path] = branch
	}
	var parts []string
	if branch != "" {
		parts = append(parts, branch)
	}
	if n := live[path]; n > 0 {
		parts = append(parts, fmt.Sprintf("%d running", n))
	}
	return strings.Join(parts, " · ")
}

// presetLabel is a preset row's annotation: where and with which agent.
func (l launcher) presetLabel(p sessions.Preset) string {
	dir := "no directory"
	if p.Directory != "" {
		dir = l.abbrev(p.Directory)
	}
	agent := p.Agent
	if agent == "" {
		agent = l.agent
	}
	return "preset · " + dir + " · " + agent
}

// launch validates a row and returns the protocol line, or the error to
// show. An @spec passes unvalidated (cmd_new resolves it) once a
// dir_provider is configured; a path must exist.
func (l launcher) launch(r newRow) (output, errMsg string) {
	agent, flags := l.agent, ""
	if r.kind == newPreset {
		p := l.cfg.Presets[r.preset]
		if p.Directory == "" {
			return "", fmt.Sprintf("Preset %s has no directory (am new -p %s <dir>)", r.preset, r.preset)
		}
		if p.Agent != "" {
			agent = sessions.NormalizeAgent(p.Agent)
		}
		flags = "--preset=" + r.preset
	}
	dir := l.expand(r.value)
	if strings.HasPrefix(dir, "@") {
		if l.cfg.DirProviderCmd() == "" {
			return "", fmt.Sprintf("No directory provider configured for %s (am config set dir_provider <cmd>)", dir)
		}
	} else if !isDir(dir) {
		return "", "Directory does not exist: " + dir
	}
	if _, ok := sessions.Agent(agent); !ok {
		return "", "Invalid agent type: " + agent
	}
	return "__NEW_SESSION__\x1f" + dir + "\x1f" + agent + "\x1f" + flags, ""
}

func isDir(path string) bool {
	st, err := os.Stat(path)
	return err == nil && st.IsDir()
}

// describe is the preview of a launch target: a directory's branch,
// uncommitted files, recent commits, and the sessions that worked there
// (here, already formatted); how an @spec resolves; a preset's fields.
// Runs git, so it is called off the UI thread.
func (l launcher) describe(r newRow, here []string) string {
	var b strings.Builder
	switch r.kind {
	case newPreset:
		p := l.cfg.Presets[r.preset]
		fmt.Fprintf(&b, "Preset %s\n\n", r.preset)
		for _, kv := range [][2]string{
			{"directory", p.Directory},
			{"agent", p.Agent},
			{"args", strings.Join(p.Args, " ")},
		} {
			if kv[1] != "" {
				fmt.Fprintf(&b, "  %-10s %s\n", kv[0], kv[1])
			}
		}
		if p.Shell {
			fmt.Fprintf(&b, "  %-10s %s\n", "shell", "open")
		}
		return b.String()
	case newSpec:
		fmt.Fprintf(&b, "%s is resolved by the dir_provider at launch:\n\n  %s resolve %s\n",
			r.value, l.cfg.DirProviderCmd(), strings.TrimPrefix(r.value, "@"))
		if r.label != "" && r.label != "resolve with dir_provider" {
			b.WriteString("\n" + r.label + "\n")
		}
		return b.String()
	}
	dir := l.expand(r.value)
	if branch := sessions.GitHeadBranch(dir); branch == "" {
		fmt.Fprintf(&b, "%s\n(not a git repository)\n", l.abbrev(dir))
	} else {
		fmt.Fprintf(&b, "%s on %s\n", l.abbrev(dir), branch)
		if status := gitLines(dir, 10, "status", "--short"); status != "" {
			b.WriteString("\nUncommitted\n" + status)
		}
		if log := gitLines(dir, 5, "log", "--oneline", "-5"); log != "" {
			b.WriteString("\nRecent commits\n" + log)
		}
	}
	if len(here) > 0 {
		b.WriteString("\nSessions here\n")
		for _, s := range here {
			b.WriteString("  " + s + "\n")
		}
	}
	return b.String()
}

// gitLines runs git in dir and returns at most max output lines, indented,
// with a "… N more" line for the rest.
func gitLines(dir string, max int, args ...string) string {
	out, err := exec.Command("git", append([]string{"-C", dir}, args...)...).Output()
	if err != nil {
		return ""
	}
	lines := strings.Split(strings.TrimRight(string(out), "\n"), "\n")
	if len(lines) == 1 && lines[0] == "" {
		return ""
	}
	var b strings.Builder
	for i, line := range lines {
		if i == max {
			fmt.Fprintf(&b, "  … %d more\n", len(lines)-max)
			break
		}
		b.WriteString("  " + line + "\n")
	}
	return b.String()
}

// trimPaste drops the line breaks a paste ends with: a copied path usually
// carries one, and the filter is a single line (the text input turns inner
// line breaks into spaces).
func trimPaste(msg tea.KeyMsg) tea.KeyMsg {
	if !msg.Paste {
		return msg
	}
	runes := msg.Runes
	for len(runes) > 0 && (runes[len(runes)-1] == '\n' || runes[len(runes)-1] == '\r') {
		runes = runes[:len(runes)-1]
	}
	msg.Runes = runes
	return msg
}

// truncRunesTo cuts a plain string to width cells with a trailing ….
func truncRunesTo(s string, width int) string {
	r := []rune(s)
	if width < 2 || len(r) <= width {
		return s
	}
	return string(r[:width-1]) + "…"
}
