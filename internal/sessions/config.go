package sessions

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Config is the part of $AM_DIR/config.json the Go side reads: the default
// agent, the directory provider, and the launch presets. The bash side
// (lib/config.sh, lib/presets.sh) owns the file and every write; this is a
// tolerant reader — a missing or unparsable file is an empty Config, and the
// callers fall back to the same defaults the bash readers use.
type Config struct {
	DefaultAgent string
	DirProvider  string
	Presets      map[string]Preset
}

// Preset is one saved `am new` input set (lib/presets.sh). Directory is a
// path or a `@spec`; a pre-0.24 preset (workspace + branch) reads back as
// `@<branch>`, as am_preset_field does. A "task" key saved before 0.40 is
// ignored.
type Preset struct {
	Agent     string
	Directory string
	Shell     bool
	Args      []string
}

// LoadConfig reads config.json under amDir.
func LoadConfig(amDir string) Config {
	var cfg Config
	data, err := os.ReadFile(filepath.Join(amDir, "config.json"))
	if err != nil {
		return cfg
	}
	var raw struct {
		DefaultAgent string `json:"default_agent"`
		DirProvider  string `json:"dir_provider"`
		Presets      map[string]struct {
			Agent     string   `json:"agent"`
			Directory string   `json:"directory"`
			Shell     bool     `json:"shell"`
			Args      []string `json:"args"`
			Workspace bool     `json:"workspace"`
			Branch    string   `json:"branch"`
		} `json:"presets"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return cfg
	}
	cfg.DefaultAgent = raw.DefaultAgent
	cfg.DirProvider = raw.DirProvider
	if len(raw.Presets) > 0 {
		cfg.Presets = make(map[string]Preset, len(raw.Presets))
		for name, p := range raw.Presets {
			dir := p.Directory
			if dir == "" && p.Workspace {
				dir = "@" + p.Branch
			}
			cfg.Presets[name] = Preset{
				Agent:     p.Agent,
				Directory: dir,
				Shell:     p.Shell,
				Args:      append([]string(nil), p.Args...),
			}
		}
	}
	return cfg
}

// PresetNames lists the presets sorted by name (am_preset_names).
func (c Config) PresetNames() []string {
	names := make([]string, 0, len(c.Presets))
	for n := range c.Presets {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

// DefaultAgentType is am_default_agent: $AM_DEFAULT_AGENT, else the
// default_agent key, else claude; aliases normalized.
func (c Config) DefaultAgentType() string {
	v := os.Getenv("AM_DEFAULT_AGENT")
	if v == "" {
		v = c.DefaultAgent
	}
	if v == "" || v == "null" {
		v = "claude"
	}
	return NormalizeAgent(v)
}

// DirProviderCmd is am_dir_provider: $AM_DIR_PROVIDER, else the
// dir_provider key. Empty disables `@spec` directories.
func (c Config) DirProviderCmd() string {
	if v := os.Getenv("AM_DIR_PROVIDER"); v != "" {
		return v
	}
	return c.DirProvider
}

// DirSuggestTimeout is am_dir_suggest_timeout: $AM_DIR_SUGGEST_TIMEOUT in
// seconds (fractional allowed), default 0.3s.
func DirSuggestTimeout() time.Duration {
	if v := strings.TrimSpace(os.Getenv("AM_DIR_SUGGEST_TIMEOUT")); v != "" {
		if secs, err := strconv.ParseFloat(v, 64); err == nil && secs > 0 {
			return time.Duration(secs * float64(time.Second))
		}
	}
	return 300 * time.Millisecond
}
