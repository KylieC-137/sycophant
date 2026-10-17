package cmd

import (
	"os"
	"path/filepath"
	"testing"

	commonpb "github.com/sycophant-md/sycophant/cmd/syco/internal/proto/sycophant/common/v1"
)

func TestLoadCursorMissing(t *testing.T) {
	dir := t.TempDir()
	seq := loadCursor(dir, "ws-1")
	if seq == nil {
		t.Fatal("expected non-nil pointer")
	}
	if *seq != 0 {
		t.Fatalf("expected 0 for missing cursor, got %d", *seq)
	}
}

func TestSaveAndLoadCursor(t *testing.T) {
	dir := t.TempDir()
	v := uint64(42)
	saveCursor(dir, "ws-1", &v)

	got := loadCursor(dir, "ws-1")
	if got == nil {
		t.Fatal("expected non-nil pointer")
	}
	if *got != 42 {
		t.Fatalf("expected 42, got %d", *got)
	}
}

func TestSaveCursorZeroNoOp(t *testing.T) {
	dir := t.TempDir()
	v := uint64(0)
	saveCursor(dir, "ws-1", &v)
	// Should not create the file.
	p := cursorPath(dir, "ws-1")
	if _, err := os.Stat(p); !os.IsNotExist(err) {
		t.Fatalf("expected no cursor file for seq=0, but file exists")
	}
}

func TestSaveCursorNilNoOp(t *testing.T) {
	dir := t.TempDir()
	saveCursor(dir, "ws-1", nil)
	p := cursorPath(dir, "ws-1")
	if _, err := os.Stat(p); !os.IsNotExist(err) {
		t.Fatalf("expected no cursor file for nil, but file exists")
	}
}

func TestCursorPath(t *testing.T) {
	p := cursorPath("/home/user/.config/syco", "my-workspace")
	want := filepath.Join("/home/user/.config/syco", "cursors", "my-workspace.seq")
	if p != want {
		t.Fatalf("cursorPath = %q, want %q", p, want)
	}
}

func TestLoadCursorBadContent(t *testing.T) {
	dir := t.TempDir()
	cursorsDir := filepath.Join(dir, "cursors")
	os.MkdirAll(cursorsDir, 0o755)
	os.WriteFile(filepath.Join(cursorsDir, "ws-1.seq"), []byte("not-a-number\n"), 0o644)

	seq := loadCursor(dir, "ws-1")
	if seq == nil {
		t.Fatal("expected non-nil pointer")
	}
	if *seq != 0 {
		t.Fatalf("expected 0 for bad cursor, got %d", *seq)
	}
}

func TestDedupSkipOld(t *testing.T) {
	v := uint64(10)
	rs := &recvState{
		cfgDir:    t.TempDir(),
		workspace: "ws-1",
		lastSeq:   &v,
	}

	frame := makeFrame(5)
	if !rs.dedup(frame) {
		t.Fatal("expected dedup to skip frame with seq <= lastSeq")
	}
	if *rs.lastSeq != 10 {
		t.Fatalf("expected lastSeq unchanged at 10, got %d", *rs.lastSeq)
	}
}

func TestDedupSkipEqual(t *testing.T) {
	v := uint64(10)
	rs := &recvState{
		cfgDir:    t.TempDir(),
		workspace: "ws-1",
		lastSeq:   &v,
	}

	frame := makeFrame(10)
	if !rs.dedup(frame) {
		t.Fatal("expected dedup to skip frame with seq == lastSeq")
	}
}

func TestDedupAcceptNew(t *testing.T) {
	dir := t.TempDir()
	v := uint64(10)
	rs := &recvState{
		cfgDir:    dir,
		workspace: "ws-1",
		lastSeq:   &v,
	}

	frame := makeFrame(11)
	if rs.dedup(frame) {
		t.Fatal("expected dedup to accept frame with seq > lastSeq")
	}
	if *rs.lastSeq != 11 {
		t.Fatalf("expected lastSeq updated to 11, got %d", *rs.lastSeq)
	}
	// Verify cursor was persisted.
	loaded := loadCursor(dir, "ws-1")
	if *loaded != 11 {
		t.Fatalf("expected persisted cursor 11, got %d", *loaded)
	}
}

func TestDedupNilSeqNotSkipped(t *testing.T) {
	v := uint64(10)
	rs := &recvState{
		cfgDir:    t.TempDir(),
		workspace: "ws-1",
		lastSeq:   &v,
	}

	frame := makeFrame(0)
	frame.WorkspaceSeq = nil // no seq on frame
	if rs.dedup(frame) {
		t.Fatal("expected dedup to NOT skip frame with nil workspace_seq")
	}
	if *rs.lastSeq != 10 {
		t.Fatalf("expected lastSeq unchanged at 10, got %d", *rs.lastSeq)
	}
}

func TestSaveCursorCreatesDir(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "nested", "config")
	v := uint64(99)
	saveCursor(dir, "ws-1", &v)

	loaded := loadCursor(dir, "ws-1")
	if *loaded != 99 {
		t.Fatalf("expected 99, got %d", *loaded)
	}
}

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
