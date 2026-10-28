package sessions

// Background launches. A browser launch that does not attach — one with a
// first prompt, or one whose @spec the dir_provider has to resolve (a fetch,
// a clone) — runs in a detached `am launch-worker`, so the popup closes at
// once. Each pending launch is a record under $AM_DIR/launches/, all of it
// written by bash (`_launch_bg_*` in am): <id>.json (target, agent, flags,
// state running|failed, error), <id>.pid (the worker), <id>.log (the
// worker's output: the provider's progress, launch errors) and <id>.prompt.
// A launch that succeeds removes them all (the session row takes over); a
// failed one stays, prompt and output kept, until it is retried or
// forgotten. This file only reads them, for the browser's rows.

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Launch is one <id>.json record.
type Launch struct {
	ID          string `json:"id"`
	Target      string `json:"target"`
	Agent       string `json:"agent"`
	Flags       string `json:"flags"`
	PromptChars int    `json:"prompt_chars"`
	CreatedAt   int64  `json:"created_at"`
	State       string `json:"state"` // running | failed
	Error       string `json:"error"`
}

// launchPidGrace is how long a running record may have no pid file: the
// starter writes <id>.json, spawns the worker, then writes <id>.pid.
const launchPidGrace = 30 * time.Second

// LaunchesDir is where the background launch records live.
func LaunchesDir(amDir string) string {
	return filepath.Join(amDir, "launches")
}

// LoadLaunchEntries returns a browser row per background launch, newest
// first. A running record whose worker is gone (killed, a reboot) shows as
// failed: nothing will finish it.
func LoadLaunchEntries(amDir string, now time.Time) []Entry {
	dir := LaunchesDir(amDir)
	paths, _ := filepath.Glob(filepath.Join(dir, "*.json"))
	var launches []Launch
	for _, p := range paths {
		data, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		var l Launch
		if json.Unmarshal(data, &l) != nil || l.ID == "" {
			continue
		}
		if l.State != "failed" && !launchWorkerAlive(dir, l, now) {
			l.State = "failed"
			if l.Error == "" {
				l.Error = "the launch worker exited before the session started"
			}
		}
		launches = append(launches, l)
	}
	sort.SliceStable(launches, func(i, j int) bool {
		if launches[i].CreatedAt != launches[j].CreatedAt {
			return launches[i].CreatedAt > launches[j].CreatedAt
		}
		return launches[i].ID < launches[j].ID
	})

	entries := make([]Entry, 0, len(launches))
	for _, l := range launches {
		prompt := ""
		if l.PromptChars > 0 {
			if data, err := os.ReadFile(filepath.Join(dir, l.ID+".prompt")); err == nil {
				prompt = string(data)
			}
		}
		agent := l.Agent
		if agent == "" {
			agent = "unknown"
		}
		kind, status, glyph := EntryLaunching, "starting", "◌ "
		if l.State == "failed" {
			kind, status, glyph = EntryLaunchFailed, "failed", "⚠ "
		}
		base := glyph + launchTargetLabel(l.Target) + " [" + agent + "]"
		if first := strings.TrimSpace(firstLine(strings.TrimSpace(prompt))); first != "" {
			base += " " + truncRunes(first, 60)
		}
		display := base + " (" + status + ")"
		if l.Error != "" {
			display += " " + l.Error
		}
		entries = append(entries, Entry{
			Meta:         Session{AgentType: l.Agent},
			Kind:         kind,
			Display:      display,
			DisplayBase:  base,
			TimeAgo:      status,
			RecencyUnix:  l.CreatedAt,
			LaunchID:     l.ID,
			LaunchTarget: l.Target,
			LaunchPrompt: prompt,
			LaunchLog:    filepath.Join(dir, l.ID+".log"),
			LaunchError:  l.Error,
		})
	}
	return entries
}

// launchWorkerAlive reports whether the record's worker still runs: its pid
// answers signal 0 (EPERM counts — the process exists). With no pid file
// yet the record gets launchPidGrace.
func launchWorkerAlive(dir string, l Launch, now time.Time) bool {
	data, err := os.ReadFile(filepath.Join(dir, l.ID+".pid"))
	if err != nil {
		return now.Unix()-l.CreatedAt < int64(launchPidGrace/time.Second)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil || pid <= 0 {
		return false
	}
	err = syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

// launchTargetLabel is a target as a row shows it: a @spec as typed, a
// directory by its basename.
func launchTargetLabel(target string) string {
	if strings.HasPrefix(target, "@") || target == "" {
		return target
	}
	return filepath.Base(target)
}

// truncRunes cuts s to n runes with a trailing ….
func truncRunes(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}
