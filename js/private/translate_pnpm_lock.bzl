"Convert pnpm lock file into starlark Bazel fetches"

load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@bazel_skylib//lib:paths.bzl", "paths")
load(":npm_utils.bzl", "npm_utils")

_DOC = """Repository rule to generate npm_import rules from pnpm lock file.

The pnpm lockfile format includes all the information needed to define npm_import rules,
including the integrity hash, as calculated by the package manager.

For more details see, https://github.com/pnpm/pnpm/blob/main/packages/lockfile-types/src/index.ts.

Instead of manually declaring the `npm_imports`, this helper generates an external repository
containing a helper starlark module `repositories.bzl`, which supplies a loadable macro
`npm_repositories`. This macro creates an `npm_import` for each package.

The generated repository also contains BUILD files declaring targets for the packages
listed as `dependencies` or `devDependencies` in `package.json`, so you can declare
dependencies on those packages without having to repeat version information.

Bazel will only fetch the packages which are required for the requested targets to be analyzed.
Thus it is performant to convert a very large package-lock.json file without concern for
users needing to fetch many unnecessary packages.

**Setup**

In `WORKSPACE`, call the repository rule pointing to your package-lock.json file:

```starlark
load("@aspect_rules_js//js:npm_import.bzl", "translate_pnpm_lock")

# Read the pnpm-lock.json file to automate creation of remaining npm_import rules
translate_pnpm_lock(
    # Creates a new repository named "@npm_deps"
    name = "npm_deps",
    pnpm_lock = "//:pnpm-lock.json",
)
```

Next, there are two choices, either load from the generated repo or check in the generated file.
The tradeoffs are similar to
[this rules_python thread](https://github.com/bazelbuild/rules_python/issues/608).

1. Immediately load from the generated `repositories.bzl` file in `WORKSPACE`.
This is similar to the 
[`pip_parse`](https://github.com/bazelbuild/rules_python/blob/main/docs/pip.md#pip_parse)
rule in rules_python for example.
It has the advantage of also creating aliases for simpler dependencies that don't require
spelling out the version of the packages.
However it causes Bazel to eagerly evaluate the `translate_pnpm_lock` rule for every build,
even if the user didn't ask for anything JavaScript-related.

```starlark
load("@npm_deps//:repositories.bzl", "npm_repositories")

npm_repositories()
```

In BUILD files, declare dependencies on the packages using the same external repository.

Following the same example, this might look like:

```starlark
nodejs_test(
    name = "test_test",
    data = ["@npm_deps//@types/node"],
    entry_point = "test.js",
)
```

2. Check in the `repositories.bzl` file to version control, and load that instead.
This makes it easier to ship a ruleset that has its own npm dependencies, as users don't
have to install those dependencies. It also avoids eager-evaluation of `translate_pnpm_lock`
for builds that don't need it.
This is similar to the [`update-repos`](https://github.com/bazelbuild/bazel-gazelle#update-repos)
approach from bazel-gazelle.

In a BUILD file, use a rule like
[write_source_files](https://github.com/aspect-build/bazel-lib/blob/main/docs/write_source_files.md)
to copy the generated file to the repo and test that it stays updated:

```starlark
write_source_files(
    name = "update_repos",
    files = {
        "repositories.bzl": "@npm_deps//:repositories.bzl",
    },
)
```

Then in `WORKSPACE`, load from that checked-in copy or instruct your users to do so.
In this case, the aliases are not created, so you get only the `npm_import` behavior
and must depend on packages with their versioned label like `@npm__types_node-15.12.2`.
"""

_ATTRS = {
    "pnpm_lock": attr.label(
        doc = """The pnpm-lock.json file.""",
        mandatory = True,
    ),
    "package": attr.string(
        default = ".",
        doc = """The package to "link" the generated npm dependencies to. By default, the package of the pnpm_lock
        target is used.""",
    ),
    "patches": attr.string_list_dict(
        doc = """A map of package names or package names with their version (e.g., "my-package" or "my-package@v1.2.3")
        to a label list of patches to apply to the downloaded npm package. Paths in the patch
        file must start with `extract_tmp/package` where `package` is the top-level folder in
        the archive on npm. If the version is left out of the package name, the patch will be
        applied to every version of the npm package.""",
    ),
    "patch_args": attr.string_list_dict(
        doc = """A map of package names or package names with their version (e.g., "my-package" or "my-package@v1.2.3")
        to a label list arguments to pass to the patch tool. Defaults to -p0, but -p1 will
        usually be needed for patches generated by git. If patch args exists for a package
        as well as a package version, then the version-specific args will be appended to the args for the package.""",
    ),
    "prod": attr.bool(
        doc = """If true, only install dependencies""",
    ),
    "dev": attr.bool(
        doc = """If true, only install devDependencies""",
    ),
    "no_optional": attr.bool(
        doc = """If true, optionalDependencies are not installed""",
    ),
}

