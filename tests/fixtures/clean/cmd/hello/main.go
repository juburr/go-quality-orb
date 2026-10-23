// Command hello prints a greeting.
package main

import (
	"fmt"

	"example.com/clean/greet"
)

func main() {
	fmt.Println(greet.Hello("Gopher"), greet.Version)
}
