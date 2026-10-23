package parse

import "testing"

func TestParse(t *testing.T) {
	if Parse("abc") != 3 {
		t.Fatal("Parse(abc) != 3")
	}
}

func FuzzParse(f *testing.F) {
	f.Add("hello")
	f.Fuzz(func(t *testing.T, s string) {
		Parse(s)
	})
}
