package sessions

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// gitRepo creates a real repository with one commit on main and returns its
// path. Skips when git is not installed.
func gitRepo(t *testing.T) string {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not installed")
	}
	dir := t.TempDir()
	git(t, dir, "init", "-q", "-b", "main")
	git(t, dir, "config", "user.email", "t@example.com")
	git(t, dir, "config", "user.name", "t")
	writeFile(t, filepath.Join(dir, "a.txt"), "one\n")
	git(t, dir, "add", "-A")
	git(t, dir, "commit", "-q", "-m", "init")
	return dir
}

func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	out, err := gitOut(dir, nil, "", args...)
	if err != nil {
		t.Fatalf("git %v: %v", args, err)
	}
	return out
}

// A same-size edit in the second after the commit must still be seen: the
// temp index keeps the real index's mtime so git's racy-clean re-hash applies.
func TestWorktreeTreeRacyEdit(t *testing.T) {
	dir := gitRepo(t)
	head := git(t, dir, "rev-parse", "HEAD^{tree}")
	// Pin the index and the file to the same second, file not older.
	now := time.Now()
	idx := filepath.Join(dir, ".git", "index")
	writeFile(t, filepath.Join(dir, "a.txt"), "two\n") // same size as "one\n"
	if err := os.Chtimes(idx, now, now); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(filepath.Join(dir, "a.txt"), now, now); err != nil {
		t.Fatal(err)
	}
	tree, err := WorktreeTree(dir)
	if err != nil {
		t.Fatal(err)
	}
	if tree == head {
		t.Fatalf("worktree tree equals HEAD tree: same-size racy edit missed")
	}
}

func TestReviewLaunchAckAndStat(t *testing.T) {
	dir := gitRepo(t)
	cp, created, err := ReviewInit(dir, "am-rev1")
	if err != nil || !created || cp.Kind != "launch" || cp.Branch != "main" {
		t.Fatalf("ReviewInit: cp=%+v created=%v err=%v", cp, created, err)
	}
	if _, created, _ = ReviewInit(dir, "am-rev1"); created {
		t.Fatalf("second ReviewInit created another launch checkpoint")
	}

	// Nothing changed yet: empty stat.
	st, _ := ReviewRead(dir, "am-rev1")
	base, _ := st.Baseline()
	rs, err := ReviewDiffStat(dir, base.Tree)
	if err != nil || rs.Files != 0 {
		t.Fatalf("clean stat: %+v err=%v", rs, err)
	}

	// Agent edits a tracked file and adds an untracked one (no commit).
	writeFile(t, filepath.Join(dir, "a.txt"), "one\ntwo\n")
	writeFile(t, filepath.Join(dir, "new.txt"), "x\ny\nz\n")
	rs, err = ReviewDiffStat(dir, base.Tree)
	if err != nil || rs.Files != 2 || rs.Added != 4 || rs.Deleted != 0 {
		t.Fatalf("dirty stat: %+v err=%v", rs, err)
	}
	// The real index is untouched by the snapshot.
	if status := git(t, dir, "status", "--porcelain"); status != " M a.txt\n?? new.txt" {
		t.Fatalf("snapshot touched the index: %q", status)
	}

	// Ack: baseline moves, stat returns to zero, chain has two entries.
	ack, err := ReviewAck(dir, "am-rev1")
	if err != nil || ack.Kind != "ack" {
		t.Fatalf("ReviewAck: %+v err=%v", ack, err)
	}
	st, _ = ReviewRead(dir, "am-rev1")
	if len(st.Checkpoints) != 2 || st.Checkpoints[0].ID != ack.ID || st.BaselineID() != ack.ID {
		t.Fatalf("after ack: %+v", st)
	}
	rs, _ = ReviewDiffStat(dir, ack.Tree)
	if rs.Files != 0 {
		t.Fatalf("stat after ack: %+v", rs)
	}

	// Reset goes back to the launch tree: both edits show again.
	launch, err := ReviewResetBaseline(dir, "am-rev1")
	if err != nil || launch.ID != cp.ID {
		t.Fatalf("reset: %+v err=%v", launch, err)
	}
	st, _ = ReviewRead(dir, "am-rev1")
	if st.BaselineID() != cp.ID {
		t.Fatalf("baseline after reset: %s want %s", st.BaselineID(), cp.ID)
	}
	if _, err := ReviewSetBaseline(dir, "am-rev1", ack.ID[:7]); err != nil {
		t.Fatalf("set baseline by short id: %v", err)
	}
	if _, err := ReviewSetBaseline(dir, "am-rev1", "deadbeef"); err == nil {
		t.Fatalf("set baseline to an unknown id succeeded")
	}
}

