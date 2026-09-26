package main

import "testing"

func TestIsMuseCommand(t *testing.T) {
	tests := []struct {
		command string
		want    bool
	}{
		{"muse resume session-id", true},
		{"/opt/facebook/bin/muse exec prompt mentioning codex", true},
		{"/usr/local/bin/muse_code/muse.real exec task", true},
		{"codex --model muse-spark-1.3-internal", false},
		{"python /tmp/muse_helper.py", false},
		{"/usr/local/bin/muse_code/bin/fast_mux /tmp/config.md", false},
	}
	for _, tt := range tests {
		if got := isMuseCommand(tt.command); got != tt.want {
			t.Errorf("isMuseCommand(%q) = %v, want %v", tt.command, got, tt.want)
		}
	}
}
