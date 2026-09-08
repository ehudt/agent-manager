// am-core is the compiled back end of the bash maintenance and query
// wrappers in lib/registry.sh and lib/utils.sh. Periodic work (tick, titles,
// restore-scan, gc, slog-gc) is silent and exits 0; queries print their
// answer on stdout. Paths and the tmux server come from the environment
// (AM_DIR, AM_STATE_DIR, AM_IDENTITY_DIR, AM_SESSIONS_LOG, AM_TMUX_SOCKET,
// AM_SESSION_PREFIX, HOME), with lib/utils.sh's defaults.
package main

import (
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/ehud-tamir/agent-manager/internal/sessions"
)

const usage = `usage: am-core <command> [args]

periodic (exit 0; throttled 60s per marker unless --force):
  tick [--force]            title/workdir refresh + restore scan + gc (one status-bar tick)
  titles [--force]          title/workdir/branch refresh, then the restore scan
  restore-scan [--force]    snapshots, session-id binding, task/branch sync into the sessions log
  gc [--force]              reap dead registry rows/state files; prune sessions log, snapshots, temps
                            prints the number of registry rows removed
  slog-gc                   prune the sessions log only

queries:
  restorable                          JSONL lines of resumable closed sessions, newest first
  first-message <agent> <dir> [sid] [transcript]
                                      first user message of the bound transcript (empty when unknown)
  detect-id <session> <dir> [agent]   conversation id from the session's own hook sidecar, verified
  jsonl-exists <dir> <sid> [agent] [transcript]
                                      exit 0 when the transcript still exists

review checkpoints (refs/am/<session>/{checkpoints,baseline} in <dir>'s repo):
  review-init <session> <dir>         record the launch checkpoint unless one exists; prints its id
  review-sync <session> <dir>         record a branch/head checkpoint when HEAD moved; prints "<kind> <id>"
  review-ack <session> <dir>          record the worktree as reviewed (new baseline); prints its id
  review-baseline <session> <dir> [--reset | <id>]
                                      print the baseline (id kind branch head time), or move it
  review-list <session> <dir>         checkpoints newest first: id kind branch head time baseline(*|-)
  review-stat <session> <dir> [--from <id>] [--record]
                                      files added deleted base_id base_kind base_time base_tree cur_tree head_moved
                                      (--record also stores the count on the registry row)
  review-adopt <old> <new> <dir>      rename a closed session's refs to its restored session
  review-drop <session> <dir>         delete a session's refs
`

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	env := sessions.LoadEnv()
	cmd, args := os.Args[1], os.Args[2:]
	force := false
	for _, a := range args {
		if a == "--force" || a == "1" {
			force = true
		}
	}
	arg := func(i int) string {
		if i < len(args) {
			return args[i]
		}
		return ""
	}

	switch cmd {
	case "tick":
		env.Tick(force)
	case "titles":
		env.TitleScan(force)
	case "restore-scan":
		env.RestoreScan(force)
	case "gc":
		fmt.Println(env.GC(force))
	case "slog-gc":
		env.SessionsLogGC()
	case "restorable":
		for _, line := range env.Restorable() {
			fmt.Println(line)
		}
	case "first-message":
		if len(args) < 2 {
			fmt.Fprint(os.Stderr, usage)
			os.Exit(2)
		}
		if msg := sessions.FirstMessage(arg(0), arg(1), arg(2), arg(3)); msg != "" {
			fmt.Println(msg)
		}
	case "detect-id":
		if len(args) < 2 {
			fmt.Fprint(os.Stderr, usage)
			os.Exit(2)
		}
		if sid := env.DetectID(arg(0), arg(1), arg(2)); sid != "" {
			fmt.Println(sid)
		}
	case "jsonl-exists":
		if len(args) < 2 {
			fmt.Fprint(os.Stderr, usage)
			os.Exit(2)
		}
		agent := arg(2)
		if agent == "" {
			agent = "claude"
		}
		if !env.JSONLExists(arg(0), arg(1), agent, arg(3)) {
			os.Exit(1)
		}
	case "review-init", "review-sync", "review-ack", "review-baseline", "review-list", "review-stat", "review-adopt", "review-drop":
		if len(args) < 2 {
			fmt.Fprint(os.Stderr, usage)
			os.Exit(2)
		}
		if err := reviewCmd(env, cmd, args); err != nil {
			fmt.Fprintf(os.Stderr, "am-core %s: %v\n", cmd, err)
			if sessions.ErrNoRepo(err) {
				os.Exit(3)
			}
			os.Exit(1)
		}
	case "-h", "--help", "help":
		fmt.Print(usage)
	default:
		fmt.Fprintf(os.Stderr, "am-core: unknown command %q\n%s", cmd, usage)
		os.Exit(2)
	}
}

