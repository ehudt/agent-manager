package main

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"

	"github.com/ehud-tamir/agent-manager/internal/sessions"
)

const sampleDiff = `diff --git a/lib/x.sh b/lib/x.sh
index 1111111..2222222 100644
--- a/lib/x.sh
+++ b/lib/x.sh
@@ -1,3 +1,4 @@
 one
-two
+two!
+	tabbed
 three
@@ -10,2 +11 @@ func
-ten
 eleven
`

func TestParseDiffHunks(t *testing.T) {
	doc := parseDiff("lib/x.sh", sampleDiff)
	if len(doc.Hunks) != 2 {
		t.Fatalf("hunks = %d, want 2", len(doc.Hunks))
	}
	h0, h1 := doc.Hunks[0], doc.Hunks[1]
	if h0.Start != 4 || h0.End != 10 {
		t.Errorf("hunk 0 span = %d..%d, want 4..10", h0.Start, h0.End)
	}
	if h0.NewStart != 1 || h0.NewCount != 4 || h0.lineRange() != "L1-4" {
		t.Errorf("hunk 0 range = %d,%d (%s)", h0.NewStart, h0.NewCount, h0.lineRange())
	}
	if h1.Start != 10 || h1.End != len(doc.Lines) {
		t.Errorf("hunk 1 span = %d..%d", h1.Start, h1.End)
	}
	if h1.NewStart != 11 || h1.NewCount != 1 || h1.lineRange() != "L11" {
		t.Errorf("hunk 1 range = %d,%d (%s)", h1.NewStart, h1.NewCount, h1.lineRange())
	}
	if doc.Lines[8] != "+    tabbed" {
		t.Errorf("tab not expanded: %q", doc.Lines[8])
	}
	if doc.hunkAt(0) != -1 || doc.hunkAt(4) != 0 || doc.hunkAt(9) != 0 || doc.hunkAt(10) != 1 || doc.hunkAt(50) != 1 {
		t.Errorf("hunkAt mapping wrong: %d %d %d %d", doc.hunkAt(0), doc.hunkAt(4), doc.hunkAt(10), doc.hunkAt(50))
	}
	if got := doc.hunkText(1, 0); got != "@@ -10,2 +11 @@ func\n-ten\n eleven" {
		t.Errorf("hunkText = %q", got)
	}
	if got := doc.hunkText(0, 2); got != "@@ -1,3 +1,4 @@\n one\n…" {
		t.Errorf("capped hunkText = %q", got)
	}
	if doc.hunkText(5, 0) != "" {
		t.Error("out-of-range hunk should be empty")
	}
}

func TestParseDiffEmpty(t *testing.T) {
	doc := parseDiff("a", "  \n")
	if len(doc.Lines) != 0 || len(doc.Hunks) != 0 {
		t.Errorf("empty diff parsed to %d lines / %d hunks", len(doc.Lines), len(doc.Hunks))
	}
}

func TestTextHelpers(t *testing.T) {
	if got := truncRunes("héllo wörld", 5); got != "héll…" {
		t.Errorf("truncRunes = %q", got)
	}
	if got := truncRunes("abc", 3); got != "abc" {
		t.Errorf("truncRunes exact = %q", got)
	}
	if got := truncRunes("abc", 0); got != "" {
		t.Errorf("truncRunes zero = %q", got)
	}
	if got := tailPath("internal/sessions/review.go", 12); got != "…s/review.go" {
		t.Errorf("tailPath = %q", got)
	}
	if got := padRight("ab", 4); got != "ab  " {
		t.Errorf("padRight = %q", got)
	}
	if got := statLine(0, 0, 0); got != "no changes" {
		t.Errorf("statLine zero = %q", got)
	}
	if got := statLine(1, 2, 3); got != "1 file +2 −3" {
		t.Errorf("statLine one = %q", got)
	}
	if got := statLine(7, 212, 48); got != "7 files +212 −48" {
		t.Errorf("statLine many = %q", got)
	}
	if got := ago(100, 130); got != "30s ago" {
		t.Errorf("ago s = %q", got)
	}
	if got := ago(0, 7200); got != "2h ago" {
		t.Errorf("ago h = %q", got)
	}
}

