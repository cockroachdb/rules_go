// Copyright 2026 The Bazel Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import (
	"maps"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"testing"

	"golang.org/x/tools/go/packages"
)

// writeSources writes the given files into a temporary directory and returns
// their absolute paths in the order given.
func writeSources(t *testing.T, files []struct{ name, content string }) []string {
	t.Helper()
	dir := t.TempDir()
	paths := make([]string, 0, len(files))
	for _, f := range files {
		path := filepath.Join(dir, f.name)
		if err := os.WriteFile(path, []byte(f.content), 0o644); err != nil {
			t.Fatal(err)
		}
		paths = append(paths, path)
	}
	return paths
}

func importIDs(imports map[string]*packages.Package) map[string]string {
	ids := make(map[string]string, len(imports))
	for path, pkg := range imports {
		ids[path] = pkg.ID
	}
	return ids
}

// TestResolveImportsExternalTests covers a go_test whose external test file
// imports a package that itself imports the library under test. rules_go
// drops that import from the internal archive to break the cycle, so only the
// external archive the aspect writes under the "_xtest" ID knows about it.
// The file list also starts with the external test file, so the package name
// must not be taken from the first file.
func TestResolveImportsExternalTests(t *testing.T) {
	srcs := writeSources(t, []struct{ name, content string }{
		{"a_external_test.go", "package a_test\n\nimport (\n\t\"testing\"\n\n\t\"example.com/helper\"\n\t\"example.com/util\"\n)\n\nfunc TestExternal(t *testing.T) { helper.Helper(); util.U() }\n"},
		{"a_internal_test.go", "package a\n\nimport \"testing\"\n\nfunc TestInternal(t *testing.T) {}\n"},
		{"a.go", "package a\n\nimport (\n\t\"fmt\"\n\n\t\"example.com/util\"\n)\n\nfunc A() { fmt.Println(); util.U() }\n"},
		{"helper.go", "package helper\n\nimport \"example.com/a\"\n\nfunc Helper() { a.A() }\n"},
		{"util.go", "package util\n\nfunc U() {}\n"},
	})
	testSrcs, helperSrcs, utilSrcs := srcs[:3], srcs[3:4], srcs[4:]

	// helper imports a, so for the external tests rules_go recompiled it
	// against the internal archive and dropped it from the internal one.
	// The aspect writes that variant under its own ID and the external
	// archive imports it by that ID; util, which does not reach a, is the
	// production package for both.
	const helperVariant = "@//helper:helper [@//a:a_test]"
	pr := NewPackageRegistry(bazelVersion{6, 0, 0},
		&FlatPackage{
			ID:              "@//a:a_test",
			PkgPath:         "example.com/a",
			ExportFile:      "a_test.x",
			GoFiles:         slices.Clone(testSrcs),
			CompiledGoFiles: slices.Clone(testSrcs),
			Imports:         map[string]string{"example.com/util": "@//util:util"},
		},
		&FlatPackage{
			ID:              "@//a:a_test_xtest",
			PkgPath:         "example.com/a_test",
			ExportFile:      "a_test_test.x",
			GoFiles:         slices.Clone(testSrcs),
			CompiledGoFiles: slices.Clone(testSrcs),
			Imports: map[string]string{
				"example.com/a":      "@//a:a_test",
				"example.com/helper": helperVariant,
				"example.com/util":   "@//util:util",
			},
		},
		&FlatPackage{
			ID:              "@//helper:helper",
			PkgPath:         "example.com/helper",
			ExportFile:      "helper.x",
			GoFiles:         slices.Clone(helperSrcs),
			CompiledGoFiles: slices.Clone(helperSrcs),
			Imports:         map[string]string{"example.com/a": "@//a:a"},
		},
		&FlatPackage{
			ID:              helperVariant,
			PkgPath:         "example.com/helper",
			ExportFile:      "a_test.helper.recompile1.x",
			GoFiles:         slices.Clone(helperSrcs),
			CompiledGoFiles: slices.Clone(helperSrcs),
			Imports:         map[string]string{"example.com/a": "@//a:a_test"},
		},
		&FlatPackage{
			ID:              "@//util:util",
			PkgPath:         "example.com/util",
			ExportFile:      "util.x",
			GoFiles:         slices.Clone(utilSrcs),
			CompiledGoFiles: slices.Clone(utilSrcs),
			Imports:         map[string]string{},
		},
		&FlatPackage{ID: "@io_bazel_rules_go//stdlib:fmt", PkgPath: "fmt", ExportFile: "fmt.x", Standard: true},
		&FlatPackage{ID: "@io_bazel_rules_go//stdlib:testing", PkgPath: "testing", ExportFile: "testing.x", Standard: true},
	)
	if err := pr.ResolveImports(nil); err != nil {
		t.Fatal(err)
	}

	internal := pr.packagesByID["@//a:a_test"]
	if internal.Name != "a" {
		t.Errorf("internal package name = %q, want %q", internal.Name, "a")
	}
	if want := []string{srcs[2], srcs[1]}; !slices.Equal(internal.GoFiles, want) {
		t.Errorf("internal GoFiles = %v, want %v", internal.GoFiles, want)
	}
	if _, ok := internal.Imports["example.com/helper"]; ok {
		t.Errorf("internal package imports helper; only the external tests do")
	}

	external := pr.packagesByID["@//a:a_test_xtest"]
	if external == nil {
		t.Fatal("no external test package")
	}
	if external.Name != "a_test" || external.PkgPath != "example.com/a_test" {
		t.Errorf("external test package is %q at %q, want %q at %q", external.Name, external.PkgPath, "a_test", "example.com/a_test")
	}
	if want := []string{srcs[0]}; !slices.Equal(external.GoFiles, want) {
		t.Errorf("external GoFiles = %v, want %v", external.GoFiles, want)
	}
	if external.ExportFile != "a_test_test.x" {
		t.Errorf("external ExportFile = %q, want the external archive's", external.ExportFile)
	}
	wantImports := map[string]string{
		"example.com/a":      "@//a:a_test",
		"example.com/helper": helperVariant,
		"example.com/util":   "@//util:util",
		"fmt":                "@io_bazel_rules_go//stdlib:fmt",
		"testing":            "@io_bazel_rules_go//stdlib:testing",
	}
	if got := importIDs(external.Imports); !maps.Equal(got, wantImports) {
		t.Errorf("external Imports = %v, want %v", got, wantImports)
	}

	// The variant is a package like any other, and reachable from the
	// external test package, so a load of the test returns it.
	roots, pkgs := pr.Match([]string{"@//a:a_test"})
	sort.Strings(roots)
	if want := []string{"@//a:a_test", "@//a:a_test_xtest"}; !slices.Equal(roots, want) {
		t.Errorf("roots = %v, want %v", roots, want)
	}
	var ids []string
	for _, pkg := range pkgs {
		ids = append(ids, pkg.ID)
	}
	sort.Strings(ids)
	if !slices.Contains(ids, helperVariant) || slices.Contains(ids, "@//helper:helper") {
		t.Errorf("packages reachable from the test = %v, want the helper variant and not the production helper", ids)
	}
}

