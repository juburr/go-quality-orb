//go:build failing

package parse

import "testing"

// TestFailing fails, with the failing build tag, for the test command's
// failure cases.
func TestFailing(t *testing.T) {
	t.Fatal("this test fails on purpose")
}
