package cmd

import (
	"os"
	"path/filepath"
	"testing"

	commonpb "github.com/sycophant-md/sycophant/cmd/syco/internal/proto/sycophant/common/v1"
)

func TestLoadCursorMissingOrBadIsZero(t *testing.T) {
	dir := t.TempDir()
	seq := loadCursor(dir, "ws-1")
	if seq == nil {
		t.Fatal("expected non-nil pointer")
	}
	if *seq != 0 {
		t.Fatalf("expected 0 for missing cursor, got %d", *seq)
	}

	// Unparseable content falls back to zero the same way.
	cursorsDir := filepath.Join(dir, "cursors")
	os.MkdirAll(cursorsDir, 0o755)
	os.WriteFile(filepath.Join(cursorsDir, "ws-1.seq"), []byte("not-a-number\n"), 0o644)

	seq = loadCursor(dir, "ws-1")
	if seq == nil {
		t.Fatal("expected non-nil pointer")
	}
	if *seq != 0 {
		t.Fatalf("expected 0 for bad cursor, got %d", *seq)
	}
}

func TestSaveCursorZeroNoOp(t *testing.T) {
	zero := uint64(0)
	for name, seq := range map[string]*uint64{"zero": &zero, "nil": nil} {
		dir := t.TempDir()
		saveCursor(dir, "ws-1", seq)
		// Should not create the file.
		p := cursorPath(dir, "ws-1")
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Fatalf("expected no cursor file for %s seq, but file exists", name)
		}
	}
}

func TestDedup(t *testing.T) {
	cases := []struct {
		name     string
		frameSeq *uint64 // nil: no workspace_seq on the frame
		wantSkip bool
		wantLast uint64
	}{
		{"old seq skipped", u64(5), true, 10},
		{"equal seq skipped", u64(10), true, 10},
		{"new seq accepted and persisted", u64(11), false, 11},
		{"nil seq not skipped", nil, false, 10},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			v := uint64(10)
			rs := &recvState{
				cfgDir:    dir,
				workspace: "ws-1",
				lastSeq:   &v,
			}

			frame := makeFrame(0)
			frame.WorkspaceSeq = tc.frameSeq
			if got := rs.dedup(frame); got != tc.wantSkip {
				t.Fatalf("dedup = %v, want %v", got, tc.wantSkip)
			}
			if *rs.lastSeq != tc.wantLast {
				t.Fatalf("expected lastSeq %d, got %d", tc.wantLast, *rs.lastSeq)
			}
			if !tc.wantSkip && tc.frameSeq != nil {
				// Verify cursor was persisted (t.TempDir has no cursors/
				// subdir, so this also covers saveCursor creating it).
				loaded := loadCursor(dir, "ws-1")
				if *loaded != tc.wantLast {
					t.Fatalf("expected persisted cursor %d, got %d", tc.wantLast, *loaded)
				}
			}
		})
	}
}

func u64(v uint64) *uint64 { return &v }

// makeFrame builds a ChannelOutbound with the given workspace_seq for testing.
func makeFrame(seq uint64) *commonpb.ChannelOutbound {
	s := seq
	return &commonpb.ChannelOutbound{
		WorkspaceSeq: &s,
		Command: &commonpb.ChannelOutbound_StreamItem{
			StreamItem: &commonpb.StreamItem{},
		},
	}
}
