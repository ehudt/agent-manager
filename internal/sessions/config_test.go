package sessions

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeConfig(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "config.json"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestLoadConfig(t *testing.T) {
	dir := writeConfig(t, `{
		"default_agent": "pi",
		"dir_provider": "wp",
		"presets": {
			"review": {"agent": "claude", "directory": "@", "args": ["--model", "opus"]},
			"scratch": {"agent": "pi", "directory": "/tmp/tools", "task": "poke", "shell": true},
			"legacy": {"agent": "claude", "workspace": true, "branch": "review-48351"},
			"legacy2": {"workspace": true}
		}
	}`)
	cfg := LoadConfig(dir)
	if cfg.DefaultAgent != "pi" || cfg.DirProvider != "wp" {
		t.Errorf("DefaultAgent=%q DirProvider=%q", cfg.DefaultAgent, cfg.DirProvider)
	}
	if got := strings.Join(cfg.PresetNames(), ","); got != "legacy,legacy2,review,scratch" {
		t.Errorf("PresetNames = %q", got)
	}
	if p := cfg.Presets["review"]; p.Directory != "@" || len(p.Args) != 2 || p.Args[1] != "opus" {
		t.Errorf("review = %+v", p)
	}
	// A pre-0.40 "task" key is ignored, not an error.
	if p := cfg.Presets["scratch"]; !p.Shell || p.Directory != "/tmp/tools" {
		t.Errorf("scratch = %+v", p)
	}
	if p := cfg.Presets["legacy"]; p.Directory != "@review-48351" {
		t.Errorf("legacy directory = %q, want @review-48351", p.Directory)
	}
	if p := cfg.Presets["legacy2"]; p.Directory != "@" {
		t.Errorf("legacy2 directory = %q, want @", p.Directory)
	}

	// Missing or broken files are an empty config.
	if cfg := LoadConfig(t.TempDir()); cfg.DefaultAgent != "" || cfg.Presets != nil {
		t.Errorf("missing file: %+v", cfg)
	}
	if cfg := LoadConfig(writeConfig(t, "{not json")); cfg.DefaultAgent != "" || cfg.Presets != nil {
		t.Errorf("bad json: %+v", cfg)
	}
}

func TestConfigDefaults(t *testing.T) {
	t.Setenv("AM_DEFAULT_AGENT", "")
	t.Setenv("AM_DIR_PROVIDER", "")
	t.Setenv("AM_DIR_SUGGEST_TIMEOUT", "")
	var cfg Config
	if got := cfg.DefaultAgentType(); got != "claude" {
		t.Errorf("DefaultAgentType = %q, want claude", got)
	}
	cfg.DefaultAgent = "cursor-agent"
	if got := cfg.DefaultAgentType(); got != "cursor" {
		t.Errorf("DefaultAgentType alias = %q, want cursor", got)
	}
	cfg.DefaultAgent = "null"
	if got := cfg.DefaultAgentType(); got != "claude" {
		t.Errorf("DefaultAgentType null = %q, want claude", got)
	}
	t.Setenv("AM_DEFAULT_AGENT", "pi")
	if got := cfg.DefaultAgentType(); got != "pi" {
		t.Errorf("AM_DEFAULT_AGENT ignored: %q", got)
	}

	if cfg.DirProviderCmd() != "" {
		t.Errorf("DirProviderCmd = %q, want empty", cfg.DirProviderCmd())
	}
	cfg.DirProvider = "wp"
	if cfg.DirProviderCmd() != "wp" {
		t.Errorf("DirProviderCmd = %q", cfg.DirProviderCmd())
	}
	t.Setenv("AM_DIR_PROVIDER", "other")
	if cfg.DirProviderCmd() != "other" {
		t.Errorf("AM_DIR_PROVIDER ignored: %q", cfg.DirProviderCmd())
	}

	if d := DirSuggestTimeout(); d != 300*time.Millisecond {
		t.Errorf("DirSuggestTimeout = %v, want 300ms", d)
	}
	t.Setenv("AM_DIR_SUGGEST_TIMEOUT", "1.5")
	if d := DirSuggestTimeout(); d != 1500*time.Millisecond {
		t.Errorf("DirSuggestTimeout 1.5 = %v", d)
	}
	t.Setenv("AM_DIR_SUGGEST_TIMEOUT", "junk")
	if d := DirSuggestTimeout(); d != 300*time.Millisecond {
		t.Errorf("DirSuggestTimeout junk = %v, want the default", d)
	}
}