func TestReviewSyncBranchAndHead(t *testing.T) {
	dir := gitRepo(t)
	if _, _, err := ReviewInit(dir, "am-rev2"); err != nil {
		t.Fatal(err)
	}
	// Uncommitted work on main before the switch.
	writeFile(t, filepath.Join(dir, "a.txt"), "one\nedited\n")

	// Same HEAD: nothing to record.
	if kind, _, err := ReviewSync(dir, "am-rev2"); err != nil || kind != "" {
		t.Fatalf("sync on unchanged HEAD: kind=%q err=%v", kind, err)
	}

	// The agent commits on main: head checkpoint, baseline stays at launch.
	git(t, dir, "add", "-A")
	git(t, dir, "commit", "-q", "-m", "work")
	kind, headCP, err := ReviewSync(dir, "am-rev2")
	if err != nil || kind != "head" {
		t.Fatalf("sync after commit: kind=%q err=%v", kind, err)
	}
	st, _ := ReviewRead(dir, "am-rev2")
	launch := st.Checkpoints[len(st.Checkpoints)-1]
	if st.BaselineID() != launch.ID {
		t.Fatalf("head checkpoint moved the baseline")
	}
	base, _ := st.Baseline()
	if rs, _ := ReviewDiffStat(dir, base.Tree); rs.Files != 1 {
		t.Fatalf("committed work vanished from the diff: %+v", rs)
	}
	if moved := HeadMoved(dir, launch); moved != "1 commit" {
		t.Fatalf("HeadMoved: %q", moved)
	}
	if moved := HeadMoved(dir, headCP); moved != "" {
		t.Fatalf("HeadMoved at current head: %q", moved)
	}

	// Pull a feature branch with its own history, then edit on it: the branch
	// checkpoint is the committed tree, so only the new edit is unreviewed.
	git(t, dir, "checkout", "-q", "-b", "feature-x")
	writeFile(t, filepath.Join(dir, "feat.txt"), "f1\nf2\n")
	git(t, dir, "add", "-A")
	git(t, dir, "commit", "-q", "-m", "feature commit")
	writeFile(t, filepath.Join(dir, "feat.txt"), "f1\nf2\nf3\n") // agent's edit after the switch
	kind, br, err := ReviewSync(dir, "am-rev2")
	if err != nil || kind != "branch" || br.Branch != "feature-x" {
		t.Fatalf("sync after branch switch: kind=%q cp=%+v err=%v", kind, br, err)
	}
	st, _ = ReviewRead(dir, "am-rev2")
	if st.BaselineID() != br.ID {
		t.Fatalf("branch checkpoint did not move the baseline")
	}
	rs, _ := ReviewDiffStat(dir, br.Tree)
	if rs.Files != 1 || rs.Added != 1 || rs.Deleted != 0 {
		t.Fatalf("post-switch stat should be the one edit: %+v", rs)
	}
	// Sync is idempotent.
	if kind, _, _ := ReviewSync(dir, "am-rev2"); kind != "" {
		t.Fatalf("second sync recorded %q", kind)
	}
	// Listing: newest first, four entries.
	kinds := []string{}
	for _, cp := range st.Checkpoints {
		kinds = append(kinds, cp.Kind)
	}
	if len(kinds) != 3 || kinds[0] != "branch" || kinds[1] != "head" || kinds[2] != "launch" {
		t.Fatalf("chain kinds: %v", kinds)
	}
}

