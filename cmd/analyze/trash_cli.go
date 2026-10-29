//go:build darwin

package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// trashResult is one row of `--trash` output. A desktop front end reads it to
// tell the user which selections moved and which were refused, without
// re-implementing analyze's protection list or its audit trail.
type trashResult struct {
	Path  string `json:"path"`
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

type trashReport struct {
	Results    []trashResult `json:"results"`
	Moved      int           `json:"moved"`
	Failed     int           `json:"failed"`
	LogWarning string        `json:"log_warning,omitempty"`
}

// runTrashMode moves each path to the Trash through the same funnel the TUI
// uses: validateTrashTarget and the protected-root checks inside moveToTrash,
// and one operations.log session with a deletions.log row per item. Relative
// paths are refused rather than resolved against an unknown working directory.
func runTrashMode(paths []string, stdout io.Writer) int {
	report := trashReport{Results: []trashResult{}}
	if len(paths) == 0 {
		_, _ = fmt.Fprintln(os.Stderr, "mo analyze --trash needs at least one absolute path")
		return 1
	}

	sizes := make(map[string]int64, len(paths))
	var accepted []string
	for _, path := range paths {
		if !filepath.IsAbs(path) {
			report.Results = append(report.Results, trashResult{Path: path, Error: "path must be absolute"})
			report.Failed++
			continue
		}
		if info, err := os.Lstat(path); err == nil && info.Mode().IsRegular() {
			sizes[path] = info.Size()
		}
		accepted = append(accepted, path)
	}

	// Deeper paths first, as the TUI does, so a parent move never strands a
	// selected child.
	sort.SliceStable(accepted, func(i, j int) bool {
		return strings.Count(accepted[i], string(filepath.Separator)) > strings.Count(accepted[j], string(filepath.Separator))
	})

	if len(accepted) > 0 {
		audit := newDeleteAudit(sizes)
		audit.begin()
		var moved []string
		for _, path := range accepted {
			_, err := trashPathWithProgress(path, nil)
			audit.record(path, err)
			if err != nil {
				report.Results = append(report.Results, trashResult{Path: path, Error: err.Error()})
				report.Failed++
				continue
			}
			report.Results = append(report.Results, trashResult{Path: path, OK: true})
			report.Moved++
			moved = append(moved, path)
		}
		audit.end()
		// The next --json scan of an ancestor must not reuse totals that still
		// count the moved bytes.
		if len(moved) > 0 {
			invalidateCacheAncestry(moved)
		}
		report.LogWarning = audit.warning()
	}

	encoder := json.NewEncoder(stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(report); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "failed to encode JSON: %v\n", err)
		return 1
	}
	if report.Failed > 0 {
		return 2
	}
	return 0
}
