package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNoteMessage(t *testing.T) {
	msg := noteMessage("lib/x.sh", "L2-3", "@@ -1,3 +1,4 @@\n one\n-two\n+two!\n", "  why the bang?  ")
	want := "Review note on lib/x.sh L2-3:\nwhy the bang?\n\n```diff\n@@ -1,3 +1,4 @@\n one\n-two\n+two!\n```\n"
	if msg != want {
		t.Fatalf("message:\n%q\nwant:\n%q", msg, want)
	}
	// A binary or hunk-less file: location and note only.
	msg = noteMessage("img.png", "", "", "replace with the svg")
	if msg != "Review note on img.png:\nreplace with the svg\n" {
		t.Fatalf("hunk-less message: %q", msg)
	}
}

// fakeAM writes a script standing in for `am`: it appends its argv to a log,
// echoes stdin into the log, and exits with the code named by the argv shape
// in `codes` ("send"→first call, "queue"→--queue call).
func fakeAM(t *testing.T, sendCode, queueCode int) (path, log string) {
	t.Helper()
	dir := t.TempDir()
	path = filepath.Join(dir, "am")
	log = filepath.Join(dir, "log")
	script := "#!/usr/bin/env bash\n" +
		"printf 'ARGS %s\\n' \"$*\" >> \"" + log + "\"\n" +
		"{ printf 'STDIN '; cat; printf '\\n'; } >> \"" + log + "\"\n" +
		"case \" $* \" in\n" +
		"  *' --queue '*) echo 'Queued for s' >&2; exit " + itoa(queueCode) + " ;;\n" +
		"  *) echo 'Session s is running; use --wait or --queue' >&2; exit " + itoa(sendCode) + " ;;\n" +
		"esac\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path, log
}

func readLog(t *testing.T, log string) string {
	t.Helper()
	b, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestSendNoteDelivered(t *testing.T) {
	am, log := fakeAM(t, 0, 0)
	res, err := sendNote(am, "am-abc", "hello agent\n")
	if err != nil || res.queued {
		t.Fatalf("delivered: res=%+v err=%v", res, err)
	}
	got := readLog(t, log)
	if !strings.Contains(got, "ARGS send am-abc\n") || strings.Contains(got, "--queue") {
		t.Fatalf("argv: %q", got)
	}
}

func TestSendNoteQueuedWhenBusy(t *testing.T) {
	am, log := fakeAM(t, 4, 0)
	res, err := sendNote(am, "am-abc", "hello agent\n")
	if err != nil || !res.queued {
		t.Fatalf("busy: res=%+v err=%v", res, err)
	}
	got := readLog(t, log)
	if !strings.Contains(got, "ARGS send am-abc\n") || !strings.Contains(got, "ARGS send --queue am-abc\n") {
		t.Fatalf("argv: %q", got)
	}
	if strings.Count(got, "STDIN hello agent") != 2 {
		t.Fatalf("prompt should travel on stdin to both calls: %q", got)
	}
}

func TestSendNoteRefusedWithoutAgent(t *testing.T) {
	am, _ := fakeAM(t, 2, 0)
	if _, err := sendNote(am, "am-abc", "x"); err == nil || !strings.Contains(err.Error(), "no running agent") {
		t.Fatalf("idle session: err=%v", err)
	}
	am, _ = fakeAM(t, 1, 0)
	if _, err := sendNote(am, "am-abc", "x"); err == nil || !strings.Contains(err.Error(), "Session s is running") {
		t.Fatalf("other failure surfaces am's last line: err=%v", err)
	}
	if _, err := sendNote("", "am-abc", "x"); err == nil {
		t.Fatal("no am path must error")
	}
}

func TestSendNoteQueueFailure(t *testing.T) {
	am, _ := fakeAM(t, 4, 1)
	if _, err := sendNote(am, "am-abc", "x"); err == nil || !strings.Contains(err.Error(), "queue failed") {
		t.Fatalf("queue failure: err=%v", err)
	}
}
