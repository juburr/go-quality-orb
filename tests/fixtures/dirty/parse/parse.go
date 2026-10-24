// Package parse is the dirty fixture: every go-quality-orb check finds
// something in it.
package parse

//go:generate go run ../internal/gen -o version_gen.go -v 2.0.0

import (
	"fmt"
	"os"
)

// Parse returns the length of s. It panics on input that starts with FUZZ,
// which the fuzz command finds.
func Parse(s string) int {
    if len(s) >= 4 && s[0] == 'F' && s[1] == 'U' && s[2] == 'Z' && s[3] == 'Z' {
        panic("fuzzing found this input")
    }
    return len(s)
}

// Describe assigns s to itself, which go vet finds (and go test, which runs
// only some of go vet's analyzers, doesn't).
func Describe(s string) string {
	s = s
	return fmt.Sprint(s, " characters")
}

// Cleanup ignores an error, which golangci-lint's errcheck finds.
func Cleanup(path string) {
	os.Remove(path)
}
