# Copyright 2026 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Rules for building a Go binary through Gosim's source translator."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("//go/private:common.bzl", "GO_TOOLCHAIN")
load("//go/private:providers.bzl", "GoArchive", "GoStdLib")
load("//go/private/rules:transition.bzl", "go_transition")
load("//go/private/rules:wrappers.bzl", "go_binary_macro")

GoSimGraphInfo = provider(
    doc = "The configured Go source graph supplied to the Gosim builder.",
    fields = {
        "manifest": "JSON manifest describing the configured package graph.",
        "sources": "Depset of source and embed files referenced by the manifest.",
    },
)

def _file_record(file, relative_path):
    return {
        "is_directory": file.is_directory,
        "path": file.path,
        "relative_path": relative_path,
        "short_path": file.short_path,
    }

def _package_record(data, pure, bin_dir_path):
    source_files = [_file_record(file, file.basename) for file in data.srcs]
    embed_files = []
    if data._embedsrcs:
        if not data.srcs:
            fail("cannot relativize embed files for {}: package has no source files".format(data.label))
        source_dir = data.srcs[-1].dirname
        for file in data._embedsrcs:
            embed_path = paths.relativize(file.path, file.root.path)
            relative_path = paths.relativize(
                embed_path.lstrip(bin_dir_path + "/"),
                source_dir.lstrip(bin_dir_path + "/"),
            )
            embed_files.append(_file_record(file, relative_path))
    return {
        "cgo": data._cgo and not pure,
        "embed_files": embed_files,
        "id": str(data.label),
        "import_map": data.importmap,
        "import_path": data.importpath,
        "import_path_aliases": list(data.importpath_aliases),
        "imports": [str(label) for label in data._dep_labels],
        "name": data.name,
        "source_files": source_files,
        "x_defs": {key: value for key, value in data._x_defs},
    }

def _collect_archives(root, runtime_deps):
    by_id = {}
    for archive in [root] + runtime_deps:
        for data in archive.transitive.to_list():
            package_id = str(data.label)
            previous = by_id.get(package_id)
            if previous and previous.importmap != data.importmap:
                fail("Gosim package ID {} has conflicting import maps: {} and {}".format(
                    package_id,
                    previous.importmap,
                    data.importmap,
                ))
            by_id[package_id] = data
    return by_id

def _gosim_binary_impl(ctx):
    root = ctx.attr.target[GoArchive]
    runtime_deps = [dep[GoArchive] for dep in ctx.attr.gosim_runtime_deps]
    archives = _collect_archives(root, runtime_deps)

    mode = root.source.mode
    package_ids = sorted(archives.keys())
    packages = []
    source_files = []
    for package_id in package_ids:
        data = archives[package_id]
        if data._cgo and not mode.pure:
            fail("gosim_go_binary does not support cgo package {} ({}) yet".format(
                data.importpath,
                data.label,
            ))
        packages.append(_package_record(data, mode.pure, ctx.bin_dir.path))
        source_files.extend(data.srcs)
        source_files.extend(data._embedsrcs)

    manifest = ctx.actions.declare_file(ctx.label.name + ".gosim.json")
    ctx.actions.write(
        output = manifest,
        content = json.encode_indent({
            "goarch": mode.goarch,
            "goos": mode.goos,
            "packages": packages,
            "race": mode.race,
            "root_id": str(root.data.label),
            "schema_version": 1,
            "tags": list(mode.tags),
        }, indent = "  ") + "\n",
    )

    name = ctx.attr.output_name or ctx.label.name
    if mode.goos == "windows" and not name.endswith(".exe"):
        name += ".exe"
    executable = ctx.actions.declare_file(name)

    toolchain = ctx.toolchains[GO_TOOLCHAIN]
    sdk = toolchain.sdk
    stdlib_target = ctx.attr._go_stdlib
    if type(stdlib_target) == "list":
        stdlib_target = stdlib_target[0]
    stdlib = stdlib_target[GoStdLib]

    args = ctx.actions.args()
    args.add("bazel-build")
    args.add("--manifest", manifest)
    args.add("--stdlib", stdlib._list_json)
    args.add("--go", sdk.go)
    args.add("--goroot", sdk.root_file.dirname)
    args.add("--output-goos", sdk.goos)
    args.add("--output-goarch", sdk.goarch)
    args.add("--output", executable)

    inputs = depset(
        direct = source_files + [
            manifest,
            sdk.go,
            sdk.package_list,
            sdk.root_file,
            stdlib._list_json,
        ],
        transitive = [
            sdk.headers,
            sdk.libs,
            sdk.srcs,
            sdk.tools,
        ],
    )

    ctx.actions.run(
        executable = ctx.executable.gosim_tool,
        arguments = [args],
        inputs = inputs,
        outputs = [executable],
        mnemonic = "GoSimBuild",
        progress_message = "Building deterministic Go binary %{label}",
        tools = [ctx.attr.gosim_tool[DefaultInfo].files_to_run],
    )

    runfiles = root.runfiles
    return [
        DefaultInfo(
            executable = executable,
            files = depset([executable]),
            runfiles = runfiles,
        ),
        GoSimGraphInfo(
            manifest = manifest,
            sources = depset(source_files),
        ),
        OutputGroupInfo(gosim_manifest = depset([manifest])),
    ]

