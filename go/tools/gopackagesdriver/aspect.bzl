# Copyright 2021 The Bazel Go Rules Authors. All rights reserved.
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

load(
    "//go/private:providers.bzl",
    "GoArchive",
    "GoStdLib",
)
load(
    "//go/tools/gopackagesdriver/pkgjson:pkg_json.bzl",
    "write_pkg_json",
    file_path_lib = "file_path",
    is_file_external_lib = "is_file_external",
)

GoPkgInfo = provider()

DEPS_ATTRS = [
    "deps",
    "embed",
]

PROTO_COMPILER_ATTRS = [
    "compiler",
    "compilers",
    "library",
]

def bazel_supports_canonical_label_literals():
    return str(Label("//:bogus")).startswith("@@")

def is_file_external(f):
    return is_file_external_lib(f)

def file_path(f):
    return file_path_lib(f)

# make_pkg_json_with_archive generates a pkg.json file from an archive
# and supports cgo generated code.
#
# This function was created to avoid breaking the signature of make_pkg_json
# and avoid adding an explicit field for cgo output files in the pkg.json.
def make_pkg_json_with_archive(ctx, name, archive, pkg_id = None, imports = None):
    pkg_json_file = ctx.actions.declare_file(name + ".pkg.json")
    write_pkg_json(ctx, ctx.executable._pkgjson, archive, pkg_json_file, pkg_id, imports)
    return pkg_json_file

# A go_test recompiles every dependency of its external test archive that
# transitively imports the library under test, against the internal test
# archive instead of the library (_recompile_external_deps in test.bzl), the
# way `go test` builds "foo [foo.test]" variants. Those archives are packages
# of their own to go/packages: their export data was compiled against the
# internal archive, and a consumer that keys types by import path must see
# exactly one version of the library under test in the external test
# package's dependency graph. They get the test's label appended to their ID.
def _is_recompiled(dep_archive, test_label):
    return dep_archive.data.label != test_label and ".recompile" in dep_archive.data.file.basename

def _dep_pkg_id(dep_archive, test_label):
    if _is_recompiled(dep_archive, test_label):
        return "%s [%s]" % (dep_archive.data.label, test_label)
    return str(dep_archive.data.label)

def _dep_imports(dep_archive, test_label):
    return {dep.data.importpath: _dep_pkg_id(dep, test_label) for dep in dep_archive.direct}

# deprecated: use make_pkg_json_with_archive instead
def make_pkg_json(ctx, name, pkg_info):
    pkg_json_file = ctx.actions.declare_file(name + ".pkg.json")
    ctx.actions.write(pkg_json_file, content = json.encode(pkg_info))
    return pkg_json_file