func TestReviewAdoptAndDrop(t *testing.T) {
	dir := gitRepo(t)
	if _, _, err := ReviewInit(dir, "am-old"); err != nil {
		t.Fatal(err)
	}
	if _, err := ReviewAck(dir, "am-old"); err != nil {
		t.Fatal(err)
	}
	// The restored session got its own launch checkpoint before adoption.
	if _, _, err := ReviewInit(dir, "am-new"); err != nil {
		t.Fatal(err)
	}
	if err := ReviewAdopt(dir, "am-old", "am-new"); err != nil {
		t.Fatal(err)
	}
	old, _ := ReviewRead(dir, "am-old")
	if len(old.Checkpoints) != 0 {
		t.Fatalf("old refs survived adoption")
	}
	st, _ := ReviewRead(dir, "am-new")
	if len(st.Checkpoints) != 2 || st.Checkpoints[0].Kind != "ack" || st.BaselineID() != st.Checkpoints[0].ID {
		t.Fatalf("adopted chain: %+v", st)
	}
	ReviewDrop(dir, "am-new")
	st, _ = ReviewRead(dir, "am-new")
	if len(st.Checkpoints) != 0 || st.BaselineRef != "" {
		t.Fatalf("drop left refs: %+v", st)
	}
}

func TestReviewNonRepo(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not installed")
	}
	dir := t.TempDir()
	_, _, err := ReviewInit(dir, "am-none")
	if !ErrNoRepo(err) {
		t.Fatalf("ReviewInit outside a repo: %v", err)
	}
	if _, err := ReviewRead(filepath.Join(dir, "missing"), "am-none"); !ErrNoRepo(err) {
		t.Fatalf("ReviewRead on a missing dir: %v", err)
	}
}

func TestRefreshTitlesReviewCount(t *testing.T) {
	dir := gitRepo(t)
	amDir := t.TempDir()
	stateDir := t.TempDir()
	regPath := filepath.Join(amDir, "sessions.json")
	binDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(binDir, "tmux"), []byte("#!/bin/sh\nprintf '\\n'\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("HOME", t.TempDir())
	t.Setenv("AM_STATE_DIR", stateDir)

	if _, _, err := ReviewInit(dir, "am-cnt"); err != nil {
		t.Fatal(err)
	}
	writeRegistryAtomic(regPath, Registry{Sessions: map[string]Session{
		"am-cnt": {Name: "am-cnt", Directory: dir, Branch: "main", AgentType: "claude"},
	}})
	refresh := func() Session {
		os.Remove(filepath.Join(amDir, ".title_scan_last"))
		RefreshTitles(testEnv(t, amDir), false)
		return ReadRegistry(regPath).Sessions["am-cnt"]
	}

	// No .dirty sidecar: the scan never runs git for this row.
	writeFile(t, filepath.Join(dir, "a.txt"), "one\ntwo\nthree\n")
	if got := refresh(); got.ReviewFiles != 0 || got.ReviewAt != 0 {
		t.Fatalf("count measured without a dirty marker: %+v", got)
	}

	// The hook touches .dirty after a tool call: measured on the next scan.
	dirty := filepath.Join(stateDir, "am-cnt.dirty")
	writeFile(t, dirty, "")
	got := refresh()
	if got.ReviewFiles != 1 || got.ReviewAdded != 2 || got.ReviewDeleted != 0 || got.ReviewAt == 0 {
		t.Fatalf("count after dirty marker: %+v", got)
	}

	// Same marker mtime: no re-measure, no rewrite.
	writeFile(t, filepath.Join(dir, "a.txt"), "one\ntwo\nthree\nfour\n")
	before, _ := os.Stat(regPath)
	got = refresh()
	after, _ := os.Stat(regPath)
	if got.ReviewAdded != 2 || !before.ModTime().Equal(after.ModTime()) {
		t.Fatalf("stale marker re-measured: %+v", got)
	}

	// Marker moves forward: re-measured.
	future := time.Now().Add(2 * time.Second)
	if err := os.Chtimes(dirty, future, future); err != nil {
		t.Fatal(err)
	}
	if got = refresh(); got.ReviewAdded != 3 {
		t.Fatalf("count after marker moved: %+v", got)
	}

	// Ack through the Env path zeroes the row.
	if _, err := ReviewAck(dir, "am-cnt"); err != nil {
		t.Fatal(err)
	}
	testEnv(t, amDir).ReviewRecord("am-cnt", ReviewStat{}, time.Now())
	if got = ReadRegistry(regPath).Sessions["am-cnt"]; got.ReviewFiles != 0 || got.ReviewAdded != 0 {
		t.Fatalf("ack did not zero the row: %+v", got)
	}
}
