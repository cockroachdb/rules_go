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

"""Rules for compiling Gosim-translated binaries through rules_go."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//lib:structs.bzl", "structs")
load("//go/private:common.bzl", "GO_TOOLCHAIN", "goos_to_extension", "has_shared_lib_extension")
load("//go/private:context.bzl", "go_context")
load("//go/private:mode.bzl", "installsuffix")
load("//go/private:providers.bzl", "GoArchive", "GoSDK", "GoStdLib")
load("//go/private/rules:binary.bzl", "gc_linkopts")
load("//go/private/rules:transition.bzl", "go_transition")
load("//go/private/rules:wrappers.bzl", "go_binary_macro")

GoSimGraphInfo = provider(
    doc = "The configured Go graph and translated source trees used by Gosim.",
    fields = {
        "manifest": "JSON manifest describing the configured package graph.",
        "sources": "Depset of original source and embed files.",
        "translated_sources": "Depset of translated package directory artifacts.",
    },
)

def _file_record(file, relative_path):
    return {
        "is_directory": file.is_directory,
        "path": file.path,
        "relative_path": relative_path,
        "short_path": file.short_path,
    }

def _package_record(data, opaque, output_dir, bin_dir_path):
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
        "cgo": data._cgo,
        "embed_files": embed_files,
        "export_file": data.export_file.path if data.export_file else "",
        "id": str(data.label),
        "import_map": data.importmap,
        "import_path": data.importpath,
        "import_path_aliases": list(data.importpath_aliases),
        "imports": [str(label) for label in data._dep_labels],
        "name": data.name,
        "opaque": opaque,
        "output_dir": output_dir.path if output_dir else "",
        "source_files": source_files,
        "x_defs": {key: value for key, value in data._x_defs},
    }

def _collect_data(archives):
    by_id = {}
    for archive in archives:
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

def _opaque_closure(by_id, mode):
    if mode.pure:
        return {}
    package_ids = sorted(by_id.keys())
    opaque = {
        package_id: True
        for package_id in package_ids
        if by_id[package_id]._cgo
    }

    # A retained cgo archive was compiled against its original dependency
    # closure. Retain that closure too, so translated archives never replace an
    # ABI dependency underneath an already-compiled archive.
    for _unused in package_ids:
        for package_id in package_ids:
            if not opaque.get(package_id):
                continue
            for dependency in by_id[package_id]._dep_labels:
                dependency_id = str(dependency)
                if dependency_id in by_id:
                    opaque[dependency_id] = True
    return opaque

def _reuse_archive(data, direct, mode):
    x_defs = {key: value for key, value in data._x_defs}
    for archive in direct:
        x_defs.update(archive.x_defs)
    headers = depset(
        direct = [
            file
            for file in data.srcs
            if file.path.split(".")[-1].lower().startswith("h")
        ],
        transitive = [archive._headers for archive in direct],
    )
    return GoArchive(
        source = struct(mode = mode),
        data = data,
        direct = direct,
        libs = depset(
            direct = [data.file],
            transitive = [archive.libs for archive in direct],
        ),
        transitive = depset(
            direct = [data],
            transitive = [archive.transitive for archive in direct],
        ),
        x_defs = x_defs,
        cgo_deps = depset(
            transitive = [data._cgo_deps] + [archive.cgo_deps for archive in direct],
        ),
        # cgo export headers are only consumed by c-archive/c-shared outputs.
        # gosim_go_binary currently emits an executable.
        cgo_exports = depset(transitive = [archive.cgo_exports for archive in direct]),
        runfiles = data.runfiles.merge_all([archive.runfiles for archive in direct]),
        _headers = headers,
    )

def _translated_source(data, direct, mode, source_dir, name, is_main):
    return struct(
        name = name,
        label = data.label,
        importpath = data.importpath,
        importmap = data.importmap,
        importpath_aliases = data.importpath_aliases,
        pathtype = data.pathtype,
        testfilter = None,
        is_main = is_main,
        mode = mode,
        srcs = [source_dir],
        embedsrcs = list(data._embedsrcs),
        cover = depset(),
        x_defs = {key: value for key, value in data._x_defs},
        deps = direct,
        gc_goopts = list(data._gc_goopts),
        runfiles = data.runfiles,
        cgo = False,
        cdeps = [],
        cppopts = [],
        copts = [],
        cxxopts = [],
        clinkopts = [],
        pgoprofile = None,
    )

def _go_with_support_stdlib(base_go, package_list, stdlib_pkg):
    sdk = base_go.sdk
    translated_sdk = GoSDK(
        goos = sdk.goos,
        goarch = sdk.goarch,
        gofips140 = sdk.gofips140,
        experiments = sdk.experiments,
        root_file = sdk.root_file,
        libs = sdk.libs,
        headers = sdk.headers,
        srcs = sdk.srcs,
        package_list = package_list,
        tools = sdk.tools,
        go = sdk.go,
        version = sdk.version,
    )
    translated_stdlib = GoStdLib(
        _list_json = base_go.stdlib._list_json,
        cache_dir = base_go.stdlib.cache_dir,
        libs = depset([stdlib_pkg]),
        root_file = stdlib_pkg,
    )
    values = structs.to_dict(base_go)
    env = dict(base_go.env)
    env["GOROOT"] = stdlib_pkg.dirname
    values.update({
        "coverdata": None,
        "coverage_enabled": False,
        "coverage_instrumented": False,
        "env": env,
        "env_for_path_mapping": {
            key: value
            for key, value in env.items()
            if key != "GOROOT"
        },
        "nogo": None,
        "sdk": translated_sdk,
        "stdlib": translated_stdlib,
    })
    return struct(**values)

def _gosim_binary_impl(ctx):
    root = ctx.attr.target[GoArchive]
    runtime_archives = [dep[GoArchive] for dep in ctx.attr.gosim_runtime_deps]
    mode = root.source.mode
    base_go = go_context(
        ctx,
        include_deprecated_properties = False,
        go_context_data = ctx.attr._go_context_data[0],
        goos = ctx.attr.goos,
        goarch = ctx.attr.goarch,
    )
    if base_go.mode != mode:
        fail("Gosim context mode does not match hidden binary mode")

    root_data = root.transitive.to_list()
    all_data = _collect_data([root] + runtime_archives)
    opaque = _opaque_closure(all_data, mode)
    root_id = str(root.data.label)
    if opaque.get(root_id):
        fail("gosim_go_binary cannot translate a main package that directly uses cgo: {}".format(root.data.label))

    output_by_id = {}
    translated_source_dirs = []
    for index, data in enumerate(root_data):
        package_id = str(data.label)
        if opaque.get(package_id):
            continue
        output_dir = ctx.actions.declare_directory(
            "{}.gosim_srcs/pkg_{}".format(ctx.label.name, index),
        )
        output_by_id[package_id] = output_dir
        translated_source_dirs.append(output_dir)

    package_ids = sorted(all_data.keys())
    packages = []
    source_files = []
    export_files = []
    for package_id in package_ids:
        data = all_data[package_id]
        packages.append(_package_record(
            data,
            opaque.get(package_id, False),
            output_by_id.get(package_id),
            ctx.bin_dir.path,
        ))
        source_files.extend(data.srcs)
        source_files.extend(data._embedsrcs)
        if data.export_file:
            export_files.append(data.export_file)

    manifest = ctx.actions.declare_file(ctx.label.name + ".gosim.json")
    ctx.actions.write(
        output = manifest,
        content = json.encode_indent({
            "goarch": mode.goarch,
            "goos": mode.goos,
            "packages": packages,
            "race": mode.race,
            "root_id": root_id,
            "schema_version": 2,
            "tags": list(mode.tags),
        }, indent = "  ") + "\n",
    )

    support_pkg = ctx.actions.declare_directory(ctx.label.name + ".gosim_goroot/pkg")
    support_package_list = ctx.actions.declare_file(ctx.label.name + ".gosim_packages.txt")
    sdk = base_go.sdk
    stdlib = base_go.stdlib
    args = ctx.actions.args()
    args.add("bazel-translate")
    args.add("--manifest", manifest)
    args.add("--stdlib", stdlib._list_json)
    args.add("--go", sdk.go)
    args.add("--goroot", sdk.root_file.dirname)
    args.add("--stdlib-root", stdlib.root_file.dirname)
    args.add("--package-list", sdk.package_list)
    args.add("--output-package-list", support_package_list)
    args.add("--output-stdlib-pkg", support_pkg.path)
    args.add("--install-suffix", installsuffix(mode))

    inputs = depset(
        direct = source_files + export_files + [
            manifest,
            sdk.go,
            sdk.package_list,
            sdk.root_file,
            stdlib._list_json,
            stdlib.root_file,
        ],
        transitive = [
            sdk.headers,
            sdk.libs,
            sdk.srcs,
            sdk.tools,
            stdlib.cache_dir,
            stdlib.libs,
            base_go.cc_toolchain_files,
        ],
    )
    ctx.actions.run(
        executable = ctx.executable.gosim_tool,
        arguments = [args],
        inputs = inputs,
        outputs = translated_source_dirs + [support_pkg, support_package_list],
        mnemonic = "GoSimTranslate",
        progress_message = "Translating deterministic Go graph %{label}",
        tools = [ctx.attr.gosim_tool[DefaultInfo].files_to_run],
        env = base_go.env,
    )

    translated_go = _go_with_support_stdlib(base_go, support_package_list, support_pkg)
    compiled = {}
    for index, data in enumerate(root_data):
        package_id = str(data.label)
        direct = []
        for dependency in data._dep_labels:
            dependency_id = str(dependency)
            archive = compiled.get(dependency_id)
            if not archive:
                fail("Gosim archive graph is not dependency ordered: {} appears before {}".format(
                    package_id,
                    dependency_id,
                ))
            direct.append(archive)
        if opaque.get(package_id):
            archive = _reuse_archive(data, direct, mode)
        else:
            source = _translated_source(
                data,
                direct,
                mode,
                output_by_id[package_id],
                "gosim_pkg_{}".format(index),
                package_id == root_id,
            )
            archive = translated_go.archive(translated_go, source)
        compiled[package_id] = archive

    root_archive = compiled[root_id]
    name = ctx.attr.output_name or ctx.label.name
    extension = goos_to_extension(mode.goos)
    if extension and not name.endswith(extension):
        name += extension
    executable = ctx.actions.declare_file(name)
    translated_go.link(
        translated_go,
        archive = root_archive,
        executable = executable,
        gc_linkopts = gc_linkopts(ctx),
        version_file = ctx.version_file,
        info_file = ctx.info_file,
    )
    cgo_dynamic_deps = [
        dependency
        for dependency in root_archive.cgo_deps.to_list()
        if has_shared_lib_extension(dependency.basename)
    ]
    runfiles = ctx.runfiles(files = cgo_dynamic_deps).merge(root_archive.runfiles)
    providers = [
        DefaultInfo(
            executable = executable,
            files = depset([executable]),
            runfiles = runfiles,
        ),
        GoSimGraphInfo(
            manifest = manifest,
            sources = depset(source_files),
            translated_sources = depset(translated_source_dirs),
        ),
        OutputGroupInfo(
            compilation_outputs = depset([root_archive.data.file]),
            gosim_manifest = depset([manifest]),
            gosim_sources = depset(translated_source_dirs),
        ),
    ]
    if ctx.attr.env:
        providers.append(RunEnvironmentInfo(environment = ctx.attr.env))
    return providers

_gosim_binary = rule(
    implementation = _gosim_binary_impl,
    attrs = {
        "env": attr.string_dict(),
        "gc_linkopts": attr.string_list(),
        "gosim_runtime_deps": attr.label_list(
            cfg = go_transition,
            providers = [GoArchive],
            doc = "Gosim runtime packages made available to the translator.",
        ),
        "gosim_tool": attr.label(
            cfg = "exec",
            executable = True,
            mandatory = True,
            doc = "Executable implementing the Gosim Bazel translation protocol.",
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
        "_go_context_data": attr.label(
            cfg = go_transition,
            default = "//:go_context_data",
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
    """Builds a deterministic executable from the same inputs as go_binary.

    A hidden go_binary resolves the configured rules_go archive graph. Gosim
    translates non-cgo packages, then rules_go compiles those source trees and
    performs the final link. Cgo packages and their dependency closures remain
    opaque rules_go archives.
    """
    raw_name = name + "__gosim_graph"
    raw_kwargs = dict(kwargs)
    raw_kwargs["basename"] = raw_name
    raw_kwargs["out"] = ""
    raw_kwargs["pure"] = kwargs.get("pure", "auto")
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
        env = kwargs.get("env", {}),
        gc_linkopts = kwargs.get("gc_linkopts", []),
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