def _user_workspace_root(repository_ctx):
    pnpm_lock = repository_ctx.attr.pnpm_lock
    segments = []
    if pnpm_lock.package:
        segments.extend(pnpm_lock.package.split("/"))
    segments.extend(pnpm_lock.name.split("/"))
    segments.pop()
    user_workspace_root = repository_ctx.path(pnpm_lock).dirname
    for i in segments:
        user_workspace_root = user_workspace_root.dirname
    return str(user_workspace_root)

def _get_local_package(repository_ctx, project_path):
    keys_to_extract = ["name", "version"]
    path = paths.join(_user_workspace_root(repository_ctx), project_path, "package.json")
    package_json = json.decode(repository_ctx.read(path))
    return {key: package_json[key] for key in keys_to_extract}

def _get_direct_dependencies(info, prod, dev, no_optional):
    direct_dependencies = []
    lock_dependencies = {}
    if not prod:
        lock_dependencies = dicts.add(lock_dependencies, info.get("devDependencies", {}))
    if not dev:
        lock_dependencies = dicts.add(lock_dependencies, info.get("dependencies", {}))
    if not no_optional:
        lock_dependencies = dicts.add(lock_dependencies, info.get("optionalDependencies", {}))
    if not lock_dependencies:
        print("no direct dependencies to translate in lockfile")

    for (dep_name, dep_version) in lock_dependencies.items():
        print(npm_utils.versioned_name(dep_name, dep_version))
        direct_dependencies.append(npm_utils.versioned_name(dep_name, dep_version))
    return direct_dependencies

def _process_lockfile(rctx, lockfile, prod, dev, no_optional):
    lock_version = lockfile.get("lockfileVersion")
    if not lock_version:
        fail("unknown lockfile version")

    # We don't test this program with spec versions other than 5.3, so just error.
    # If users hit this we can add test coverage and expand the supported range.
    if str(lock_version) != "5.3":
        msg = "translate_pnpm_lock only works with pnpm lockfile version 5.3, found %s" % lock_version
        fail(msg)

    # If there's one single project in the lockfile
    # we will find 'specifiers' there along 'dependencies' etc
    if "specifiers" in lockfile:
        direct_dependencies = _get_direct_dependencies(lockfile, prod, dev, no_optional)
    # If there are multiple projects in the lockfile
    # they will be under the 'importers' key
    elif "importers" in lockfile:
        lock_importers = lockfile.get("importers")
        for (importer_name, importer_info) in lock_importers.items():
            # Root level project, if there is none, this should be skipped
            if (importer_name == "." and len(importer_info["specifiers"]) == 0):
                continue
            direct_dependencies = _get_direct_dependencies(importer_info, prod, dev, no_optional) 
    else:
        direct_dependencies = []
        # not yet sure if there is such a scenario
        fail("scenario not covered, exit with error")

    lock_packages = lockfile.get("packages")
    if not lock_packages:
        fail("no packages in lockfile")

    packages = {}

    for (packagePath, packageSnapshot) in lock_packages.items():
        if not packagePath.startswith("/"):
            msg = "unsupported package path %s" % packagePath
            fail(msg)
        path_segments = packagePath[1:].split("/")
        if len(path_segments) != 2 and len(path_segments) != 3:
            msg = "unsupported package path %s" % packagePath
            fail(msg)
        package_name = "/".join(path_segments[0:-1])
        package_version = path_segments[-1].replace("@", "_at_").replace("+","-")
        resolution = packageSnapshot.get("resolution")
        if not resolution:
            msg = "package %s has no resolution field" % packagePath
            fail(msg)
        integrity = resolution.get("integrity")
        if not integrity:
            msg = "package %s resolution has no integrity field" % packagePath
            fail(msg)
        dev = resolution.get("dev", False)
        optional = resolution.get("optional", False)
        has_bin = resolution.get("hasBin", False)
        requires_build = resolution.get("requiresBuild", False)
        package = {
            "name": package_name,
            "version": package_version,
            "integrity": integrity,
            "dependencies": {},
            "dev": dev,
            "optional": optional,
            "has_bin": has_bin,
            "requires_build":  requires_build
        }
        dependencies = []
        package_deps = packageSnapshot.get("dependencies")
        if package_deps:
            for (dep_name, dep_version) in package_deps.items():
                dependencies.append(npm_utils.versioned_name(dep_name, dep_version))
        if dependencies:
            package["dependencies"] = dependencies
        packages[npm_utils.versioned_name(package_name, package_version)] = package

    return {
        "dependencies": direct_dependencies,
        "packages": packages,
    }

_NPM_IMPORT_TMPL = \
"""    npm_import(
        name = "{name}",
        integrity = "{integrity}",
        link_package_guard = "{link_package_guard}",
        package_name = "{package_name}",
        package_version = "{package_version}",
        namespace = "{namespace}",
        {maybe_deps}{maybe_transitive}{maybe_patches}{maybe_patch_args}
    )
"""

