package sessions

import (
	_ "embed"
	"strings"
)

// Agent adapter manifest. agents.manifest (this directory; lib/agents.manifest
// is a symlink to it for bash) holds every agent-specific fact in one place:
// launch command, aliases, prompt delivery, resume args, transcript store
// layout, title parser, title→state signal, turn-boundary reliability, hook
// family, restore preflight, version binary, live lab. This file parses it
// once at init; the rest of the package branches on AgentSpec fields, never on
// the agent name.

//go:embed agents.manifest
var agentManifest string

// AgentSpec is one agent's block of the manifest. Field semantics are
// documented in agents.manifest; a `-` value in the file parses to "".
type AgentSpec struct {
	Type         string
	Command      string
	Aliases      []string
	Prompt       string // stdin | argv
	Resume       string // args template with {id}; "" = not restorable
	Store        string // claude | cursor | pi | none
	Title        string // claude | cursor | pi
	TitleState   string // glyph | suffix | none
	TurnBoundary string // reliable | gated
	HookFamily   string // claude | cursor | pi
	Preflight    string // transcript | id
	VersionBin   string
	Lab          string
}

// Restorable reports whether the manifest gives the agent a resume form.
func (a AgentSpec) Restorable() bool { return a.Resume != "" }

// HasStore reports whether the agent keeps transcripts in a layout am can
// address (dir + id → file): the first-message title fallback and the
// transcript preflight both need it.
func (a AgentSpec) HasStore() bool { return a.Store != "" && a.Store != "none" }

// ResumeArgs expands the resume template for a conversation id.
func (a AgentSpec) ResumeArgs(id string) []string {
	if a.Resume == "" {
		return nil
	}
	fields := strings.Fields(a.Resume)
	for i, f := range fields {
		fields[i] = strings.ReplaceAll(f, "{id}", id)
	}
	return fields
}

var (
	agentSpecs   map[string]AgentSpec
	agentAliases map[string]string
	agentOrder   []string
)

func init() {
	agentSpecs, agentAliases, agentOrder = parseAgentManifest(agentManifest)
}

// parseAgentManifest reads `<type>.<field> <value>` lines. Types appear in
// the order of their first line; unknown fields are ignored so an older
// binary tolerates a newer manifest.
func parseAgentManifest(text string) (map[string]AgentSpec, map[string]string, []string) {
	specs := map[string]AgentSpec{}
	aliases := map[string]string{}
	var order []string
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, _ := strings.Cut(line, " ")
		value = strings.TrimSpace(value)
		if value == "-" {
			value = ""
		}
		typ, field, ok := strings.Cut(key, ".")
		if !ok || typ == "" {
			continue
		}
		spec, seen := specs[typ]
		if !seen {
			spec.Type = typ
			order = append(order, typ)
		}
		switch field {
		case "command":
			spec.Command = value
		case "aliases":
			spec.Aliases = strings.Fields(value)
			for _, a := range spec.Aliases {
				aliases[a] = typ
			}
		case "prompt":
			spec.Prompt = value
		case "resume":
			spec.Resume = value
		case "store":
			spec.Store = value
		case "title":
			spec.Title = value
		case "title_state":
			spec.TitleState = value
		case "turn_boundary":
			spec.TurnBoundary = value
		case "hook_family":
			spec.HookFamily = value
		case "preflight":
			spec.Preflight = value
		case "version_bin":
			spec.VersionBin = value
		case "lab":
			spec.Lab = value
		}
		specs[typ] = spec
	}
	return specs, aliases, order
}

// AgentTypes lists the canonical agent types in manifest order.
func AgentTypes() []string { return append([]string(nil), agentOrder...) }

// NormalizeAgent maps an alias to its canonical type; unknown names pass
// through unchanged (the caller decides whether that is an error).
func NormalizeAgent(name string) string {
	if canon, ok := agentAliases[name]; ok {
		return canon
	}
	return name
}

// Agent looks up a type (or alias). ok is false for names not in the
// manifest; the zero AgentSpec then reports no store, no resume, no title
// signal, which is the conservative behaviour for an unknown agent.
func Agent(name string) (spec AgentSpec, ok bool) {
	spec, ok = agentSpecs[NormalizeAgent(name)]
	return
}

// agentSpec is Agent for callers that treat an unknown or empty type as
// Claude, the registry default before agent_type was recorded.
func agentSpec(name string) AgentSpec {
	if name == "" {
		name = "claude"
	}
	spec, _ := Agent(name)
	return spec
}
