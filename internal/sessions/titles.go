package sessions

import (
	"bufio"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const titleMaxLen = 60

var leadingNonAlnum = regexp.MustCompile(`^[^[:alnum:]]+`)

// metaUpdate is one session's pending registry refresh; only fields whose set
// flag is on are applied.
type metaUpdate struct {
	task, workdir, branch          string
	setTask, setWorkdir, setBranch bool
	review                         ReviewStat
	reviewAt                       int64
	setReview                      bool
}

func (u metaUpdate) empty() bool {
	return !u.setTask && !u.setWorkdir && !u.setBranch && !u.setReview
}

// RefreshTitles refreshes the per-session registry metadata that drifts while
// a session runs: the task (pane title, else the transcript's first user
// message), the live working directory (`workdir`, from the state hook's .cwd
// sidecar or `am cd`, stored only when it differs from the launch directory)
// and the branch (re-read from the effective directory's .git/HEAD, so a
// checkout in place or a move to another copy both relabel the tab). Every
// registry row is scanned (a row whose tmux session is gone yields an empty
// title and is left to GC). Throttled to 60s via .title_scan_last unless
// forced; the marker is stamped on every run. Backs bash auto_title_scan via
// `am-core titles`.
func RefreshTitles(e Env, force bool) {
	markerPath := filepath.Join(e.AmDir, ".title_scan_last")
	now := time.Now()
	if !force && !markerDue(markerPath, now) {
		return
	}
	if err := stampMarker(markerPath, now); err != nil {
		return
	}

	e.capDebugLogs()
	e.titlerLog("scan start (force=%v)", force)

	regPath := e.RegistryPath()
	registry := ReadRegistry(regPath)

	// Phase 1 (unlocked): compute updates against a registry snapshot. Slow
	// (tmux exec + file reads per session), so it must not run under the
	// registry lock.
	updates := make(map[string]metaUpdate)
	names := make([]string, 0, len(registry.Sessions))
	for name := range registry.Sessions {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		meta := registry.Sessions[name]
		var u metaUpdate
		u.workdir, u.setWorkdir, u.branch, u.setBranch = refreshedWorkdir(e.StateDir, name, meta)
		if u.setWorkdir {
			e.titlerLog("  %s: workdir=%q", name, u.workdir)
		}
		if u.setBranch {
			e.titlerLog("  %s: branch=%q", name, u.branch)
		}
		if title, ok := e.refreshedTitle(name, meta); ok {
			u.task, u.setTask = title, true
			e.titlerLog("  %s: title=%q", name, title)
		}
		if rs, at, ok := e.refreshedReview(name, meta, u); ok {
			u.review, u.reviewAt, u.setReview = rs, at, true
			e.titlerLog("  %s: review=%d files +%d -%d", name, rs.Files, rs.Added, rs.Deleted)
		}
		if !u.empty() {
			updates[name] = u
		}
	}
	e.titlerLog("scan done: %d scanned, %d updated", len(names), len(updates))

	if len(updates) == 0 {
		return
	}

	// Phase 2 (locked): re-read the registry under the write lock shared with
	// bash (lib/registry.sh:_registry_lock) and apply only the refreshed
	// fields — writing back the phase-1 snapshot would clobber concurrent
	// writers.
	lock := lockRegistry(e.AmDir)
	defer unlockRegistry(lock)

	fresh := ReadRegistry(regPath)
	var updated bool
	for name, u := range updates {
		meta, ok := fresh.Sessions[name]
		if !ok {
			continue
		}
		if u.setTask && meta.Task != u.task {
			meta.Task = u.task
			updated = true
		}
		if u.setWorkdir && meta.Workdir != u.workdir {
			meta.Workdir = u.workdir
			updated = true
		}
		if u.setBranch && meta.Branch != u.branch {
			meta.Branch = u.branch
			updated = true
		}
		if u.setReview && (meta.ReviewFiles != u.review.Files || meta.ReviewAdded != u.review.Added ||
			meta.ReviewDeleted != u.review.Deleted || meta.ReviewAt != u.reviewAt) {
			meta.ReviewFiles, meta.ReviewAdded, meta.ReviewDeleted = u.review.Files, u.review.Added, u.review.Deleted
			meta.ReviewAt = u.reviewAt
			updated = true
		}
		fresh.Sessions[name] = meta
	}
	if !updated {
		return
	}
	writeRegistryAtomic(regPath, fresh)
}

// refreshedWorkdir is the workdir/branch half of the title scan. The
// .cwd sidecar (written by the state hook from Claude's tracked tool cwd, or by
// `am cd`) becomes workdir when it names an existing directory other than the
// launch directory. The branch is re-read from whichever directory is in
// effect; a missing directory leaves the branch alone.
func refreshedWorkdir(stateDir, name string, meta Session) (workdir string, setWorkdir bool, branch string, setBranch bool) {
	workdir = meta.Workdir
	if data, err := os.ReadFile(filepath.Join(stateDir, name+".cwd")); err == nil {
		sidecar := strings.SplitN(string(data), "\n", 2)[0]
		if fi, err := os.Stat(sidecar); err == nil && fi.IsDir() {
			workdir = sidecar
			if workdir == meta.Directory {
				workdir = ""
			}
		}
	}
	setWorkdir = workdir != meta.Workdir

	effective := workdir
	if effective == "" {
		effective = meta.Directory
	}
	if effective == "" {
		return
	}
	if fi, err := os.Stat(effective); err != nil || !fi.IsDir() {
		return
	}
	branch = GitHeadBranch(effective)
	setBranch = branch != meta.Branch
	return
}

// refreshedReview is the change-count half of the title scan. It runs git
// (forks) and so is gated: only when the state hook's .dirty sidecar — touched
// on every tool event — is newer than the last measurement, or when the
// branch just changed (the branch checkpoint moves the baseline, so the count
// must follow). Agents without hooks never touch .dirty; their count is
// measured by `am diff` itself. The .dirty mtime, not "now", becomes
// review_at, so a tool event racing the measurement is caught by the next
// scan instead of being lost.
func (e Env) refreshedReview(name string, meta Session, u metaUpdate) (ReviewStat, int64, bool) {
	dir := meta.Directory
	if u.setWorkdir {
		if u.workdir != "" {
			dir = u.workdir
		}
	} else if meta.Workdir != "" {
		dir = meta.Workdir
	}
	if dir == "" {
		return ReviewStat{}, 0, false
	}
	var dirtyAt int64
	if fi, err := os.Stat(filepath.Join(e.StateDir, name+".dirty")); err == nil {
		dirtyAt = fi.ModTime().Unix()
	}
	branchChanged := u.setBranch && meta.Branch != u.branch
	if !branchChanged && (dirtyAt == 0 || dirtyAt <= meta.ReviewAt) {
		return ReviewStat{}, 0, false
	}
	at := dirtyAt
	if at == 0 || branchChanged {
		at = time.Now().Unix()
	}
	_, rs, _, err := e.ReviewMeasure(name, dir, "", false)
	if err != nil {
		if !ErrNoRepo(err) {
			e.titlerLog("  %s: review: %v", name, err)
		}
		return ReviewStat{}, 0, false
	}
	return rs, at, true
}

// refreshedTitle returns the session's current title when it is valid and
// differs from the registry task: the agent's pane title, else (Claude / pi /
// Cursor) the first user message of this session's transcript.
func (e Env) refreshedTitle(name string, meta Session) (string, bool) {
	spec := agentSpec(meta.AgentType)
	title := readPaneTitle(e.Socket, name+":.{top}")
	title = leadingNonAlnum.ReplaceAllString(title, "")
	switch spec.Title {
	case "pi":
		title = piTitleExtract(title)
	case "cursor":
		title = cursorTitleExtract(title)
	default:
		dir := meta.Workdir
		if dir == "" {
			dir = meta.Directory
		}
		title = normalizeTitle(title, dir)
	}
	if !titleValid(title) {
		// Hysteresis: a title the session already
		// has is kept until the pane paints a new valid one, so transient
		// placeholders never swap it for the first-message fallback.
		if meta.Task != "" {
			return "", false
		}
		if spec.HasStore() && meta.Directory != "" {
			// THIS session's conversation id comes from the sidecar its own
			// hook wrote; the readers open exactly that transcript. With no
			// id there is no fallback: the directory's transcript store is
			// shared with other sessions and with agents outside am.
			transcript := ""
			if spec.Store == "cursor" {
				transcript = e.SidecarTranscript(name)
			}
			sid := e.DetectID(name, meta.Directory, meta.AgentType)
			fallback := FirstMessage(meta.AgentType, meta.Directory, sid, transcript)
			if len(fallback) > titleMaxLen {
				fallback = fallback[:titleMaxLen]
			}
			if titleValid(fallback) {
				title = fallback
				e.titlerLog("  %s: jsonl fallback=%q", name, title)
			} else {
				return "", false
			}
		} else {
			return "", false
		}
	}

	if title == meta.Task {
		return "", false
	}
	return title, true
}

func readScanMarker(path string) (time.Time, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return time.Time{}, false
	}
	ts, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	if err != nil {
		return time.Time{}, false
	}
	return time.Unix(ts, 0), true
}

