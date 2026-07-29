package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
)

type fileRecord struct {
	Path         string `json:"path"`
	RelativePath string `json:"relative_path"`
	IsDirectory  bool   `json:"is_directory"`
}

type manifest struct {
	RootID   string `json:"root_id"`
	Packages []struct {
		Opaque      bool         `json:"opaque"`
		OutputDir   string       `json:"output_dir"`
		SourceFiles []fileRecord `json:"source_files"`
	} `json:"packages"`
}

func copyFile(source, destination string, mode fs.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return err
	}
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()
	output, err := os.OpenFile(destination, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(output, input); err != nil {
		output.Close()
		return err
	}
	return output.Close()
}

func copyTree(source, destination string) error {
	return filepath.WalkDir(source, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}
		target := filepath.Join(destination, relative)
		if entry.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		return copyFile(path, target, info.Mode().Perm())
	})
}

func main() {
	if len(os.Args) == 1 || os.Args[1] != "bazel-translate" {
		fmt.Fprintln(os.Stderr, "expected bazel-translate subcommand")
		os.Exit(2)
	}

	flags := flag.NewFlagSet("bazel-translate", flag.ExitOnError)
	manifestPath := flags.String("manifest", "", "")
	stdlibRoot := flags.String("stdlib-root", "", "")
	packageList := flags.String("package-list", "", "")
	outputPackageList := flags.String("output-package-list", "", "")
	outputStdlibPkg := flags.String("output-stdlib-pkg", "", "")
	installSuffix := flags.String("install-suffix", "", "")
	flags.String("stdlib", "", "")
	flags.String("go", "", "")
	flags.String("goroot", "", "")
	_ = flags.Parse(os.Args[2:])

	data, err := os.ReadFile(*manifestPath)
	if err != nil {
		panic(err)
	}
	var graph manifest
	if err := json.Unmarshal(data, &graph); err != nil {
		panic(err)
	}
	if graph.RootID == "" || len(graph.Packages) == 0 {
		panic("manifest has no root package")
	}
	for _, pkg := range graph.Packages {
		if pkg.OutputDir == "" {
			continue
		}
		if pkg.Opaque {
			panic("opaque package unexpectedly has a translated output")
		}
		if err := os.MkdirAll(pkg.OutputDir, 0o755); err != nil {
			panic(err)
		}
		for _, source := range pkg.SourceFiles {
			if source.IsDirectory {
				if err := copyTree(source.Path, pkg.OutputDir); err != nil {
					panic(err)
				}
				continue
			}
			relative := source.RelativePath
			if relative == "" {
				relative = filepath.Base(source.Path)
			}
			if err := copyFile(source.Path, filepath.Join(pkg.OutputDir, relative), 0o644); err != nil {
				panic(err)
			}
		}
	}

	originalArchives := filepath.Join(*stdlibRoot, "pkg", *installSuffix)
	outputArchives := filepath.Join(*outputStdlibPkg, *installSuffix)
	if err := copyTree(originalArchives, outputArchives); err != nil {
		panic(err)
	}
	if err := copyFile(*packageList, *outputPackageList, 0o644); err != nil {
		panic(err)
	}
}
