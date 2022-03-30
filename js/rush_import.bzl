"repository rules for importing packages from rush lib"

load("@bazel_skylib//lib:paths.bzl", "paths")
load("//js/private:translate_rush.bzl", lib = "translate_rush")

_WORKSPACE_REROOTED_PATH = "_"

# Returns the path to a file within the re-rooted user workspace
# under _WORKSPACE_REROOTED_PATH in this repo rule's external workspace
def _rerooted_workspace_path(repository_ctx, f):
    return paths.normalize(paths.join(_WORKSPACE_REROOTED_PATH, f.package, f.name))

# Returns the path to the package.json directory within the re-rooted user workspace
# under _WORKSPACE_REROOTED_PATH in this repo rule's external workspace
def _rerooted_workspace_package_json_dir(repository_ctx):
    return str(repository_ctx.path(_rerooted_workspace_path(repository_ctx, repository_ctx.attr.package_json)).dirname)


def _rush_import_impl(repository_ctx):

    repository_ctx.file("BUILD.bazel", """
load("@aspect_rules_js//js:nodejs_package.bzl", "nodejs_package")
load("@rules_nodejs//third_party/github.com/bazelbuild/bazel-skylib:rules/copy_file.bzl", "copy_file")

# Turn a source directory into a TreeArtifact for RBE-compat
copy_file(
    # The default target in this repository
    name = "_{name}",
    src = "{nested_folder}",
    # This attribute comes from rules_nodejs patch of
    # https://github.com/bazelbuild/bazel-skylib/pull/323
    is_directory = True,
    # We must give this as the directory in order for it to appear on NODE_PATH
    out = "{package_name}",
)

nodejs_package(
    name = "{name}",
    src = "_{name}",
    package_name = "{package_name}",
    visibility = ["//visibility:public"],
    deps = {deps},
)

# The name of the repo can be affected by repository mapping and may not match
# our declared "npm_foo-1.2.3" naming. So give a stable label as well to use
# when declaring dependencies between packages.
alias(
    name = "pkg",
    actual = "{name}",
    visibility = ["//visibility:public"],
)
""".format(
        name = repository_ctx.name,
        nested_folder = "./",
        # nested_folder = result.stdout.rstrip("\n"),
        package_name = repository_ctx.attr.package,
        deps = [str(d.relative(":pkg")) for d in repository_ctx.attr.deps],
    ))

_rush_import = repository_rule(
    implementation = _rush_import_impl,
    attrs = {
        "deps": attr.label_list(),
        "integrity": attr.string(),
        "package": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "patches": attr.label_list(),
    },
)

def rush_import(integrity, package, version, deps = [], name = None, patches = []):
    """Import a single npm package into Bazel.

    Normally you'd want to use `translate_package_lock` to import all your packages at once.
    It generates `rush_import` rules.
    You can create these manually if you want to have exact control.

    Bazel will only fetch the given package from an external registry if the package is
    required for the user-requested targets to be build/tested.
    The package will be exposed as a [`nodejs_package`](./nodejs_package) rule in a repository
    with a default name `@npm_[package name]-[version]`, as the default target in that repository.
    (Characters in the package name which are not legal in Bazel repository names are converted to underscore.)

    This is a repository rule, which should be called from your `WORKSPACE` file
    or some `.bzl` file loaded from it. For example, with this code in `WORKSPACE`:

    ```starlark
    rush_import(
        integrity = "sha512-zjQ69G564OCIWIOHSXyQEEDpdpGl+G348RAKY0XXy9Z5kU9Vzv1GMNnkar/ZJ8dzXB3COzD9Mo9NtRZ4xfgUww==",
        package = "@types/node",
        version = "15.12.2",
    )
    ```

    you can use the label `@npm__types_node-15.12.2` in your BUILD files to reference the package.

    > This is similar to Bazel rules in other ecosystems named "_import" like
    > `apple_bundle_import`, `scala_import`, `java_import`, and `py_import`
    > `go_repository` is also a model for this rule.

    The name of this repository should contain the version number, so that multiple versions of the same
    package don't collide.
    (Note that the npm ecosystem always supports multiple versions of a library depending on where
    it is required, unlike other languages like Go or Python.)

    To change the proxy URL we use to fetch, configure the Bazel downloader:
    1. Make a file containing a rewrite rule like

       rewrite (registry.nodejs.org)/(.*) artifactory.build.internal.net/artifactory/$1/$2

    1. To understand the rewrites, see [UrlRewriterConfig] in Bazel sources.

    1. Point bazel to the config with a line in .bazelrc like
        common --experimental_downloader_config=.bazel_downloader_config

    [UrlRewriterConfig]: https://github.com/bazelbuild/bazel/blob/4.2.1/src/main/java/com/google/devtools/build/lib/bazel/repository/downloader/UrlRewriterConfig.java#L66

    Args:
        name: the external repository generated to contain the package content.
            This argument may be omitted to get the default name documented above.
        deps: other npm packages this one depends on.
        integrity: Expected checksum of the file downloaded, in Subresource Integrity format.
            This must match the checksum of the file downloaded.

            This is the same as appears in the yarn.lock or package-lock.json file.

            It is a security risk to omit the checksum as remote files can change.
            At best omitting this field will make your build non-hermetic.
            It is optional to make development easier but should be set before shipping.
        package: npm package name, such as `acorn` or `@types/node`
        version: version of the npm package, such as `8.4.0`
        patches: patch files to apply onto the downloaded npm package.
            Paths in the patch file must start with `extract_tmp/package`
            where `package` is the top-level folder in the archive on npm.
    """

    _rush_import(
        name = name or lib.repository_name(package, version),
        deps = deps,
        integrity = integrity,
        package = package,
        patches = patches,
        version = version,
    )

translate_rush = repository_rule(
    doc = lib.doc,
    implementation = lib.implementation,
    attrs = lib.attrs,
)
