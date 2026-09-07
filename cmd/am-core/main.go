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
	case "-h", "--help", "help":
		fmt.Print(usage)
	default:
		fmt.Fprintf(os.Stderr, "am-core: unknown command %q\n%s", cmd, usage)
		os.Exit(2)
	}
}