def _go_pkg_info_aspect_impl(target, ctx):
    # Fetch the stdlib JSON file from the inner most target
    stdlib_json_file = None
    stdlib_cache_dir = None

    transitive_json_files = []
    transitive_export_files = []
    transitive_compiled_go_files = []

    for attr in DEPS_ATTRS + PROTO_COMPILER_ATTRS:
        deps = getattr(ctx.rule.attr, attr, []) or []

        # Some attrs are not iterable, ensure that deps is always iterable.
        if type(deps) != type([]):
            deps = [deps]

        for dep in deps:
            if GoPkgInfo in dep:
                pkg_info = dep[GoPkgInfo]
                if attr == "embed":
                    # An embedded library's sources are compiled into this
                    # target's archive, which is the package go/packages sees;
                    # its own archive is imported by nothing, and may not even
                    # build: a go_proto_library embedded into the go_library
                    # that defines the types its generated code refers to
                    # fails on its own. Take what it collected from its
                    # dependencies, but do not ask for its archive.
                    transitive_json_files.append(pkg_info.transitive_pkg_json_files)
                    transitive_compiled_go_files.append(pkg_info.transitive_compiled_go_files)
                    transitive_export_files.append(pkg_info.transitive_export_files)
                else:
                    transitive_json_files.append(pkg_info.pkg_json_files)
                    transitive_compiled_go_files.append(pkg_info.compiled_go_files)
                    transitive_export_files.append(pkg_info.export_files)

                # Fetch the stdlib json from the first dependency
                if not stdlib_json_file:
                    stdlib_json_file = pkg_info.stdlib_json_file
                    stdlib_cache_dir = pkg_info.stdlib_cache_dir

    pkg_json_files = []
    compiled_go_files = []
    export_files = []

    if GoArchive in target:
        archive = target[GoArchive]
        if ctx.rule.kind != "go_test":
            compiled_go_files.extend(archive.source.srcs)
            if archive.data.cgo_out_dir:
                compiled_go_files.append(archive.data.cgo_out_dir)
            export_files.append(archive.data.export_file)
            pkg_json_files.append(make_pkg_json_with_archive(ctx, archive.data.name, archive))
        else:
            # A go_test's own archive is the generated test main: of no use to
            # go/packages, and labelled like the internal archive below, so
            # writing it too made two packages claim one ID and left the
            # driver with whichever JSON it read last.
            # A go_test compiles two archives under the test's own label: the
            # internal one, the library plus its in-package test files, and
            # the external one, the "<package>_test" test files, which imports
            # the internal one. The driver builds the external test package
            # out of the internal archive's file list (MoveTestFiles), but the
            # internal archive's imports are not a complete record of what
            # those files may import: rules_go drops from the internal archive
            # every dependency that would form a cycle through the library
            # under test (_recompile_external_deps). So the external archive is
            # written too, under the ID the driver gives that package, for its
            # imports.
            test_label = archive.data.label
            test_archives = [a for a in archive.direct if a.data.label == test_label]
            recompiled = []
            for dep_archive in test_archives:
                is_external = any([dep_archive.data.name == a.data.name + "_test" for a in test_archives])
                pkg_id = str(test_label) + ("_xtest" if is_external else "")
                imports = _dep_imports(dep_archive, test_label) if is_external else None
                pkg_json_files.append(make_pkg_json_with_archive(ctx, dep_archive.data.name, dep_archive, pkg_id, imports))
                compiled_go_files.extend(dep_archive.source.srcs)
                if dep_archive.data.cgo_out_dir:
                    compiled_go_files.append(dep_archive.data.cgo_out_dir)
                export_files.append(dep_archive.data.export_file)
                if is_external:
                    recompiled.extend(dep_archive.direct)

            # The recompiled dependencies of the external archive (see
            # _is_recompiled). A dependency that was not recompiled does not
            # reach the library under test, so neither does anything below it,
            # and the walk stops there. Starlark has no recursion; the loop
            # bound only has to exceed the number of recompiled archives.
            seen = {}
            for _ in range(100000):
                if not recompiled:
                    break
                dep_archive = recompiled.pop()
                if not _is_recompiled(dep_archive, test_label):
                    continue
                pkg_id = _dep_pkg_id(dep_archive, test_label)
                if pkg_id in seen:
                    continue
                seen[pkg_id] = True
                name = "%s.%s" % (test_label.name, dep_archive.data.file.basename)
                pkg_json_files.append(make_pkg_json_with_archive(ctx, name, dep_archive, pkg_id, _dep_imports(dep_archive, test_label)))
                if dep_archive.data.cgo_out_dir:
                    compiled_go_files.append(dep_archive.data.cgo_out_dir)
                export_files.append(dep_archive.data.export_file)
                recompiled.extend(dep_archive.direct)

    # If there was no stdlib json in any dependencies, fetch it from the
    # current go_ node.
    if not stdlib_json_file:
        stdlib_json_file = ctx.attr._go_stdlib[GoStdLib]._list_json
        stdlib_cache_dir = ctx.attr._go_stdlib[GoStdLib].cache_dir

    # The transitive_* sets leave out this target's own files, for a target
    # that embeds this one (see the embed case above).
    pkg_info = GoPkgInfo(
        stdlib_json_file = stdlib_json_file,
        stdlib_cache_dir = stdlib_cache_dir,
        pkg_json_files = depset(
            direct = pkg_json_files,
            transitive = transitive_json_files,
        ),
        compiled_go_files = depset(
            direct = compiled_go_files,
            transitive = transitive_compiled_go_files,
        ),
        export_files = depset(
            direct = export_files,
            transitive = transitive_export_files,
        ),
        transitive_pkg_json_files = depset(transitive = transitive_json_files),
        transitive_compiled_go_files = depset(transitive = transitive_compiled_go_files),
        transitive_export_files = depset(transitive = transitive_export_files),
    )

    return [
        pkg_info,
        OutputGroupInfo(
            go_pkg_driver_json_file = pkg_info.pkg_json_files,
            go_pkg_driver_srcs = pkg_info.compiled_go_files,
            go_pkg_driver_export_file = pkg_info.export_files,
            go_pkg_driver_stdlib_json_file = depset([pkg_info.stdlib_json_file] if pkg_info.stdlib_json_file else []),
            go_pkg_driver_stdlib_cache_dir = pkg_info.stdlib_cache_dir or depset([]),
        ),
    ]

go_pkg_info_aspect = aspect(
    implementation = _go_pkg_info_aspect_impl,
    attr_aspects = DEPS_ATTRS + PROTO_COMPILER_ATTRS,
    attrs = {
        "_go_stdlib": attr.label(
            default = "//:stdlib",
        ),
        "_pkgjson": attr.label(
            executable = True,
            cfg = "exec",
            default = Label("//go/tools/gopackagesdriver/pkgjson:reset_pkgjson"),
        ),
    },
)