func TestFitHints(t *testing.T) {
	parts := []string{"j/k file", "]/[ hunk", "↑↓ hunk", "c note", "q close"}
	// Everything fits: hints left, position right-aligned.
	got := fitHints(parts, "hunk 1/3", 60)
	if !strings.HasPrefix(got, "j/k file  ]/[ hunk  ↑↓ hunk  c note  q close") || !strings.HasSuffix(got, "hunk 1/3") || ansi.StringWidth(got) != 60 {
		t.Errorf("wide = %q (width %d)", got, ansi.StringWidth(got))
	}
	// Too narrow for all hints plus the position: trailing hints go, whole.
	got = fitHints(parts, "hunk 1/3", 40)
	if got != "j/k file  ]/[ hunk  ↑↓ hunk     hunk 1/3" {
		t.Errorf("narrow = %q", got)
	}
	// Narrower than the three navigation hints plus position: position goes.
	got = fitHints(parts, "hunk 1/3", 20)
	if got != "j/k file  ]/[ hunk" {
		t.Errorf("tight = %q", got)
	}
	// Styled input is measured by columns, not bytes.
	styled := []string{styleKey.Render("j/k") + styleDim.Render(" file"), styleKey.Render("q") + styleDim.Render(" close")}
	got = fitHints(styled, "", 17) // "j/k file  q close" is exactly 17 columns
	if ansi.StringWidth(got) != 17 {
		t.Errorf("styled = %q (width %d)", got, ansi.StringWidth(got))
	}
	if got := truncStyled(styleKey.Render("abcdef"), 4); ansi.StringWidth(got) != 4 || !strings.HasSuffix(ansi.Strip(got), "…") {
		t.Errorf("truncStyled = %q", got)
	}
}

func TestCheckpointRows(t *testing.T) {
	launch := sessions.Checkpoint{ID: "aaaaaaa1111", Kind: "launch", Branch: "main", Head: "bbbbbbb2222", Time: 1000}
	head := sessions.Checkpoint{ID: "ccccccc3333", Kind: "head", Branch: "", Head: "", Time: 1300}
	pick := sessions.Checkpoint{ID: "ddddddd4444", Kind: "commit", Branch: "", Head: "ddddddd4444", Anchor: "ddddddd4444", Time: 1200}
	big := sessions.ReviewStat{Files: 579, Added: 30396, Deleted: 7538, BaseTree: "t1"}
	same := sessions.ReviewStat{BaseTree: "t2"}
	// The baseline row is starred; the picked (shown) base gets >; others a
	// blank. The change column says what each base would show.
	if got := checkpointRow(launch, big, launch.ID, head.ID, 1360); got != "* aaaaaaa  launch  Δ579 +30396 −7538 bbbbbbb  6m ago   main" {
		t.Errorf("baseline row = %q", got)
	}
	if got := checkpointRow(head, same, launch.ID, head.ID, 1360); got != "> ccccccc  head    Δ0                -        1m ago   (detached)" {
		t.Errorf("shown row = %q", got)
	}
	if got := checkpointRow(pick, sessions.ReviewStat{}, launch.ID, "", 1360); got != "  ddddddd  commit  ?                 ddddddd  2m ago   -" {
		t.Errorf("typed commit row = %q", got)
	}
	if got := checkpointRow(head, same, launch.ID, "", 1360); got[0] != ' ' {
		t.Errorf("plain row mark = %q", got[:1])
	}
	// Header columns line up with a row whose cells fill their widths (column
	// positions in runes: Δ and − are multi-byte).
	h, row := checkpointHeader(), checkpointRow(launch, big, "", "", 1360)
	runeIndex := func(s, sub string) int { return len([]rune(s[:strings.Index(s, sub)])) }
	if runeIndex(h, "BRANCH") != runeIndex(row, "main") || runeIndex(h, "HEAD") != runeIndex(row, "bbbbbbb") {
		t.Errorf("header does not line up with rows:\n%q\n%q", h, row)
	}
}