_gosim_binary = rule(
    implementation = _gosim_binary_impl,
    attrs = {
        "gosim_runtime_deps": attr.label_list(
            cfg = go_transition,
            providers = [GoArchive],
            doc = "Gosim runtime packages that must be available to the translated binary.",
        ),
        "gosim_tool": attr.label(
            cfg = "exec",
            executable = True,
            mandatory = True,
            doc = "Executable implementing the Gosim Bazel builder protocol.",
        ),
        "output_name": attr.string(),
        "goarch": attr.string(default = "auto"),
        "gofips140": attr.string(default = "off"),
        "goos": attr.string(default = "auto"),
        "gotags": attr.string_list(),
        "linkmode": attr.string(default = "auto"),
        "msan": attr.string(default = "auto"),
        "pgoprofile": attr.string(default = "auto"),
        "pure": attr.string(default = "auto"),
        "race": attr.string(default = "auto"),
        "static": attr.string(default = "auto"),
        "target": attr.label(
            mandatory = True,
            providers = [GoArchive],
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
        "_go_stdlib": attr.label(
            cfg = go_transition,
            default = "//:stdlib",
            providers = [GoStdLib],
        ),
    },
    executable = True,
    toolchains = [GO_TOOLCHAIN],
)

def gosim_go_binary(
        name,
        gosim_tool,
        gosim_runtime_deps = [],
        **kwargs):
    """Builds a deterministic executable from the same inputs as `go_binary`.

    The hidden `go_binary` target resolves rules_go's configured package graph.
    Its compile and link actions are not dependencies of the Gosim action; only
    its providers and selected sources are consumed.

    This initial implementation rebuilds with cgo disabled. Packages declared
    with cgo may be used only when they provide a complete non-cgo fallback.
    """
    raw_name = name + "__gosim_graph"
    raw_kwargs = dict(kwargs)
    raw_kwargs["basename"] = raw_name
    raw_kwargs["out"] = ""
    raw_kwargs["pure"] = kwargs.get("pure", "on")
    raw_kwargs["gotags"] = sorted({
        tag: None
        for tag in kwargs.get("gotags", []) + [
            "gosim_bazel_runtime",
            "http2legacy",
            "linkname",
            "purego",
            "sim",
        ]
    }.keys())
    raw_kwargs["tags"] = kwargs.get("tags", []) + ["manual"]
    raw_kwargs["visibility"] = ["//visibility:private"]
    if not kwargs.get("importpath") and not kwargs.get("embed"):
        importpath = native.package_name()
        if not importpath:
            importpath = name
        elif not importpath.endswith(name):
            importpath += "/" + name
        raw_kwargs["importpath"] = importpath
    go_binary_macro(
        name = raw_name,
        **raw_kwargs
    )

    outer_kwargs = {}
    for key in [
        "compatible_with",
        "deprecation",
        "exec_compatible_with",
        "exec_properties",
        "features",
        "restricted_to",
        "tags",
        "target_compatible_with",
        "testonly",
        "visibility",
    ]:
        if key in kwargs:
            outer_kwargs[key] = kwargs[key]

    output_name = kwargs.get("out") or kwargs.get("basename") or name
    _gosim_binary(
        name = name,
        goarch = raw_kwargs.get("goarch", "auto"),
        gofips140 = raw_kwargs.get("gofips140", "off"),
        goos = raw_kwargs.get("goos", "auto"),
        gotags = raw_kwargs.get("gotags", []),
        gosim_runtime_deps = gosim_runtime_deps,
        gosim_tool = gosim_tool,
        linkmode = raw_kwargs.get("linkmode", "auto"),
        msan = raw_kwargs.get("msan", "auto"),
        output_name = output_name,
        pgoprofile = raw_kwargs.get("pgoprofile", "auto"),
        pure = raw_kwargs.get("pure", "auto"),
        race = raw_kwargs.get("race", "auto"),
        static = raw_kwargs.get("static", "auto"),
        target = ":" + raw_name,
        **outer_kwargs
    )
