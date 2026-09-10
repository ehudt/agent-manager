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

// A rebase onto a newer upstream must not turn the upstream's commits into
// the agent's work: the baseline is re-anchored below the agent's rewritten
// commits, and work that was uncommitted at launch is carried over.
func TestReviewSyncRebase(t *testing.T) {
	dir := gitRepo(t)
	git(t, dir, "checkout", "-q", "-b", "feature")
	writeFile(t, filepath.Join(dir, "scratch.txt"), "dirty at launch\n") // uncommitted, stays so
	if _, _, err := ReviewInit(dir, "am-rb"); err != nil {
		t.Fatal(err)
	}
	// The agent commits on feature.
	writeFile(t, filepath.Join(dir, "feat.txt"), "f1\n")
	git(t, dir, "add", "feat.txt")
	git(t, dir, "commit", "-q", "-m", "agent work")
	if kind, _, err := ReviewSync(dir, "am-rb"); err != nil || kind != "head" {
		t.Fatalf("sync after commit: kind=%q err=%v", kind, err)
	}
	// Upstream moves on: two commits on main touching other files.
	git(t, dir, "checkout", "-q", "main")
	writeFile(t, filepath.Join(dir, "up1.txt"), "u1\n")
	git(t, dir, "add", "up1.txt")
	git(t, dir, "commit", "-q", "-m", "upstream 1")
	writeFile(t, filepath.Join(dir, "up2.txt"), "u2\n")
	git(t, dir, "add", "up2.txt")
	git(t, dir, "commit", "-q", "-m", "upstream 2")
	mainSHA := git(t, dir, "rev-parse", "HEAD")
	git(t, dir, "checkout", "-q", "feature")
	git(t, dir, "rebase", "-q", "main")

	kind, cp, err := ReviewSync(dir, "am-rb")
	if err != nil || kind != "rebase" {
		t.Fatalf("sync after rebase: kind=%q err=%v", kind, err)
	}
	if cp.Anchor != mainSHA {
		t.Fatalf("rebase checkpoint anchored on %s, want the new upstream tip %s", cp.Anchor, mainSHA)
	}
	if cp.Head == mainSHA || cp.Head == "" {
		t.Fatalf("rebase checkpoint head should be the rebased HEAD, got %q", cp.Head)
	}
	st, _ := ReviewRead(dir, "am-rb")
	if st.BaselineID() != cp.ID {
		t.Fatalf("rebase checkpoint did not move the baseline")
	}
	base, _ := st.Baseline()
	rs, err := ReviewDiffStat(dir, base.Tree)
	if err != nil {
		t.Fatal(err)
	}
	if rs.Files != 1 || rs.Added != 1 {
		files, _ := ReviewFileStats(dir, base.Tree, rs.CurTree)
		t.Fatalf("diff since the rebase baseline should be the agent's one file, got %+v: %+v", rs, files)
	}
	if moved := HeadMoved(dir, base); moved != "1 commit" {
		t.Fatalf("HeadMoved since the rebase anchor: %q", moved)
	}
	// Launch was at the branch point, which the rebase kept: HEAD is simply
	// ahead of it (two upstream, one own).
	launch := st.Checkpoints[len(st.Checkpoints)-1]
	if moved := HeadMoved(dir, launch); moved != "3 commits" {
		t.Fatalf("HeadMoved since launch: %q", moved)
	}
	if kind, _, _ := ReviewSync(dir, "am-rb"); kind != "" {
		t.Fatalf("second sync recorded %q", kind)
	}

	// A second rebase (upstream moved again) anchors on the agent's rewritten
	// commit again, so the earlier work stays in the diff.
	git(t, dir, "checkout", "-q", "main")
	writeFile(t, filepath.Join(dir, "up3.txt"), "u3\n")
	git(t, dir, "add", "up3.txt")
	git(t, dir, "commit", "-q", "-m", "upstream 3")
	main2 := git(t, dir, "rev-parse", "HEAD")
	git(t, dir, "checkout", "-q", "feature")
	git(t, dir, "rebase", "-q", "main")
	kind, cp, err = ReviewSync(dir, "am-rb")
	if err != nil || kind != "rebase" || cp.Anchor != main2 {
		t.Fatalf("second rebase: kind=%q anchor=%s want %s err=%v", kind, cp.Anchor, main2, err)
	}
	if rs, _ := ReviewDiffStat(dir, cp.Tree); rs.Files != 1 {
		t.Fatalf("after the second rebase: %+v", rs)
	}
}

