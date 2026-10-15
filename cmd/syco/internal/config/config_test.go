package config_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/sycophant-md/sycophant/cmd/syco/internal/config"
)

// AC 3: Missing server exits non-zero with an error.
// The config resolver must return an error when no server is set in the active
// profile and SYCO_SERVER is unset.
func TestResolveConfig_MissingServer_ReturnsError(t *testing.T) {
	dir := t.TempDir()
	cfgFile := filepath.Join(dir, "config.toml")
	os.WriteFile(cfgFile, []byte(`[default]
profile = "dev"

[profile.dev]
workspace = "hello-world"
`), 0644)
	os.Unsetenv("SYCO_SERVER")

	_, err := config.LoadProfile(dir, "", "")
	if err == nil {
		t.Fatal("expected error for missing server, got nil")
	}
	if !strings.Contains(err.Error(), "server") {
		t.Fatalf("error should mention 'server', got: %s", err)
	}
}

// AC 7: `syco session` prints active profile name and resolved values.
// The config resolver must return the active profile name and its server/workspace.
func TestResolveConfig_ReturnsProfileNameAndValues(t *testing.T) {
	dir := t.TempDir()
	cfgFile := filepath.Join(dir, "config.toml")
	os.WriteFile(cfgFile, []byte(`[default]
profile = "staging"

[profile.staging]
server = "relay.staging.ts.local:9090"
workspace = "my-workspace"
`), 0644)

	p, err := config.LoadProfile(dir, "", "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if p.Name != "staging" {
		t.Errorf("expected profile name 'staging', got %q", p.Name)
	}
	if p.Server != "relay.staging.ts.local:9090" {
		t.Errorf("expected server, got %q", p.Server)
	}
	if p.Workspace != "my-workspace" {
		t.Errorf("expected workspace, got %q", p.Workspace)
	}
}

// AC 8: `syco session workspace <ws>` writes workspace to active profile.
func TestSetWorkspace_WritesConfig(t *testing.T) {
	dir := t.TempDir()
	cfgFile := filepath.Join(dir, "config.toml")
	os.WriteFile(cfgFile, []byte(`[default]
profile = "dev"

[profile.dev]
server = "relay.dev:9090"
`), 0644)

	err := config.SetWorkspace(dir, "", "", "new-workspace")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	p, err := config.LoadProfile(dir, "", "")
	if err != nil {
		t.Fatalf("unexpected error loading after set: %v", err)
	}
	if p.Workspace != "new-workspace" {
		t.Errorf("expected workspace 'new-workspace', got %q", p.Workspace)
	}
}