// TestResolveImportsNoExternalTests: the aspect writes the external archive
// for every go_test, external test files or not, and that entry lists every
// file of the test. Without external test files it must not survive as a
// package of its own.
func TestResolveImportsNoExternalTests(t *testing.T) {
	srcs := writeSources(t, []struct{ name, content string }{
		{"a.go", "package a\n"},
		{"a_test.go", "package a\n\nimport \"testing\"\n\nfunc TestA(t *testing.T) {}\n"},
	})
	pr := NewPackageRegistry(bazelVersion{6, 0, 0},
		&FlatPackage{ID: "@//a:a_test", PkgPath: "example.com/a", GoFiles: slices.Clone(srcs), CompiledGoFiles: slices.Clone(srcs)},
		&FlatPackage{ID: "@//a:a_test_xtest", PkgPath: "example.com/a_test", GoFiles: slices.Clone(srcs), CompiledGoFiles: slices.Clone(srcs)},
		&FlatPackage{ID: "@io_bazel_rules_go//stdlib:testing", PkgPath: "testing", ExportFile: "testing.x", Standard: true},
	)
	if err := pr.ResolveImports(nil); err != nil {
		t.Fatal(err)
	}
	if _, ok := pr.packagesByID["@//a:a_test_xtest"]; ok {
		t.Errorf("external test package exists although there are no external test files")
	}
	var ids []string
	for id := range pr.packagesByID {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	if want := []string{"@//a:a_test", "@io_bazel_rules_go//stdlib:testing"}; !slices.Equal(ids, want) {
		t.Errorf("packages = %v, want %v", ids, want)
	}
}

func TestPackageName(t *testing.T) {
	for _, tc := range []struct {
		name  string
		files []struct{ name, content string }
		want  string
	}{
		{
			name: "external test file sorts first",
			files: []struct{ name, content string }{
				{"a_external_test.go", "package a_test\n"},
				{"a_internal_test.go", "package a\n"},
				{"a.go", "package a\n"},
			},
			want: "a",
		},
		{
			name: "only test files",
			files: []struct{ name, content string }{
				{"a_external_test.go", "package a_test\n"},
				{"a_test.go", "package a\n"},
			},
			want: "a",
		},
		{
			name: "only external test files",
			files: []struct{ name, content string }{
				{"a_external_test.go", "package a_test\n"},
			},
			want: "a",
		},
		{
			name: "package whose own name ends in _test",
			files: []struct{ name, content string }{
				{"x.go", "package name_test\n"},
			},
			want: "name_test",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srcs := writeSources(t, tc.files)
			pkg := &packages.Package{ID: "@//a:a", CompiledGoFiles: srcs, Imports: map[string]*packages.Package{}}
			if err := ResolveImports(pkg, func(string) *packages.Package { return nil }, nil); err != nil {
				t.Fatal(err)
			}
			if pkg.Name != tc.want {
				t.Errorf("package name = %q, want %q", pkg.Name, tc.want)
			}
		})
	}
}