func readPaneTitle(socket, target string) string {
	cmd := exec.Command("tmux", "-L", socket, "display-message", "-p", "-t", target, "#{pane_title}")
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimRight(string(out), "\n")
}

// normalizeTitle strips the
// transient decorations Claude Code appends to its terminal title: a trailing
// " - 🔄 Reconnecting…" segment and a trailing " - <dirname>" that repeats the
// directory the tab already shows.
func normalizeTitle(t, dir string) string {
	if i := strings.Index(t, " - 🔄"); i >= 0 {
		t = t[:i]
	}
	if base := filepath.Base(dir); dir != "" && base != "" && base != "." {
		t = strings.TrimSuffix(t, " - "+base)
	}
	return strings.TrimRight(t, " \t")
}

// titleValid accepts a pane title as a task name. The bare "Claude Code" is
// the placeholder Claude paints until a conversation has a summary, not a
// title; rejecting it lets the JSONL first-message fallback name the tab.
func titleValid(t string) bool {
	if t == "" || t == "Claude Code" || len(t) > titleMaxLen {
		return false
	}
	return !strings.ContainsRune(t, '\n')
}

func writeRegistryAtomic(path string, reg Registry) {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".sessions.*.json.tmp")
	if err != nil {
		return
	}
	tmpName := tmp.Name()
	enc := json.NewEncoder(tmp)
	enc.SetIndent("", "  ")
	if err := enc.Encode(reg); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return
	}
	_ = os.Rename(tmpName, path)
}

