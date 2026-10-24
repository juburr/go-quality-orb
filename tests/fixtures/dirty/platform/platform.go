// Package platform builds everywhere but Windows, which the build command
// finds.
package platform

// Name is the platform's name.
func Name() string {
	return name
}
