package sessions

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Review checkpoints back `am diff`: per session, the trees the user has
// already looked at, kept in the session's own repository so they survive
// kill and restore with no am-side state.
//
// Each checkpoint is a commit object made with commit-tree (no parent into
// the real history): its tree is the snapshot, its message carries the
// metadata (kind, branch, HEAD sha, time), and its parent is the previous
// checkpoint, so one ref per session, refs/am/<session>/checkpoints, holds
// the whole list and `git log` on it is the listing. A second ref,
// refs/am/<session>/baseline, names the checkpoint `am diff` compares the
// working copy against. Kinds:
//
//	launch  worktree tree at launch; the baseline starts here
//	ack     worktree tree at `am diff --ack`; the baseline moves here
//	branch  HEAD's committed tree when the branch name changed; baseline moves
//	head    HEAD's committed tree when HEAD moved on the same branch; no move
//	rebase  the baseline re-anchored after the branch's history was rewritten
//	        (rebase / reset: the previous checkpoint's HEAD is no longer an
//	        ancestor of HEAD); its anchor is the commit the new baseline sits
//	        on; moves
//	pick    the committed tree of a commit the user named (`am diff --checkpoint`
//	        / the review pane's `/` prompt, then `b`); its anchor is that
//	        commit; moves
//
// A branch checkpoint records the committed tree, not the worktree, so it
// does not matter when the change is noticed (the hook's next PostToolUse or
// the 60s title scan): "feature-x as checked out" is the same tree either
// way, and `am diff` then shows only the agent's work on the new branch.
//
// A rebase checkpoint keeps "what did the agent do" true across a rebase onto
// a newer upstream: without it the launch snapshot would sit on the old base
// and every upstream commit the rebase pulled in would show as the agent's
// work (observed: 579 files after a rebase whose own work was 16). The
// re-anchoring finds the agent's pre-rebase commits again by patch-id in the
// rewritten history and puts the baseline just below the earliest of them.
type Checkpoint struct {
	ID     string // commit sha
	Kind   string // launch | ack | branch | head | rebase | pick | commit (virtual, not in the chain)
	Tree   string // snapshot tree sha
	Branch string // branch name at record time ("" when detached / unborn)
	Head   string // HEAD sha at record time ("" when unborn)
	Anchor string // rebase / pick / commit: the commit the tree sits on (else "")
	Time   int64  // unix seconds
}

// AnchorCommit is the commit the checkpoint's tree is based on: the anchor
// for rebase / pick / commit checkpoints, HEAD at record time otherwise. It
// is what HeadMoved and rebase re-anchoring measure from.
func (cp Checkpoint) AnchorCommit() string {
	if cp.Anchor != "" {
		return cp.Anchor
	}
	return cp.Head
}

// ReviewState is one session's checkpoint chain, newest first, plus the
// baseline checkpoint id (empty when the baseline ref is missing; callers
// fall back to the oldest checkpoint, the launch).
type ReviewState struct {
	Checkpoints []Checkpoint
	BaselineRef string
}

// ReviewStat is the size of the unreviewed change: base tree → worktree.
type ReviewStat struct {
	Files, Added, Deleted int
	BaseTree, CurTree     string
}

var errNoRepo = errors.New("not a git repository")

// ErrNoRepo reports whether err means dir is not inside a git repository.
func ErrNoRepo(err error) bool { return errors.Is(err, errNoRepo) }

func reviewRefs(session string) (checkpoints, baseline string) {
	return "refs/am/" + session + "/checkpoints", "refs/am/" + session + "/baseline"
}

// gitOut runs git in dir and returns trimmed stdout. Errors carry git's
// stderr.
func gitOut(dir string, extraEnv []string, stdin string, args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = append(os.Environ(), extraEnv...)
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(errb.String())
		if strings.Contains(msg, "not a git repository") {
			return "", errNoRepo
		}
		return "", fmt.Errorf("git %s: %w: %s", args[0], err, msg)
	}
	return strings.TrimRight(out.String(), "\n"), nil
}

// gitRoot is the worktree top level of dir, or errNoRepo.
func gitRoot(dir string) (string, error) {
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		return "", errNoRepo
	}
	return gitOut(dir, nil, "", "rev-parse", "--show-toplevel")
}