// claudeFirstUserMessage backs the bash claude_first_user_message wrapper.
// Returns the first user-message text (>10 chars) from exactly the Claude
// JSONL bound to this session (the id the pane's own hook reported), with
// tags stripped and whitespace collapsed. The directory only locates the
// per-project transcript store; it never chooses among transcripts, because
// the store is shared with other am sessions and with agents started outside
// am. No id → "".
func claudeFirstUserMessage(directory, sessionID string) string {
	if sessionID == "" {
		return ""
	}
	projectPath := strings.ReplaceAll(directory, "/", "-")
	projectPath = strings.ReplaceAll(projectPath, ".", "-")
	target := filepath.Join(homeDir(), ".claude", "projects", projectPath, sessionID+".jsonl")
	if st, err := os.Stat(target); err != nil || st.IsDir() {
		return ""
	}

	f, err := os.Open(target)
	if err != nil {
		return ""
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	count := 0
	for scanner.Scan() && count < 10 {
		line := scanner.Bytes()
		if !strings.Contains(string(line), `"type":"user"`) {
			continue
		}
		count++
		var rec struct {
			Message struct {
				Content json.RawMessage `json:"content"`
			} `json:"message"`
		}
		if err := json.Unmarshal(line, &rec); err != nil {
			continue
		}
		text := extractContent(rec.Message.Content)
		text = cleanContent(text)
		if titleWorthy(text) {
			return text
		}
	}
	return ""
}

// cursorTitleExtract drops Cursor's empirically observed transient status
// titles. Task titles pass through; exact task fallback comes from transcript.
func cursorTitleExtract(title string) string {
	if strings.HasSuffix(title, " - ✅ Ready") {
		title = strings.TrimSuffix(title, " - ✅ Ready")
	} else if idx := strings.LastIndex(title, " - ⏳ Working"); idx >= 0 {
		title = title[:idx]
	} else if strings.HasSuffix(title, " - ❓ Waiting for you") {
		title = strings.TrimSuffix(title, " - ❓ Waiting for you")
	}
	switch title {
	case "Cursor Agent", "Shell Command":
		return ""
	default:
		return title
	}
}

var cursorUserQueryRe = regexp.MustCompile(`(?s)<user_query>\s*(.*?)\s*</user_query>`)

// cursorFirstUserMessage reads the hook-bound transcript when available, else
// Cursor's standard per-project layout addressed by sessionID. Neither → "":
// the per-project store is shared with conversations that are not this
// session.
func cursorFirstUserMessage(directory, sessionID, transcriptPath string) string {
	target := ""
	if transcriptPath != "" {
		if st, err := os.Stat(transcriptPath); err == nil && !st.IsDir() {
			target = transcriptPath
		}
	}
	if target == "" && sessionID != "" {
		candidate := cursorStandardTranscriptPath(homeDir(), directory, sessionID)
		if st, err := os.Stat(candidate); err == nil && !st.IsDir() {
			target = candidate
		}
	}
	if target == "" {
		return ""
	}

	f, err := os.Open(target)
	if err != nil {
		return ""
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		var rec struct {
			Role    string `json:"role"`
			Message struct {
				Content json.RawMessage `json:"content"`
			} `json:"message"`
		}
		if err := json.Unmarshal(scanner.Bytes(), &rec); err != nil || rec.Role != "user" {
			continue
		}
		text := extractContent(rec.Message.Content)
		if match := cursorUserQueryRe.FindStringSubmatch(text); len(match) == 2 {
			text = match[1]
		}
		text = cleanContent(strings.ReplaceAll(text, "\n", " "))
		if titleWorthy(text) {
			return text
		}
	}
	return ""
}

func extractContent(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s
	}
	var arr []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if err := json.Unmarshal(raw, &arr); err == nil {
		var parts []string
		for _, p := range arr {
			if p.Type == "text" && p.Text != "" {
				parts = append(parts, p.Text)
			}
		}
		return strings.Join(parts, " ")
	}
	return ""
}