// AC 9: `syco profile list` prints all named profiles.
func TestListProfiles_ReturnsAllNames(t *testing.T) {
	dir := t.TempDir()
	cfgFile := filepath.Join(dir, "config.toml")
	os.WriteFile(cfgFile, []byte(`[default]
profile = "dev"

[profile.dev]
server = "a:1"

[profile.staging]
server = "b:2"

[profile.prod]
server = "c:3"
`), 0644)

	names, err := config.ListProfiles(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(names) != 3 {
		t.Fatalf("expected 3 profiles, got %d: %v", len(names), names)
	}
	want := map[string]bool{"dev": true, "staging": true, "prod": true}
	for _, n := range names {
		if !want[n] {
			t.Errorf("unexpected profile %q", n)
		}
	}
}

// AC 10: `syco profile use <name>` sets [default].profile.
func TestUseProfile_SetsDefault(t *testing.T) {
	dir := t.TempDir()
	cfgFile := filepath.Join(dir, "config.toml")
	os.WriteFile(cfgFile, []byte(`[default]
profile = "dev"

[profile.dev]
server = "a:1"

[profile.staging]
server = "b:2"
`), 0644)

	err := config.UseProfile(dir, "staging")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	p, err := config.LoadProfile(dir, "", "")
	if err != nil {
		t.Fatalf("unexpected error loading: %v", err)
	}
	if p.Name != "staging" {
		t.Errorf("expected active profile 'staging', got %q", p.Name)
	}
}

// AC 6: Expired token → "session expired, run syco login", exit non-zero.
func TestLoadToken_Expired_ReturnsError(t *testing.T) {
	dir := t.TempDir()
	// Create a credentials.toml with an expired JWT.
	// The JWT payload has exp in the past. This is a minimal unsigned JWT
	// (header.payload.signature) with exp = 0 (1970-01-01).
	// Header: {"alg":"none","typ":"JWT"}
	// Payload: {"sub":"user@test","exp":0}
	expiredToken := "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJ1c2VyQHRlc3QiLCJleHAiOjB9."
	credFile := filepath.Join(dir, "credentials.toml")
	os.WriteFile(credFile, []byte(`[dev]
token = "`+expiredToken+`"
`), 0644)

	_, err := config.LoadToken(dir, "dev")
	if err == nil {
		t.Fatal("expected error for expired token, got nil")
	}
	if !strings.Contains(err.Error(), "session expired") {
		t.Fatalf("error should mention 'session expired', got: %s", err)
	}
}

// AC 4: `syco logout` deletes token from active profile in credentials.toml.
func TestDeleteToken_RemovesEntry(t *testing.T) {
	dir := t.TempDir()
	credFile := filepath.Join(dir, "credentials.toml")
	// A token with exp far in the future.
	validToken := "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJ1c2VyQHRlc3QiLCJleHAiOjk5OTk5OTk5OTl9."
	os.WriteFile(credFile, []byte(`[dev]
token = "`+validToken+`"
`), 0644)

	err := config.DeleteToken(dir, "dev")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// After deletion, loading should fail (no token).
	_, err = config.LoadToken(dir, "dev")
	if err == nil {
		t.Fatal("expected error after deleting token, got nil")
	}
}

// AC 12: --continue looks up last conversation for current workspace from history.
func TestHistoryLastForWorkspace(t *testing.T) {
	dir := t.TempDir()
	histFile := filepath.Join(dir, "history")
	now := time.Now().UTC().Format(time.RFC3339)
	os.WriteFile(histFile, []byte(
		"aaaa-bbbb\tworkspace-a\t2026-01-01T00:00:00Z\n"+
			"cccc-dddd\tworkspace-b\t2026-01-02T00:00:00Z\n"+
			"eeee-ffff\tworkspace-a\t"+now+"\n",
	), 0644)

	entry, err := config.HistoryLastForWorkspace(dir, "workspace-a")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if entry.ConversationID != "eeee-ffff" {
		t.Errorf("expected conversation 'eeee-ffff', got %q", entry.ConversationID)
	}
}

// AC 12 (no prior conversation): --continue with no history exits non-zero.
func TestHistoryLastForWorkspace_Empty_ReturnsError(t *testing.T) {
	dir := t.TempDir()
	histFile := filepath.Join(dir, "history")
	os.WriteFile(histFile, []byte(""), 0644)

	_, err := config.HistoryLastForWorkspace(dir, "workspace-a")
	if err == nil {
		t.Fatal("expected error for empty history, got nil")
	}
}

// AC 14: --grant toolset/grant parses into (toolset, grant) pair.
func TestParseGrant(t *testing.T) {
	toolset, grant, err := config.ParseGrant("ssh-credentials/demo-key")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if toolset != "ssh-credentials" {
		t.Errorf("expected toolset 'ssh-credentials', got %q", toolset)
	}
	if grant != "demo-key" {
		t.Errorf("expected grant 'demo-key', got %q", grant)
	}
}

// AC 14: invalid grant format (no slash) returns error.
func TestParseGrant_Invalid(t *testing.T) {
	_, _, err := config.ParseGrant("invalid-no-slash")
	if err == nil {
		t.Fatal("expected error for invalid grant format, got nil")
	}
}
