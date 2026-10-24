package greet

import "testing"

func TestHello(t *testing.T) {
	if got := Hello("Gopher"); got != "Hello, Gopher" {
		t.Fatalf("Hello(Gopher) = %q", got)
	}
}

func TestHelloEmpty(t *testing.T) {
	if got := Hello(" "); got != "Hello, world" {
		t.Fatalf("Hello( ) = %q", got)
	}
}

func FuzzParse(f *testing.F) {
	f.Add("hello")
	f.Fuzz(func(t *testing.T, s string) {
		if Parse(s) != len(s) {
			t.Fatal("wrong length")
		}
	})
}

func BenchmarkHello(b *testing.B) {
	for i := 0; i < b.N; i++ {
		Hello("Gopher")
	}
}
