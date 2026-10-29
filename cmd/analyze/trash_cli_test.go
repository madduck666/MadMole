//go:build darwin

package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func decodeTrashReport(t *testing.T, out []byte) trashReport {
	t.Helper()
	var report trashReport
	if err := json.Unmarshal(out, &report); err != nil {
		t.Fatalf("output is not a trash report: %v\n%s", err, out)
	}
	return report
}

func TestTrashModeRefusesRelativeAndProtectedPaths(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	var stdout bytes.Buffer
	code := runTrashMode([]string{"relative/file", "/System/Library"}, &stdout)

	if code != 2 {
		t.Fatalf("exit code = %d, want 2 when every path is refused", code)
	}
	report := decodeTrashReport(t, stdout.Bytes())
	if report.Moved != 0 || report.Failed != 2 {
		t.Fatalf("moved=%d failed=%d, want 0 and 2: %+v", report.Moved, report.Failed, report)
	}
	for _, result := range report.Results {
		if result.OK || result.Error == "" {
			t.Errorf("result %+v, want a refusal with a reason", result)
		}
	}
	if _, err := os.Stat("/System/Library"); err != nil {
		t.Fatalf("/System/Library must survive a refused trash request: %v", err)
	}
}

func TestTrashModeLogsRefusalsInOperationsLog(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("MO_NO_OPLOG", "")

	var stdout bytes.Buffer
	runTrashMode([]string{"/System/Library"}, &stdout)

	data, err := os.ReadFile(filepath.Join(home, "Library", "Logs", "mole", "operations.log"))
	if err != nil {
		t.Fatalf("operations.log not written: %v", err)
	}
	log := string(data)
	if !strings.Contains(log, "[analyze run=") || !strings.Contains(log, "FAILED /System/Library (protected)") {
		t.Errorf("operations.log = %q, want an analyze session with a protected FAILED row", log)
	}
}

func TestTrashModeNeedsAPath(t *testing.T) {
	var stdout bytes.Buffer
	if code := runTrashMode(nil, &stdout); code != 1 {
		t.Fatalf("exit code = %d, want 1 with no paths", code)
	}
	if stdout.Len() != 0 {
		t.Errorf("stdout = %q, want nothing when no path was given", stdout.String())
	}
}
