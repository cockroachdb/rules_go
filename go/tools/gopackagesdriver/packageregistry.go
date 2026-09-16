// Copyright 2021 The Bazel Authors. All rights reserved.
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
	"fmt"
	"strings"

	"golang.org/x/tools/go/packages"
)

type PackageRegistry struct {
	packagesByID map[string]*packages.Package
	stdlib       map[string]*packages.Package
	bazelVersion bazelVersion
}

func NewPackageRegistry(bazelVersion bazelVersion, pkgs ...*FlatPackage) *PackageRegistry {
	pr := &PackageRegistry{
		packagesByID: map[string]*packages.Package{},
		stdlib:       map[string]*packages.Package{},
		bazelVersion: bazelVersion,
	}
	pr.Add(pkgs...)
	return pr
}

func (pr *PackageRegistry) Add(pkgs ...*FlatPackage) *PackageRegistry {
	for _, flatPkg := range pkgs {
		imports := make(map[string]*packages.Package)
		for impKey, imp := range flatPkg.Imports {
			imports[impKey] = &packages.Package{
				ID: imp,
			}
		}

		pkg := &packages.Package{
			ID:              flatPkg.ID,
			Name:            flatPkg.Name,
			PkgPath:         flatPkg.PkgPath,
			GoFiles:         flatPkg.GoFiles,
			CompiledGoFiles: flatPkg.CompiledGoFiles,
			OtherFiles:      flatPkg.OtherFiles,
			ExportFile:      flatPkg.ExportFile,
			Imports:         imports,
		}

		if len(pkg.CompiledGoFiles) <= 0 {
			pkg.CompiledGoFiles = pkg.GoFiles
		}

		pr.packagesByID[pkg.ID] = pkg

		if flatPkg.IsStdlib() {
			pr.stdlib[pkg.PkgPath] = pkg
		}
	}
	return pr
}

func (pr *PackageRegistry) ResolvePaths(prf PathResolverFunc) error {
	for _, pkg := range pr.packagesByID {
		ResolvePaths(pkg, prf)
		FilterFilesForBuildTags(pkg)
	}
	return nil
}

// ResolveImports adds stdlib imports to packages. This is required because
// stdlib packages are not part of the JSON file exports as bazel is unaware of
// them.
func (pr *PackageRegistry) ResolveImports(overlays map[string][]byte) error {
	resolve := func(importPath string) *packages.Package {
		if pkg, ok := pr.stdlib[importPath]; ok {
			return pkg
		}

		return nil
	}

	// The aspect writes a go_test's external test archive under the test's
	// label plus "_xtest", the ID MoveTestFiles gives the package it builds
	// from the test's external test files. Those entries are folded into that
	// package below, so gather the packages to process first.
	var pkgs []*packages.Package
	for id, pkg := range pr.packagesByID {
		if !strings.HasSuffix(id, "_xtest") {
			pkgs = append(pkgs, pkg)
		}
	}

	for _, pkg := range pkgs {
		if err := ResolveImports(pkg, resolve, overlays); err != nil {
			return err
		}

		external := pr.packagesByID[pkg.ID+"_xtest"]
		testPkg := MoveTestFiles(pkg)
		if testPkg == nil {
			// No external test files. The external archive's entry lists
			// every file of the test and must not become a package of its own.
			delete(pr.packagesByID, pkg.ID+"_xtest")
			continue
		}
		if external != nil {
			// MoveTestFiles copied the internal package's imports. The external
			// archive's are the ones this package was compiled with: rules_go
			// drops from the internal archive every dependency that would form
			// a cycle through the library under test, and the external archive
			// imports those as variants recompiled against the internal archive
			// (_recompile_external_deps in test.bzl), which the aspect writes
			// as packages of their own.
			for path, imp := range external.Imports {
				testPkg.Imports[path] = imp
			}
			testPkg.ExportFile = external.ExportFile
		}
		pr.packagesByID[testPkg.ID] = testPkg
	}

	return nil
}

func (pr *PackageRegistry) walk(acc map[string]*packages.Package, root string) {
	pkg := pr.packagesByID[root]

	if pkg == nil {
		return
	}

	acc[pkg.ID] = pkg
	for _, pkgI := range pkg.Imports {
		if _, ok := acc[pkgI.ID]; !ok {
			pr.walk(acc, pkgI.ID)
		}
	}
}

func (pr *PackageRegistry) Match(labels []string) ([]string, []*packages.Package) {
	roots := map[string]struct{}{}

	for _, label := range labels {
		// When packagesdriver is ran from rules go, rulesGoRepositoryName will just be @
		if pr.bazelVersion.isAtLeast(bazelVersion{6, 0, 0}) &&
			!strings.HasPrefix(label, "@") {
			// Canonical labels is only since Bazel 6.0.0
			label = fmt.Sprintf("@%s", label)
		}

		if label == RulesGoStdlibLabel {
			// For stdlib, we need to append all the subpackages as roots
			// since RulesGoStdLibLabel doesn't actually show up in the stdlib pkg.json
			for _, pkg := range pr.stdlib {
				roots[pkg.ID] = struct{}{}
			}
		} else if _, ok := pr.packagesByID[label]; ok {
			roots[label] = struct{}{}
			// If an xtest package exists for this package add it to the roots
			if _, ok := pr.packagesByID[label+"_xtest"]; ok {
				roots[label+"_xtest"] = struct{}{}
			}
		} else {
			// Skip a package if we don't have .pkg.json for it.
			// This happens if 'bazel query' matches the target, but 'bazel build'
			// can't analyze it, for example, if target_compatible_with is set
			// with contraints not compatible with the host platform.
			continue
		}
	}

	walkedPackages := map[string]*packages.Package{}
	retRoots := make([]string, 0, len(roots))
	for rootPkg := range roots {
		retRoots = append(retRoots, rootPkg)
		pr.walk(walkedPackages, rootPkg)
	}

	retPkgs := make([]*packages.Package, 0, len(walkedPackages))
	for _, pkg := range walkedPackages {
		retPkgs = append(retPkgs, pkg)
	}

	return retRoots, retPkgs
}