_ALIAS_TMPL = \
"""load("//:package.bzl", "package", "package_dir")

alias(
    name = "{basename}",
    actual = package("{name}"),
    visibility = ["//visibility:public"],
)

alias(
    name = "dir",
    actual = package_dir("{name}"),
    visibility = ["//visibility:public"],
)"""

_PACKAGE_TMPL = \
"""
load("@aspect_rules_js//js/private:npm_utils.bzl", "npm_utils")

def package(name):
    return Label("@//{link_package}:" + npm_utils.alias_target_name(\"{namespace}\", name))

def package_dir(name):
    return Label("@//{link_package}:" + npm_utils.alias_target_name(\"{namespace}\", name) + "__dir")
"""

def _impl(rctx):
    if rctx.attr.prod and rctx.attr.dev:
        fail("prod and dev attributes cannot both be set to true")

    lockfile = _process_lockfile(
        rctx = rctx,
        lockfile = json.decode(rctx.read(rctx.attr.pnpm_lock)),
        prod = rctx.attr.prod,
        dev = rctx.attr.dev,
        no_optional = rctx.attr.no_optional,
    )

    link_package = rctx.attr.package
    if link_package == ".":
        link_package = rctx.attr.pnpm_lock.package

    direct_dependencies = lockfile.get("dependencies")
    packages = lockfile.get("packages")

    repositories_bzl = [
        """load("@aspect_rules_js//js:npm_import.bzl", "npm_import")""",
        "",
        "def npm_repositories():",
    ]

    nodejs_packages_header_bzl = []
    nodejs_packages_bzl = ["def nodejs_packages():"]

    for (i, v) in enumerate(packages.items()):
        (versioned_name, package) = v
        name = package.get("name")
        version = package.get("version")
        deps = package.get("dependencies")
        dev = package.get("dev")
        optional = package.get("optional")
        has_bin = package.get("has_bin")
        requires_build = package.get("requires_build")

        if rctx.attr.prod and dev:
            # when prod attribute is set, skip devDependencies
            continue
        if rctx.attr.dev and not dev:
            # when dev attribute is set, skip (non-dev) dependencies
            continue
        if rctx.attr.no_optional and optional:
            # when no_optional attribute is set, skip optionalDependencies
            continue

        patches = rctx.attr.patches.get(name, [])[:]
        patches.extend(rctx.attr.patches.get(versioned_name, []))

        patch_args = rctx.attr.patch_args.get(name, [])[:]
        patch_args.extend(rctx.attr.patch_args.get(versioned_name, []))

        repo_name = "%s__%s" % (rctx.name, npm_utils.bazel_name(name, version))

        transitive = False if versioned_name in direct_dependencies else True

        repositories_bzl.append(_NPM_IMPORT_TMPL.format(
            name = repo_name,
            link_package_guard = link_package,
            package_name = name,
            package_version = version,
            integrity = package.get("integrity"),
            namespace = rctx.name,
            maybe_transitive = """
        transitive = True,""" if transitive else "",
            maybe_deps = ("""
        deps = %s,""" % deps) if len(deps) > 0 else "",
            maybe_patches = ("""
        patches = %s,""" % patches) if len(patches) > 0 else "",
            maybe_patch_args = ("""
        patch_args = %s,""" % patch_args) if len(patches) > 0 and len(patch_args) > 0 else "",
        ))

        nodejs_packages_header_bzl.append(
            """load("@{repo_name}//:nodejs_package.bzl", nodejs_package_{i} = "nodejs_package")""".format(
                i = i,
                repo_name = repo_name,
            ))
        nodejs_packages_bzl.append("    nodejs_package_{i}()".format(i = i))

        if not transitive:
            # For direct dependencies create alias targets @repo_name//name, @repo_name//@scope/name,
            # @repo_name//name:dir and @repo_name//@scope/name:dir
            rctx.file("%s/BUILD.bazel" % name, _ALIAS_TMPL.format(
            basename = paths.basename(name),
            name = name,
        ))

    package_bzl = [_PACKAGE_TMPL.format(
        link_package = link_package,
        namespace = rctx.name,
    )]

    generated_by_line = ["# @generated by translate_pnpm_lock.bzl from {pnpm_lock}\"".format(pnpm_lock = str(rctx.attr.pnpm_lock))]
    empty_line = [""]

    rctx.file("repositories.bzl", "\n".join(generated_by_line + repositories_bzl))
    rctx.file("nodejs_packages.bzl", "\n".join(generated_by_line + nodejs_packages_header_bzl + empty_line + nodejs_packages_bzl + empty_line))
    rctx.file("package.bzl", "\n".join(generated_by_line + package_bzl))
    rctx.file("BUILD.bazel", "")

translate_pnpm_lock = struct(
    doc = _DOC,
    implementation = _impl,
    attrs = _ATTRS,
)

translate_pnpm_lock_testonly = struct(
    testonly_process_lockfile = _process_lockfile,
)