// With no commits of its own, a rebase leaves nothing to show: the baseline
// becomes the rebased HEAD's tree.
func TestReviewSyncRebaseNoOwnCommits(t *testing.T) {
	dir := gitRepo(t)
	git(t, dir, "checkout", "-q", "-b", "feature")
	writeFile(t, filepath.Join(dir, "feat.txt"), "f1\n")
	git(t, dir, "add", "-A")
	git(t, dir, "commit", "-q", "-m", "pre-existing branch commit")
	if _, _, err := ReviewInit(dir, "am-rb2"); err != nil {
		t.Fatal(err)
	}
	git(t, dir, "checkout", "-q", "main")
	writeFile(t, filepath.Join(dir, "up.txt"), "u\n")
	git(t, dir, "add", "-A")
	git(t, dir, "commit", "-q", "-m", "upstream")
	git(t, dir, "checkout", "-q", "feature")
	git(t, dir, "rebase", "-q", "main")
	head := git(t, dir, "rev-parse", "HEAD")
	kind, cp, err := ReviewSync(dir, "am-rb2")
	if err != nil || kind != "rebase" || cp.Anchor != head {
		t.Fatalf("kind=%q anchor=%s want %s err=%v", kind, cp.Anchor, head, err)
	}
	if rs, _ := ReviewDiffStat(dir, cp.Tree); rs.Files != 0 {
		t.Fatalf("nothing of the agent's own, yet %+v", rs)
	}
	// The launch commit itself was rewritten: HEAD did not move forward from it.
	st, _ := ReviewRead(dir, "am-rb2")
	if moved := HeadMoved(dir, st.Checkpoints[len(st.Checkpoints)-1]); moved != "rebased or reset" {
		t.Fatalf("HeadMoved since the rewritten launch: %q", moved)
	}
}

