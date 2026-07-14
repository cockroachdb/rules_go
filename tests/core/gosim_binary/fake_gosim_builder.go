package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
)

type manifest struct {
	RootID   string `json:"root_id"`
	Packages []struct {
		SourceFiles []struct {
			Path string `json:"path"`
		} `json:"source_files"`
	} `json:"packages"`
}

func main() {
	if len(os.Args) == 1 || os.Args[1] != "bazel-build" {
		fmt.Fprintln(os.Stderr, "expected bazel-build subcommand")
		os.Exit(2)
	}

	flags := flag.NewFlagSet("bazel-build", flag.ExitOnError)
	manifestPath := flags.String("manifest", "", "")
	stdlibPath := flags.String("stdlib", "", "")
	flags.String("go", "", "")
	flags.String("goroot", "", "")
	flags.String("output-goarch", "", "")
	flags.String("output-goos", "", "")
	outputPath := flags.String("output", "", "")
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
	if _, err := os.Stat(*stdlibPath); err != nil {
		panic(err)
	}

	script := fmt.Sprintf("#!/bin/sh\nprintf 'root=%%s packages=%%s\\n' %q %q\n", graph.RootID, fmt.Sprint(len(graph.Packages)))
	if err := os.WriteFile(*outputPath, []byte(script), 0o755); err != nil {
		panic(err)
	}
}