var tagRe = regexp.MustCompile(`<[^>]*>[^<]*</[^>]*>|<[^>]*>`)

func cleanContent(s string) string {
	s = tagRe.ReplaceAllString(s, "")
	s = strings.ReplaceAll(s, "\n", " ")
	return strings.TrimSpace(s)
}

// titleWorthy is the first-message length gate shared by the Claude, Cursor,
// and pi transcript readers. It counts characters, not bytes (the contract
// the bash readers had: `${#cleaned} -gt 10`), so a short non-ASCII message
// is rejected the same way regardless of its encoding.
func titleWorthy(text string) bool {
	return utf8.RuneCountInString(text) > 10
}

func homeDir() string {
	if h := os.Getenv("HOME"); h != "" {
		return h
	}
	h, _ := os.UserHomeDir()
	return h
}

// validSessionID is the conversation-id character set (bash
// _sessions_log_valid_id).
var validSessionID = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

// piTitleExtract pulls a task candidate out of pi's self-maintained title.
// "pi - <name> - <base>" -> "<name>" (name may contain " - "; only the
// first and last segments are stripped). "pi - <base>" or "pi" -> "" so the
// caller falls back to the JSONL first message. Anything else passes through.
func piTitleExtract(title string) string {
	if title == "pi" {
		return ""
	}
	rest, ok := strings.CutPrefix(title, "pi - ")
	if !ok {
		return title
	}
	idx := strings.LastIndex(rest, " - ")
	if idx < 0 {
		return ""
	}
	return rest[:idx]
}

// piFirstUserMessage backs the bash pi_first_user_message wrapper: exactly the
// bound transcript, no id → "".
func piFirstUserMessage(directory, sessionID string) string {
	if sessionID == "" {
		return ""
	}
	piDir := filepath.Join(piSessionsRoot(homeDir()), encodedPiSessionDir(directory))
	matches, _ := filepath.Glob(filepath.Join(piDir, "*_"+sessionID+".jsonl"))
	if len(matches) == 0 {
		return ""
	}
	target := matches[0]

	f, err := os.Open(target)
	if err != nil {
		return ""
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	count := 0
	for scanner.Scan() && count < 10 {
		line := scanner.Bytes()
		if !strings.Contains(string(line), `"role":"user"`) {
			continue
		}
		count++
		var rec struct {
			Type    string `json:"type"`
			Message struct {
				Role    string          `json:"role"`
				Content json.RawMessage `json:"content"`
			} `json:"message"`
		}
		if err := json.Unmarshal(line, &rec); err != nil {
			continue
		}
		if rec.Type != "message" || rec.Message.Role != "user" {
			continue
		}
		text := cleanContent(extractContent(rec.Message.Content))
		if titleWorthy(text) {
			return text
		}
	}
	return ""
}
