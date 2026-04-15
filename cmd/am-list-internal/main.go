package main

import (
	"fmt"

	"github.com/ehud-tamir/agent-manager/internal/sessions"
)

func main() {
	entries := sessions.LoadEntries()
	for _, e := range entries {
		fmt.Println(e.Name + "|" + e.Display)
	}
}
