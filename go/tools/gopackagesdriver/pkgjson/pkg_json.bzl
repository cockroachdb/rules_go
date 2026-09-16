load(
    "@bazel_skylib//lib:paths.bzl",
    "paths",
)

def write_pkg_json(ctx, pkg_json_tool, archive, pkg_json, pkg_id = None, imports = None):
    """Writes the go/packages JSON for archive to pkg_json.

    Args:
      ctx: the aspect context.
      pkg_json_tool: the pkgjson executable, which fills in cgo-generated files.
      archive: the GoArchive to describe.
      pkg_json: the output file.
      pkg_id: the package ID; defaults to the archive's label. A go_test's
        external test archive shares the test's label with the internal one
        and is written under the label plus "_xtest".
      imports: the package's imports, import path to package ID; defaults to
        the labels of the archive's direct dependencies. A go_test's external
        archive and its recompiled dependencies import the recompiled variants
        of their dependencies, which have IDs of their own.
    """
    args = ctx.actions.args()
    inputs = [src for src in archive.data.srcs if src.path.endswith(".go")]

    tmp_json = ctx.actions.declare_file(pkg_json.path + ".tmp")
    pkg_info = _go_archive_to_pkg(archive, pkg_id, imports)
    ctx.actions.write(tmp_json, content = json.encode(pkg_info))
    inputs.append(tmp_json)
    args.add("--pkg_json", tmp_json.path)

    if archive.data.cgo_out_dir:
        inputs.append(archive.data.cgo_out_dir)
        args.add("--cgo_out_dir", file_path(archive.data.cgo_out_dir))

    args.add("--output", pkg_json.path)
    ctx.actions.run(
        inputs = inputs,
        outputs = [pkg_json],
        executable = pkg_json_tool.path,
        arguments = [args],
        tools = [pkg_json_tool],
    )

def file_path(f):
    prefix = "__BAZEL_WORKSPACE__"
    if not f.is_source:
        prefix = "__BAZEL_EXECROOT__"
    elif is_file_external(f):
        prefix = "__BAZEL_OUTPUT_BASE__"
    return paths.join(prefix, f.path)

def is_file_external(f):
    return f.owner.workspace_root != ""

def _go_archive_to_pkg(archive, pkg_id = None, imports = None):
    go_files = [
        file_path(src)
        for src in archive.data.srcs
        if src.path.endswith(".go")
    ]
    if imports == None:
        imports = {
            pkg.data.importpath: str(pkg.data.label)
            for pkg in archive.direct
        }
    return struct(
        ID = pkg_id or str(archive.data.label),
        # go/packages defines PkgPath as the path go/types knows the package
        # by, which is the one the compiler was given (-p, rules_go's
        # importmap), not the one import statements name (importpath). The
        # two differ for a library that embeds one with another import path:
        # it inherits the embedded library's importmap, and export data
        # readers keyed by path then find nothing under the importpath.
        # Imports stay keyed by importpath, as import statements are.
        PkgPath = archive.data.importmap or archive.data.importpath,
        ExportFile = file_path(archive.data.export_file),
        GoFiles = go_files,
        CompiledGoFiles = go_files,
        OtherFiles = [
            file_path(src)
            for src in archive.data.srcs
            if not src.path.endswith(".go")
        ],
        Imports = imports,
    )
