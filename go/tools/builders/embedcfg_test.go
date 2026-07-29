package main

import (
	"path/filepath"
	"testing"
)

func TestFindInRootDirsUsesMostSpecificRoot(t *testing.T) {
	execRoot := filepath.Join(string(filepath.Separator), "execroot")
	packageRoot := filepath.Join(execRoot, "example", "package")
	path := filepath.Join(packageRoot, "message.txt")
	if got := findInRootDirs(path, []string{execRoot, packageRoot}); got != packageRoot {
		t.Fatalf("findInRootDirs() = %q, want %q", got, packageRoot)
	}
}