// WorktreeTree snapshots the working copy of dir's repository as a tree
// object — tracked, modified, and untracked files (ignored ones excluded) —
// without touching the real index or the stash. It copies the real index
// to a temporary one so the stat cache is warm (only changed files are
// re-hashed), stages everything there, and writes the tree.
func WorktreeTree(dir string) (string, error) {
	root, err := gitRoot(dir)
	if err != nil {
		return "", err
	}
	idx, err := gitOut(root, nil, "", "rev-parse", "--git-path", "index")
	if err != nil {
		return "", err
	}
	if !filepath.IsAbs(idx) {
		idx = filepath.Join(root, idx)
	}
	tmp, err := os.CreateTemp("", "am-index-")
	if err != nil {
		return "", err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if data, err := os.ReadFile(idx); err == nil {
		_, _ = tmp.Write(data)
		_ = tmp.Close()
		// Keep the real index's mtime on the copy: git treats an entry whose
		// file mtime is not older than the index as "racily clean" and
		// re-hashes it instead of trusting the stat cache. A fresh copy would
		// be newer than every file, so a same-size edit made in the same
		// second as the last index write (common right after a commit) would
		// pass as unchanged.
		if fi, err := os.Stat(idx); err == nil {
			_ = os.Chtimes(tmpPath, fi.ModTime(), fi.ModTime())
		}
	} else {
		// No index yet (fresh repo): start empty; add -A fills it.
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
	}
	env := []string{"GIT_INDEX_FILE=" + tmpPath}
	if _, err := gitOut(root, env, "", "add", "-A", "--", "."); err != nil {
		return "", err
	}
	return gitOut(root, env, "", "write-tree")
}

// FileStat is one file's share of the unreviewed change. Binary files carry
// Binary=true and zero counts.
type FileStat struct {
	Path           string
	Added, Deleted int
	Binary         bool
}

// ReviewFileStats lists the files that differ between two trees with their
// line counts (`git diff --numstat -z`, renames reported as delete + add so a
// path is always one file).
func ReviewFileStats(dir, baseTree, curTree string) ([]FileStat, error) {
	out, err := gitOut(dir, nil, "", "diff", "--numstat", "-z", "--no-renames", "--no-ext-diff", baseTree, curTree)
	if err != nil {
		return nil, err
	}
	var files []FileStat
	for _, rec := range strings.Split(out, "\x00") {
		if rec == "" {
			continue
		}
		parts := strings.SplitN(rec, "\t", 3)
		if len(parts) != 3 {
			continue
		}
		fs := FileStat{Path: parts[2]}
		if parts[0] == "-" || parts[1] == "-" {
			fs.Binary = true
		} else {
			fs.Added, _ = strconv.Atoi(parts[0])
			fs.Deleted, _ = strconv.Atoi(parts[1])
		}
		files = append(files, fs)
	}
	return files, nil
}

// ReviewFileDiff is the unified diff of one path between two trees, without
// colour or external diff drivers so callers can parse and style it.
func ReviewFileDiff(dir, baseTree, curTree, path string) (string, error) {
	return gitOut(dir, nil, "", "diff", "--no-color", "--no-renames", "--no-ext-diff", baseTree, curTree, "--", path)
}

// HeadInfo returns the current branch name ("" when detached or unborn) and
// HEAD's sha ("" when unborn).
func HeadInfo(dir string) (branch, sha string, err error) {
	if _, err = gitRoot(dir); err != nil {
		return "", "", err
	}
	branch, _ = gitOut(dir, nil, "", "symbolic-ref", "-q", "--short", "HEAD")
	sha, _ = gitOut(dir, nil, "", "rev-parse", "-q", "--verify", "HEAD^{commit}")
	return branch, sha, nil
}

// headTree is HEAD's committed tree, or the empty tree on an unborn branch.
func headTree(dir string) (string, error) {
	if t, err := gitOut(dir, nil, "", "rev-parse", "-q", "--verify", "HEAD^{tree}"); err == nil && t != "" {
		return t, nil
	}
	return gitOut(dir, nil, "", "mktree")
}

// ReviewRead loads the session's checkpoint chain (newest first) and
// baseline. A repository without the refs yields an empty state, nil error.
func ReviewRead(dir, session string) (ReviewState, error) {
	var st ReviewState
	if _, err := gitRoot(dir); err != nil {
		return st, err
	}
	cpRef, baseRef := reviewRefs(session)
	if _, err := gitOut(dir, nil, "", "rev-parse", "-q", "--verify", cpRef); err != nil {
		return st, nil
	}
	out, err := gitOut(dir, nil, "", "log", "--format=%H%x1f%T%x1f%B%x1e", cpRef)
	if err != nil {
		return st, err
	}
	for _, rec := range strings.Split(out, "\x1e") {
		rec = strings.TrimSpace(rec)
		if rec == "" {
			continue
		}
		parts := strings.SplitN(rec, "\x1f", 3)
		if len(parts) != 3 {
			continue
		}
		cp := Checkpoint{ID: parts[0], Tree: parts[1]}
		for _, line := range strings.Split(parts[2], "\n") {
			k, v, ok := strings.Cut(line, "=")
			if !ok {
				continue
			}
			switch k {
			case "kind":
				cp.Kind = v
			case "branch":
				cp.Branch = v
			case "head":
				cp.Head = v
			case "anchor":
				cp.Anchor = v
			case "time":
				cp.Time, _ = strconv.ParseInt(v, 10, 64)
			}
		}
		st.Checkpoints = append(st.Checkpoints, cp)
	}
	st.BaselineRef, _ = gitOut(dir, nil, "", "rev-parse", "-q", "--verify", baseRef)
	return st, nil
}

// Baseline is the checkpoint `am diff` compares against: the one the
// baseline ref names, else the oldest (launch) checkpoint. ok is false when
// the chain is empty.
func (st ReviewState) Baseline() (Checkpoint, bool) {
	if len(st.Checkpoints) == 0 {
		return Checkpoint{}, false
	}
	for _, cp := range st.Checkpoints {
		if cp.ID == st.BaselineID() {
			return cp, true
		}
	}
	return st.Checkpoints[len(st.Checkpoints)-1], true
}

// BaselineID is the baseline ref's target, else the launch checkpoint's id.
func (st ReviewState) BaselineID() string {
	if st.BaselineRef != "" {
		return st.BaselineRef
	}
	if n := len(st.Checkpoints); n > 0 {
		return st.Checkpoints[n-1].ID
	}
	return ""
}

// Find resolves a checkpoint by full or abbreviated id.
func (st ReviewState) Find(id string) (Checkpoint, bool) {
	if id == "" {
		return Checkpoint{}, false
	}
	var found Checkpoint
	n := 0
	for _, cp := range st.Checkpoints {
		if strings.HasPrefix(cp.ID, id) {
			found = cp
			n++
		}
	}
	return found, n == 1
}

// lastBranch is the branch of the newest checkpoint that recorded one
// (detached-HEAD checkpoints carry none).
func (st ReviewState) lastBranch() string {
	for _, cp := range st.Checkpoints {
		if cp.Branch != "" {
			return cp.Branch
		}
	}
	return ""
}

var checkpointEnv = []string{
	"GIT_AUTHOR_NAME=am", "GIT_AUTHOR_EMAIL=am@localhost",
	"GIT_COMMITTER_NAME=am", "GIT_COMMITTER_EMAIL=am@localhost",
}

// reviewAdd appends a checkpoint of kind with the given tree and optionally
// moves the baseline to it. The chain ref is advanced with compare-and-swap
// on the parent it was built from, so two writers (the state hook's detached
// tail and the title scan) cannot both append for the same event: the loser
// fails and its caller re-reads.
func reviewAdd(dir, session, kind, tree string, moveBaseline bool) (Checkpoint, error) {
	return reviewAddAnchored(dir, session, kind, tree, "", moveBaseline)
}

// reviewAddAnchored is reviewAdd with an anchor: rebase and pick checkpoints
// carry the tree of a commit that is not HEAD, and record which.
func reviewAddAnchored(dir, session, kind, tree, anchor string, moveBaseline bool) (Checkpoint, error) {
	if !isSafeSessionName(session) {
		return Checkpoint{}, fmt.Errorf("unsafe session name %q", session)
	}
	branch, head, err := HeadInfo(dir)
	if err != nil {
		return Checkpoint{}, err
	}
	cpRef, baseRef := reviewRefs(session)
	parent, _ := gitOut(dir, nil, "", "rev-parse", "-q", "--verify", cpRef)
	now := time.Now().Unix()
	msg := fmt.Sprintf("am checkpoint\n\nkind=%s\nbranch=%s\nhead=%s\n", kind, branch, head)
	if anchor != "" {
		msg += "anchor=" + anchor + "\n"
	}
	msg += fmt.Sprintf("time=%d\n", now)
	args := []string{"commit-tree", tree}
	if parent != "" {
		args = append(args, "-p", parent)
	}
	args = append(args, "-F", "-")
	id, err := gitOut(dir, checkpointEnv, msg, args...)
	if err != nil {
		return Checkpoint{}, err
	}
	casArgs := []string{"update-ref", cpRef, id}
	if parent != "" {
		casArgs = append(casArgs, parent)
	} else {
		casArgs = append(casArgs, strings.Repeat("0", 40))
	}
	if _, err := gitOut(dir, nil, "", casArgs...); err != nil {
		return Checkpoint{}, fmt.Errorf("checkpoint chain moved under us: %w", err)
	}
	if moveBaseline {
		if _, err := gitOut(dir, nil, "", "update-ref", baseRef, id); err != nil {
			return Checkpoint{}, err
		}
	}
	return Checkpoint{ID: id, Kind: kind, Tree: tree, Branch: branch, Head: head, Anchor: anchor, Time: now}, nil
}

// ReviewInit records the launch checkpoint (the worktree as it is now, the
// baseline) when the session has none yet. created is false when a chain
// already existed; the newest checkpoint is returned then.
func ReviewInit(dir, session string) (cp Checkpoint, created bool, err error) {
	st, err := ReviewRead(dir, session)
	if err != nil {
		return Checkpoint{}, false, err
	}
	if len(st.Checkpoints) > 0 {
		return st.Checkpoints[0], false, nil
	}
	tree, err := WorktreeTree(dir)
	if err != nil {
		return Checkpoint{}, false, err
	}
	cp, err = reviewAdd(dir, session, "launch", tree, true)
	if err != nil {
		// Lost a race with another initializer: adopt its chain.
		if st2, err2 := ReviewRead(dir, session); err2 == nil && len(st2.Checkpoints) > 0 {
			return st2.Checkpoints[0], false, nil
		}
		return Checkpoint{}, false, err
	}
	return cp, true, nil
}

// ReviewAck records the worktree as reviewed: a new ack checkpoint that
// becomes the baseline.
func ReviewAck(dir, session string) (Checkpoint, error) {
	if _, _, err := ReviewInit(dir, session); err != nil {
		return Checkpoint{}, err
	}
	tree, err := WorktreeTree(dir)
	if err != nil {
		return Checkpoint{}, err
	}
	return reviewAdd(dir, session, "ack", tree, true)
}

// ReviewSync records HEAD movement since the newest checkpoint: a branch
// checkpoint (baseline moves) when the branch name changed, a rebase
// checkpoint (baseline re-anchored) when the HEAD the newest checkpoint saw
// is no longer an ancestor of HEAD, a head checkpoint (baseline stays) when
// HEAD moved forward on the same branch. Returns the kind recorded ("launch"
// when the chain had to be created, "" when nothing changed). Idempotent;
// safe to call from several writers.
func ReviewSync(dir, session string) (string, Checkpoint, error) {
	cp, created, err := ReviewInit(dir, session)
	if err != nil {
		return "", Checkpoint{}, err
	}
	if created {
		return "launch", cp, nil
	}
	for attempt := 0; attempt < 2; attempt++ {
		st, err := ReviewRead(dir, session)
		if err != nil || len(st.Checkpoints) == 0 {
			return "", Checkpoint{}, err
		}
		branch, head, err := HeadInfo(dir)
		if err != nil {
			return "", Checkpoint{}, err
		}
		newest := st.Checkpoints[0]
		base, _ := st.Baseline()
		kind, anchor := "", ""
		switch {
		case branch != "" && branch != st.lastBranch():
			kind = "branch"
		case head == newest.Head:
			return "", newest, nil
		case newest.Head != "" && head != "" && !isAncestor(dir, newest.Head, head):
			kind = "rebase"
		default:
			kind = "head"
		}
		var tree string
		if kind == "rebase" {
			// A failure here (patch-id, apply) is not worth losing the event:
			// fall back to a plain head checkpoint and let the user pick. The
			// same when the re-anchored baseline is the one we have (a reset
			// that only dropped the agent's own commits): nothing to move.
			if anchor, tree, err = rebasedBaseline(dir, base, newest.Head, head); err != nil || tree == base.Tree {
				kind, anchor, tree = "head", "", ""
			}
		}
		if tree == "" {
			if tree, err = headTree(dir); err != nil {
				return "", Checkpoint{}, err
			}
		}
		cp, err := reviewAddAnchored(dir, session, kind, tree, anchor, kind == "branch" || kind == "rebase")
		if err == nil {
			return kind, cp, nil
		}
		if attempt == 1 {
			return "", Checkpoint{}, err
		}
	}
	return "", Checkpoint{}, nil
}

// isAncestor reports whether commit a is an ancestor of (or equal to) b.
func isAncestor(dir, a, b string) bool {
	_, err := gitOut(dir, nil, "", "merge-base", "--is-ancestor", a, b)
	return err == nil
}

// patchIDs maps commit sha → stable patch-id for the commits of a `git log`
// range. Commits without a diff of their own (merges, empty commits) are
// absent.
func patchIDs(dir, rng string) (map[string]string, error) {
	ids := map[string]string{}
	log, err := gitOut(dir, nil, "", "log", "-p", "--no-color", "--no-ext-diff", "--no-renames", rng)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(log) == "" {
		return ids, nil
	}
	out, err := gitOut(dir, nil, log+"\n", "patch-id", "--stable")
	if err != nil {
		return nil, err
	}
	for _, line := range strings.Split(out, "\n") {
		if f := strings.Fields(line); len(f) == 2 {
			ids[f[1]] = f[0]
		}
	}
	return ids, nil
}

// rebasedBaseline re-anchors baseline base after HEAD moved from prevHead to
// head by a history rewrite (prevHead is not an ancestor of head). It
// returns the anchor commit and the tree the new baseline should carry.
//
// The agent's own commits are the ones between the baseline's anchor and the
// pre-rewrite head; a rebase keeps their patch-ids, so they are found again
// in the new history and the anchor is the parent of the earliest one —
// everything below it (the new upstream base, pre-existing branch commits)
// is not the agent's work. No commits of its own → the anchor is head (the
// rewrite brought only upstream). Patch-ids that no longer match (amend or
// squash during the rebase) fall back to counting the same number of commits
// down from head, and to the merge base when that leaves the range. The
// baseline's uncommitted delta (its tree vs its head's tree: work that was
// dirty at launch or ack) is re-applied on the anchor's tree when it still
// applies, so it does not reappear as unreviewed.
func rebasedBaseline(dir string, base Checkpoint, prevHead, head string) (anchor, tree string, err error) {
	anchor = head
	from := base.AnchorCommit()
	if from == "" {
		from = head
	}
	if mb, _ := gitOut(dir, nil, "", "merge-base", from, head); mb != "" {
		mine, err := patchIDs(dir, from+".."+prevHead)
		if err != nil {
			return "", "", err
		}
		if len(mine) > 0 {
			want := map[string]bool{}
			for _, pid := range mine {
				want[pid] = true
			}
			theirs, err := patchIDs(dir, mb+".."+head)
			if err != nil {
				return "", "", err
			}
			anchor = ""
			if order, _ := gitOut(dir, nil, "", "rev-list", "--reverse", "--topo-order", mb+".."+head); order != "" {
				for _, sha := range strings.Fields(order) {
					if want[theirs[sha]] {
						anchor, _ = gitOut(dir, nil, "", "rev-parse", "-q", "--verify", sha+"^")
						break
					}
				}
			}
			if anchor == "" {
				n, _ := gitOut(dir, nil, "", "rev-list", "--count", from+".."+prevHead)
				if t, err := gitOut(dir, nil, "", "rev-parse", "-q", "--verify", head+"~"+n+"^{commit}"); err == nil && t != "" && isAncestor(dir, mb, t) {
					anchor = t
				} else {
					anchor = mb
				}
			}
		}
	}
	if tree, err = gitOut(dir, nil, "", "rev-parse", "-q", "--verify", anchor+"^{tree}"); err != nil {
		return "", "", err
	}
	if baseHeadTree, _ := gitOut(dir, nil, "", "rev-parse", "-q", "--verify", from+"^{tree}"); baseHeadTree != "" && baseHeadTree != base.Tree {
		if t, err := treeWithDelta(dir, tree, baseHeadTree, base.Tree); err == nil {
			tree = t
		}
	}
	return anchor, tree, nil
}

// treeWithDelta applies the change fromTree → toTree onto tree base in a
// temporary index and returns the resulting tree. Errors when the patch does
// not apply cleanly; the real index and worktree are never touched.
func treeWithDelta(dir, base, fromTree, toTree string) (string, error) {
	root, err := gitRoot(dir)
	if err != nil {
		return "", err
	}
	patch, err := gitOut(root, nil, "", "diff", "--binary", "--no-color", "--no-ext-diff", "--no-renames", fromTree, toTree)
	if err != nil {
		return "", err
	}
	if patch == "" {
		return base, nil
	}
	tmp, err := os.CreateTemp("", "am-index-")
	if err != nil {
		return "", err
	}
	tmpPath := tmp.Name()
	_ = tmp.Close()
	_ = os.Remove(tmpPath) // read-tree creates it
	defer os.Remove(tmpPath)
	env := []string{"GIT_INDEX_FILE=" + tmpPath}
	if _, err := gitOut(root, env, "", "read-tree", base); err != nil {
		return "", err
	}
	if _, err := gitOut(root, env, patch+"\n", "apply", "--cached", "--whitespace=nowarn"); err != nil {
		return "", err
	}
	return gitOut(root, env, "", "write-tree")
}

// CommitCheckpoint is a virtual checkpoint for any commit of the repository
// (kind "commit", not in the chain): its committed tree, anchored on itself.
// ok is false when rev does not name a commit.
func CommitCheckpoint(dir, rev string) (Checkpoint, bool) {
	if rev == "" || strings.HasPrefix(rev, "-") {
		return Checkpoint{}, false
	}
	out, err := gitOut(dir, nil, "", "log", "-1", "--format=%H%x1f%T%x1f%ct", rev+"^{commit}", "--")
	if err != nil || out == "" {
		return Checkpoint{}, false
	}
	parts := strings.SplitN(out, "\x1f", 3)
	if len(parts) != 3 {
		return Checkpoint{}, false
	}
	cp := Checkpoint{ID: parts[0], Kind: "commit", Tree: parts[1], Head: parts[0], Anchor: parts[0]}
	cp.Time, _ = strconv.ParseInt(parts[2], 10, 64)
	return cp, true
}

// ReviewRebaseSuggestion finds a history rewrite the chain never re-anchored
// for (checkpoints recorded before rebase checkpoints existed, or a rewrite
// the hook missed) and returns the base a rebase checkpoint would have
// carried, as a virtual checkpoint of kind "rebase" (its id is the anchor
// commit, so Enter / `b` in the picker resolve it as a commit). ok is false
// when every recorded commit still descends into HEAD, when a rebase
// checkpoint already covers the rewrite, or when the computed tree is one
// the chain already has.
func ReviewRebaseSuggestion(dir string, st ReviewState) (Checkpoint, bool) {
	n := len(st.Checkpoints)
	if n < 2 {
		return Checkpoint{}, false
	}
	_, head, err := HeadInfo(dir)
	if err != nil || head == "" {
		return Checkpoint{}, false
	}
	// prev: the newest checkpoint whose commit was rewritten away.
	prevIdx := -1
	for i, cp := range st.Checkpoints {
		if cp.Kind == "rebase" {
			return Checkpoint{}, false
		}
		if c := cp.AnchorCommit(); c != "" && !isAncestor(dir, c, head) {
			prevIdx = i
			break
		}
	}
	if prevIdx < 0 {
		return Checkpoint{}, false
	}
	// base: the newest "since" point older than prev (launch, or a branch /
	// pick checkpoint that reset the range the agent's commits are counted in).
	base := st.Checkpoints[n-1]
	for _, cp := range st.Checkpoints[prevIdx+1:] {
		if cp.Kind == "launch" || cp.Kind == "branch" || cp.Kind == "pick" {
			base = cp
			break
		}
	}
	if base.AnchorCommit() == "" {
		return Checkpoint{}, false
	}
	anchor, _, err := rebasedBaseline(dir, base, st.Checkpoints[prevIdx].AnchorCommit(), head)
	if err != nil || anchor == "" {
		return Checkpoint{}, false
	}
	cp, ok := CommitCheckpoint(dir, anchor)
	if !ok {
		return Checkpoint{}, false
	}
	for _, have := range st.Checkpoints {
		if have.Tree == cp.Tree {
			return Checkpoint{}, false
		}
	}
	cp.Kind = "rebase"
	return cp, true
}

// Resolve finds id in the chain (full or abbreviated checkpoint id), else as
// a commit-ish of the repository (a virtual "commit" checkpoint).
func (st ReviewState) Resolve(dir, id string) (Checkpoint, bool) {
	if cp, ok := st.Find(id); ok {
		return cp, true
	}
	return CommitCheckpoint(dir, id)
}

// ReviewSetBaseline points the baseline at checkpoint id (full or
// abbreviated). An id that is not in the chain but names a commit of the
// repository is recorded first as a pick checkpoint of that commit's tree.
func ReviewSetBaseline(dir, session, id string) (Checkpoint, error) {
	st, err := ReviewRead(dir, session)
	if err != nil {
		return Checkpoint{}, err
	}
	cp, ok := st.Find(id)
	if !ok {
		commit, isCommit := CommitCheckpoint(dir, id)
		if !isCommit {
			return Checkpoint{}, fmt.Errorf("no checkpoint or commit %q for %s", id, session)
		}
		if len(st.Checkpoints) == 0 {
			if _, _, err := ReviewInit(dir, session); err != nil {
				return Checkpoint{}, err
			}
		}
		return reviewAddAnchored(dir, session, "pick", commit.Tree, commit.ID, true)
	}
	_, baseRef := reviewRefs(session)
	if _, err := gitOut(dir, nil, "", "update-ref", baseRef, cp.ID); err != nil {
		return Checkpoint{}, err
	}
	return cp, nil
}

// ReviewResetBaseline moves the baseline back to the launch checkpoint.
func ReviewResetBaseline(dir, session string) (Checkpoint, error) {
	st, err := ReviewRead(dir, session)
	if err != nil {
		return Checkpoint{}, err
	}
	n := len(st.Checkpoints)
	if n == 0 {
		return Checkpoint{}, fmt.Errorf("no checkpoints for %s", session)
	}
	return ReviewSetBaseline(dir, session, st.Checkpoints[n-1].ID)
}

// ReviewDiffStat sizes the change from baseTree to the current worktree.
func ReviewDiffStat(dir, baseTree string) (ReviewStat, error) {
	cur, err := WorktreeTree(dir)
	if err != nil {
		return ReviewStat{}, err
	}
	return ReviewStatTrees(dir, baseTree, cur)
}

// ReviewStatTrees sizes the change between two trees (the picker measures
// every checkpoint against one worktree snapshot).
func ReviewStatTrees(dir, baseTree, cur string) (ReviewStat, error) {
	rs := ReviewStat{BaseTree: baseTree, CurTree: cur}
	if baseTree == cur {
		return rs, nil
	}
	out, err := gitOut(dir, nil, "", "diff", "--numstat", baseTree, cur)
	if err != nil {
		return rs, err
	}
	for _, line := range strings.Split(out, "\n") {
		f := strings.Fields(line)
		if len(f) < 3 {
			continue
		}
		rs.Files++
		if n, err := strconv.Atoi(f[0]); err == nil {
			rs.Added += n
		}
		if n, err := strconv.Atoi(f[1]); err == nil {
			rs.Deleted += n
		}
	}
	return rs, nil
}

// HeadMoved describes how HEAD moved since a checkpoint's anchor commit: ""
// when it has not, "N commits" when the anchor is an ancestor, "rebased or
// reset" when the history was rewritten under it, "moved" when the checkpoint
// recorded no commit to compare with.
func HeadMoved(dir string, cp Checkpoint) string {
	from := cp.AnchorCommit()
	_, head, err := HeadInfo(dir)
	if err != nil || head == from {
		return ""
	}
	if from == "" {
		return "moved"
	}
	if !isAncestor(dir, from, head) {
		return "rebased or reset"
	}
	n, err := gitOut(dir, nil, "", "rev-list", "--count", from+".."+head)
	if err != nil || n == "" {
		return "moved"
	}
	if n == "1" {
		return "1 commit"
	}
	return n + " commits"
}

// ReviewAdopt renames the refs of oldSession to newSession (restore gives
// the resumed conversation a new session name). A new session's own launch
// checkpoint, if any, is replaced by the old chain.
func ReviewAdopt(dir, oldSession, newSession string) error {
	if !isSafeSessionName(oldSession) || !isSafeSessionName(newSession) || oldSession == newSession {
		return nil
	}
	if _, err := gitRoot(dir); err != nil {
		return err
	}
	oldCP, oldBase := reviewRefs(oldSession)
	newCP, newBase := reviewRefs(newSession)
	for _, pair := range [][2]string{{oldCP, newCP}, {oldBase, newBase}} {
		val, err := gitOut(dir, nil, "", "rev-parse", "-q", "--verify", pair[0])
		if err != nil || val == "" {
			continue
		}
		if _, err := gitOut(dir, nil, "", "update-ref", pair[1], val); err != nil {
			return err
		}
		_, _ = gitOut(dir, nil, "", "update-ref", "-d", pair[0])
	}
	return nil
}

// ReviewDrop deletes a session's refs (sessions-log GC: the conversation can
// no longer be restored, so nothing will ever diff against them again).
func ReviewDrop(dir, session string) {
	if !isSafeSessionName(session) {
		return
	}
	if _, err := gitRoot(dir); err != nil {
		return
	}
	cpRef, baseRef := reviewRefs(session)
	_, _ = gitOut(dir, nil, "", "update-ref", "-d", baseRef)
	_, _ = gitOut(dir, nil, "", "update-ref", "-d", cpRef)
}

// EffectiveDir is where the session's agent works now: the registry workdir
// when set, else the launch directory.
func (s Session) EffectiveDir() string {
	if s.Workdir != "" {
		return s.Workdir
	}
	return s.Directory
}

// ReviewRecord stores the unreviewed-change size on the session's registry
// row (files, added, deleted, and when it was measured) under the shared
// registry lock. Bash readers (status-bar tab, `am list`) render it.
func (e Env) ReviewRecord(session string, rs ReviewStat, at time.Time) {
	lock := lockRegistry(e.AmDir)
	defer unlockRegistry(lock)
	regPath := e.RegistryPath()
	reg := ReadRegistry(regPath)
	meta, ok := reg.Sessions[session]
	if !ok {
		return
	}
	if meta.ReviewFiles == rs.Files && meta.ReviewAdded == rs.Added && meta.ReviewDeleted == rs.Deleted && meta.ReviewAt == at.Unix() {
		return
	}
	meta.ReviewFiles, meta.ReviewAdded, meta.ReviewDeleted, meta.ReviewAt = rs.Files, rs.Added, rs.Deleted, at.Unix()
	reg.Sessions[session] = meta
	writeRegistryAtomic(regPath, reg)
}

// ReviewMeasure syncs HEAD movement, sizes the change from the baseline (or
// from checkpoint fromID when given) to the worktree, and records it on the
// registry row when measuring against the baseline. Returns the baseline
// (or chosen) checkpoint, the stat, and HEAD movement since it.
func (e Env) ReviewMeasure(session, dir, fromID string, record bool) (Checkpoint, ReviewStat, string, error) {
	if _, _, err := ReviewSync(dir, session); err != nil {
		return Checkpoint{}, ReviewStat{}, "", err
	}
	st, err := ReviewRead(dir, session)
	if err != nil {
		return Checkpoint{}, ReviewStat{}, "", err
	}
	var cp Checkpoint
	if fromID != "" {
		var ok bool
		if cp, ok = st.Resolve(dir, fromID); !ok {
			return Checkpoint{}, ReviewStat{}, "", fmt.Errorf("no checkpoint or commit %q for %s", fromID, session)
		}
	} else {
		var ok bool
		if cp, ok = st.Baseline(); !ok {
			// A session launched before review checkpoints existed (or
			// registered by hand): adopt the working copy as its launch
			// checkpoint now, so "nothing reviewed yet" starts from here.
			if cp, _, err = ReviewInit(dir, session); err != nil {
				return Checkpoint{}, ReviewStat{}, "", err
			}
		}
	}
	rs, err := ReviewDiffStat(dir, cp.Tree)
	if err != nil {
		return cp, rs, "", err
	}
	if record && fromID == "" {
		e.ReviewRecord(session, rs, time.Now())
	}
	return cp, rs, HeadMoved(dir, cp), nil
}