// reviewCmd dispatches the review-* subcommands (see usage). Output is
// whitespace-separated fields for the bash wrappers in lib/review.sh.
func reviewCmd(env sessions.Env, cmd string, args []string) error {
	session, dir := args[0], args[1]
	rest := args[2:]
	printCP := func(cp sessions.Checkpoint) {
		fmt.Printf("%s %s %s %s %d\n", cp.ID, cp.Kind, orDash(cp.Branch), orDash(cp.Head), cp.Time)
	}
	switch cmd {
	case "review-init":
		cp, _, err := sessions.ReviewInit(dir, session)
		if err != nil {
			return err
		}
		fmt.Println(cp.ID)
	case "review-sync":
		kind, cp, err := sessions.ReviewSync(dir, session)
		if err != nil {
			return err
		}
		if kind != "" {
			fmt.Printf("%s %s\n", kind, cp.ID)
		}
	case "review-ack":
		cp, err := sessions.ReviewAck(dir, session)
		if err != nil {
			return err
		}
		env.ReviewRecord(session, sessions.ReviewStat{}, time.Now())
		fmt.Println(cp.ID)
	case "review-baseline":
		var cp sessions.Checkpoint
		var err error
		switch {
		case len(rest) == 0:
			st, rerr := sessions.ReviewRead(dir, session)
			if rerr != nil {
				return rerr
			}
			var ok bool
			if cp, ok = st.Baseline(); !ok {
				return fmt.Errorf("no checkpoints for %s", session)
			}
		case rest[0] == "--reset":
			cp, err = sessions.ReviewResetBaseline(dir, session)
		default:
			cp, err = sessions.ReviewSetBaseline(dir, session, rest[0])
		}
		if err != nil {
			return err
		}
		printCP(cp)
	case "review-list":
		st, err := sessions.ReviewRead(dir, session)
		if err != nil {
			return err
		}
		base := st.BaselineID()
		for _, cp := range st.Checkpoints {
			mark := "-"
			if cp.ID == base {
				mark = "*"
			}
			fmt.Printf("%s %s %s %s %d %s\n", cp.ID, cp.Kind, orDash(cp.Branch), orDash(cp.Head), cp.Time, mark)
		}
	case "review-stat":
		from, record := "", false
		for i := 0; i < len(rest); i++ {
			switch rest[i] {
			case "--from":
				if i+1 < len(rest) {
					from = rest[i+1]
					i++
				}
			case "--record":
				record = true
			}
		}
		cp, rs, moved, err := env.ReviewMeasure(session, dir, from, record)
		if err != nil {
			return err
		}
		if moved == "" {
			moved = "-"
		}
		fmt.Printf("%d %d %d %s %s %d %s %s %s\n", rs.Files, rs.Added, rs.Deleted,
			cp.ID, cp.Kind, cp.Time, rs.BaseTree, rs.CurTree, strings.ReplaceAll(moved, " ", "_"))
	case "review-adopt":
		// args: <old> <new> <dir>
		if len(args) < 3 {
			return fmt.Errorf("usage: review-adopt <old> <new> <dir>")
		}
		return sessions.ReviewAdopt(args[2], args[0], args[1])
	case "review-drop":
		sessions.ReviewDrop(dir, session)
	}
	return nil
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}