// A chain recorded before rebase checkpoints existed (a head checkpoint after
// the rebase, baseline still at launch) gets the re-anchored base offered as
// a virtual row; a chain that already has a rebase checkpoint does not.
func TestReviewRebaseSuggestion(t *testing.T) {
	dir := gitRepo(t)
	git(t, dir, "checkout", "-q", "-b", "feature")
	if _, _, err := ReviewInit(dir, "am-old"); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(dir, "feat.txt"), "f1\n")
	git(t, dir, "add", "-A")
	git(t, dir, "commit", "-q", "-m", "agent work")
	if kind, _, _ := ReviewSync(dir, "am-old"); kind != "head" {
		t.Fatalf("kind %q", kind)
	}
	git(t, dir, "checkout", "-q", "main")
	writeFile(t, filepath.Join(dir, "up.txt"), "u\n")
	git(t, dir, "add", "-A")
	git(t, dir, "commit", "-q", "-m", "upstream")
	mainSHA := git(t, dir, "rev-parse", "HEAD")
	git(t, dir, "checkout", "-q", "feature")
	git(t, dir, "rebase", "-q", "main")
	// What a pre-0.33 sync recorded: a head checkpoint of the rebased HEAD.
	tree, _ := headTree(dir)
	if _, err := reviewAdd(dir, "am-old", "head", tree, false); err != nil {
		t.Fatal(err)
	}
	if kind, _, _ := ReviewSync(dir, "am-old"); kind != "" {
		t.Fatalf("sync on a chain already at HEAD recorded %q", kind)
	}
	st, _ := ReviewRead(dir, "am-old")
	sug, ok := ReviewRebaseSuggestion(dir, st)
	if !ok || sug.Kind != "rebase" || sug.ID != mainSHA || sug.Anchor != mainSHA {
		t.Fatalf("suggestion: ok=%v %+v want anchor %s", ok, sug, mainSHA)
	}
	if rs, _ := ReviewDiffStat(dir, sug.Tree); rs.Files != 1 {
		t.Fatalf("since the suggested base: %+v", rs)
	}
	// Making it the baseline records a pick; the suggestion then disappears
	// (its tree is in the chain).
	if _, err := ReviewSetBaseline(dir, "am-old", sug.ID); err != nil {
		t.Fatal(err)
	}
	st, _ = ReviewRead(dir, "am-old")
	if _, ok := ReviewRebaseSuggestion(dir, st); ok {
		t.Fatalf("suggestion repeated after it was picked")
	}

	// A chain whose rewrite was re-anchored by ReviewSync offers nothing.
	dir2 := gitRepo(t)
	git(t, dir2, "checkout", "-q", "-b", "feature")
	if _, _, err := ReviewInit(dir2, "am-new"); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(dir2, "feat.txt"), "f1\n")
	git(t, dir2, "add", "-A")
	git(t, dir2, "commit", "-q", "-m", "agent work")
	ReviewSync(dir2, "am-new")
	git(t, dir2, "checkout", "-q", "main")
	writeFile(t, filepath.Join(dir2, "up.txt"), "u\n")
	git(t, dir2, "add", "-A")
	git(t, dir2, "commit", "-q", "-m", "upstream")
	git(t, dir2, "checkout", "-q", "feature")
	git(t, dir2, "rebase", "-q", "main")
	if kind, _, _ := ReviewSync(dir2, "am-new"); kind != "rebase" {
		t.Fatalf("kind %q", kind)
	}
	st2, _ := ReviewRead(dir2, "am-new")
	if _, ok := ReviewRebaseSuggestion(dir2, st2); ok {
		t.Fatalf("suggestion on a chain with a rebase checkpoint")
	}
}

// Any commit of the repository can serve as a one-off base, and `b` on it
// records a pick checkpoint anchored on that commit.
func TestReviewCommitBase(t *testing.T) {
	dir := gitRepo(t)
	first := git(t, dir, "rev-parse", "HEAD")
	writeFile(t, filepath.Join(dir, "b.txt"), "b\n")
	git(t, dir, "add", "-A")
	git(t, dir, "commit", "-q", "-m", "second")
	env := Env{AmDir: t.TempDir()}
	if _, _, err := ReviewInit(dir, "am-pick"); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(dir, "c.txt"), "c\n")
	cp, rs, moved, err := env.ReviewMeasure("am-pick", dir, first[:10], false)
	if err != nil {
		t.Fatal(err)
	}
	if cp.Kind != "commit" || cp.ID != first || rs.Files != 2 || moved != "1 commit" {
		t.Fatalf("measure since a commit: cp=%+v rs=%+v moved=%q", cp, rs, moved)
	}
	if _, _, _, err := env.ReviewMeasure("am-pick", dir, "nonexistent-ref", false); err == nil {
		t.Fatalf("unknown id accepted")
	}
	pick, err := ReviewSetBaseline(dir, "am-pick", first[:10])
	if err != nil {
		t.Fatal(err)
	}
	if pick.Kind != "pick" || pick.Anchor != first || pick.Head == first {
		t.Fatalf("pick checkpoint: %+v", pick)
	}
	if moved := HeadMoved(dir, pick); moved != "1 commit" {
		t.Fatalf("HeadMoved since the pick anchor: %q", moved)
	}
	st, _ := ReviewRead(dir, "am-pick")
	if st.BaselineID() != pick.ID || st.Checkpoints[0].ID != pick.ID {
		t.Fatalf("pick did not become the baseline: %+v", st)
	}
	if rs, _ := ReviewDiffStat(dir, pick.Tree); rs.Files != 2 {
		t.Fatalf("since the pick: %+v", rs)
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
