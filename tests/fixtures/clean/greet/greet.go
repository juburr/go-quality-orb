// Package greet is the clean fixture: every go-quality-orb check passes on it.
package greet

//go:generate go run ../internal/gen -o version_gen.go -v 1.2.3

import "strings"

// Hello greets name.
func Hello(name string) string {
	if strings.TrimSpace(name) == "" {
		return "Hello, world"
	}
	return "Hello, " + name
}

// Parse returns the length of s, and never panics.
func Parse(s string) int {
	return len(s)
}
