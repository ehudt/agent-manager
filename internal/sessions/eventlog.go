package sessions

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// The events log ($AM_DIR/events.log) is the always-on, append-only record
// of lifecycle events and swallowed failures, shared with bash (`am_event`
// in lib/utils.sh) and the state hook (`_hook_event`). Same line shape as
// the bash writer, so one grep covers every writer:
//
//	<utc rfc3339> TAB <component>:<pid> TAB <event> TAB <session|-> TAB k=v k=v ...
//
// Go writes only on failures — the tick, scans, and queries are hot paths
// and never log their successes. AM_EVENTS_LOG overrides the path (empty
// disables, which bash forwards through am_core); the title scan caps the
// file at eventsLogCap, newest half kept.

// eventsLogCap bounds events.log. A few hundred ~200-byte lines a day makes
// 8MB months of history; a runaway writer is cut back within one scan.
const eventsLogCap = 8 * 1024 * 1024

// eventsLogPath: the file to append to, "" when logging is disabled.
func eventsLogPath(amDir string) string {
	if v, ok := os.LookupEnv("AM_EVENTS_LOG"); ok {
		return v
	}
	return filepath.Join(amDir, "events.log")
}

// EventLog appends one event. kv are "key=value" strings; tabs and newlines
// in values become spaces and each is capped at 400 bytes. Never fails the
// caller.
func EventLog(amDir, event, session string, kv ...string) {
	path := eventsLogPath(amDir)
	if path == "" {
		return
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	if session == "" {
		session = "-"
	}
	parts := make([]string, 0, len(kv)+1)
	if from := os.Getenv("AM_SESSION_NAME"); from != "" {
		parts = append(parts, "from="+from)
	}
	for _, p := range kv {
		parts = append(parts, eventValue(p))
	}
	fmt.Fprintf(f, "%s\t%s:%d\t%s\t%s\t%s\n",
		time.Now().UTC().Format("2006-01-02T15:04:05Z"),
		eventComponent(), os.Getpid(), event, eventValue(session), strings.Join(parts, " "))
}

// eventComponent names the writer: "core" for am-core, else the binary name.
func eventComponent() string {
	base := filepath.Base(os.Args[0])
	if rest, ok := strings.CutPrefix(base, "am-"); ok {
		return rest
	}
	return base
}

func eventValue(v string) string {
	v = strings.NewReplacer("\t", " ", "\n", " ", "\r", " ").Replace(v)
	if len(v) > 400 {
		v = v[:400]
	}
	return v
}
