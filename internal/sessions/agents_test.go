package sessions

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestAgentManifestTypes(t *testing.T) {
	want := []string{"claude", "codex", "cursor", "pi"}
	if got := AgentTypes(); !reflect.DeepEqual(got, want) {
		t.Fatalf("AgentTypes = %v, want %v", got, want)
	}
	for _, typ := range want {
		spec, ok := Agent(typ)
		if !ok {
			t.Fatalf("Agent(%q) missing", typ)
		}
		for name, v := range map[string]string{
			"command": spec.Command, "prompt": spec.Prompt, "store": spec.Store,
			"title": spec.Title, "title_state": spec.TitleState,
			"turn_boundary": spec.TurnBoundary, "hook_family": spec.HookFamily,
			"preflight": spec.Preflight, "version_bin": spec.VersionBin,
		} {
			if v == "" {
				t.Errorf("%s.%s is empty", typ, name)
			}
		}
		if !spec.Restorable() {
			t.Errorf("%s: expected restorable", typ)
		}
	}
}

func TestAgentManifestFacts(t *testing.T) {
	cases := []struct {
		typ, command, prompt, store, hookFamily string
		resume                                 []string
		hasStore                               bool
	}{
		{"claude", "claude", "stdin", "claude", "claude", []string{"--resume", "x1"}, true},
		{"codex", "codex", "argv", "none", "claude", []string{"resume", "x1"}, false},
		{"cursor", "agent", "argv", "cursor", "cursor", []string{"--resume", "x1"}, true},
		{"pi", "pi", "argv", "pi", "pi", []string{"--session", "x1"}, true},
	}
	for _, c := range cases {
		spec, _ := Agent(c.typ)
		if spec.Command != c.command || spec.Prompt != c.prompt || spec.Store != c.store || spec.HookFamily != c.hookFamily {
			t.Errorf("%s: got %+v", c.typ, spec)
		}
		if got := spec.ResumeArgs("x1"); !reflect.DeepEqual(got, c.resume) {
			t.Errorf("%s: ResumeArgs = %v, want %v", c.typ, got, c.resume)
		}
		if spec.HasStore() != c.hasStore {
			t.Errorf("%s: HasStore = %v", c.typ, spec.HasStore())
		}
	}
}

func TestAgentAliasesAndUnknown(t *testing.T) {
	if got := NormalizeAgent("cursor-agent"); got != "cursor" {
		t.Errorf("NormalizeAgent(cursor-agent) = %q", got)
	}
	if spec, ok := Agent("cursor-agent"); !ok || spec.Type != "cursor" {
		t.Errorf("Agent(cursor-agent) = %+v, %v", spec, ok)
	}
	if got := NormalizeAgent("bogus"); got != "bogus" {
		t.Errorf("NormalizeAgent(bogus) = %q", got)
	}
	if _, ok := Agent("bogus"); ok {
		t.Error("Agent(bogus) should be unknown")
	}
	if isRestorableAgent("bogus") || isRestorableAgent("") {
		t.Error("unknown / empty agent must not be restorable")
	}
	if spec := agentSpec(""); spec.Type != "claude" {
		t.Errorf("agentSpec(\"\") = %+v, want claude", spec)
	}
	if spec := agentSpec("bogus"); spec.HasStore() || spec.Restorable() || spec.TitleState != "" {
		t.Errorf("agentSpec(bogus) must be the zero spec, got %+v", spec)
	}
}

func TestAgentManifestParser(t *testing.T) {
	specs, aliases, order := parseAgentManifest("# c\n\nfoo.command  f oo \nfoo.aliases a b\nfoo.resume -\nfoo.newfield x\nbar.command bar\nnoise\n")
	if !reflect.DeepEqual(order, []string{"foo", "bar"}) {
		t.Fatalf("order = %v", order)
	}
	if specs["foo"].Command != "f oo" || specs["foo"].Resume != "" || len(specs["foo"].Aliases) != 2 {
		t.Errorf("foo = %+v", specs["foo"])
	}
	if aliases["a"] != "foo" || aliases["b"] != "foo" {
		t.Errorf("aliases = %v", aliases)
	}
	if _, ok := specs["noise"]; ok {
		t.Error("a line without a dot must not declare a type")
	}
}

// The bash side reads lib/agents.manifest; it must be this package's file.
func TestAgentManifestSharedWithBash(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "..", "lib", "agents.manifest"))
	if err != nil {
		t.Fatalf("lib/agents.manifest: %v", err)
	}
	if string(b) != agentManifest {
		t.Fatal("lib/agents.manifest differs from the embedded internal/sessions/agents.manifest")
	}
}

// FirstMessage and JSONLExists dispatch on the store layout, not the name.
func TestStoreDispatch(t *testing.T) {
	if FirstMessage("codex", t.TempDir(), "abc", "") != "" {
		t.Error("codex has no store; FirstMessage must be empty")
	}
	if FirstMessage("bogus", t.TempDir(), "abc", "") != "" {
		t.Error("unknown agent: FirstMessage must be empty")
	}
	e := Env{Home: t.TempDir()}
	if !e.JSONLExists("/x", "abc-123", "codex", "") {
		t.Error("codex: a well-formed id passes the existence check")
	}
	if e.JSONLExists("/x", "abc-123", "bogus", "") {
		t.Error("unknown agent: nothing exists")
	}
	if e.JSONLExists("/x", "abc-123", "claude", "") {
		t.Error("claude: missing transcript must not exist")
	}
}
