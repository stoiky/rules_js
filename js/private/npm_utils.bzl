"Utility functions for npm rules"

def _bazel_name(name, version):
    "Make a bazel friendly name from a package name and a version that can be used in repository and target names"
    escaped_name = name.replace("/", "_").replace("@", "at_")
    # print(escaped_name)
    escaped_version = _ensure_not_peer_version(version)
    return "%s_%s" % (escaped_name, escaped_version)

def _versioned_name(name, version):
    "Make a developer-friendly name for a package name and version"
    escaped = _ensure_not_link_version(version)
    return "%s@%s" % (name, _ensure_not_peer_version(escaped))

def _ensure_not_peer_version(version):
    return version.split("_")[0]

def _ensure_not_link_version(version):
    if "link:.." in version:
        return "workspace"
    return version

def _virtual_store_name(name, version):
    "Make a virtual store name for a given package and version"
    escaped = name.replace("/", "+")
    return "%s@%s" % (escaped, version)

def _alias_target_name(name):
    "Make an alias target name for a given package"
    return name.replace("/", "+")

npm_utils = struct(
    bazel_name = _bazel_name,
    versioned_name = _versioned_name,
    virtual_store_name = _virtual_store_name,
    alias_target_name = _alias_target_name,
    ensure_not_peer_version = _ensure_not_peer_version,
    # Prefix namespace to use for generated nodejs_binary targets and aliases
    nodejs_package_target_namespace = "npm",
)
