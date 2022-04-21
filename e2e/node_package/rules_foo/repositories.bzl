"Shows how a custom ruleset can export its npm dependencies"

load("@aspect_rules_js//js:npm_import.bzl", "translate_pnpm_lock")

def repositories():
    translate_pnpm_lock(
        name = "rules_foo_npm",
        # yq -o=json -I=2 '.' pnpm-lock.yaml > pnpm-lock.json
        pnpm_lock = "@rules_foo//foo:pnpm-lock.json",
    )
