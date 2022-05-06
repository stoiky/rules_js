const { writeFileSync } = require('fs')
const { join } = require('path')

const prod = !!process.env.TRANSLATE_PACKAGE_LOCK_PROD
const dev = !!process.env.TRANSLATE_PACKAGE_LOCK_DEV
const noOptional = !!process.env.TRANSLATE_PACKAGE_LOCK_NO_OPTIONAL

function getDirectDependencies(lockfile, packageDep = false) {
    let packageDependencies = {}
    let directDependencies = []
    const lockDependencies = {
        ...(!prod && lockfile.devDependencies ? lockfile.devDependencies : {}),
        ...(!dev && lockfile.dependencies ? lockfile.dependencies : {}),
        ...(!noOptional && lockfile.optionalDependencies
            ? lockfile.optionalDependencies
            : {}),
    }
    for (const name of Object.keys(lockDependencies)) {
        let constructName = pnpmName(name, lockDependencies[name])
        if (packageDep) {
            const [name, pnpmVersion] = parsePnpmName(constructName)
            packageDependencies[name] = pnpmVersion
        } else {
            directDependencies.push(constructName)
        }
    }
    if (packageDep) {
        return packageDependencies
    } else {
        return directDependencies
    }
}

function getPackageFromAlias(name, version) {
    // An alias, use it
    if (alias.charAt(0) === "/") {
        const [aliasName, aliasVersion] = parsePnpmName(version)
        name = aliasName.substring(1)
        version = aliasVersion
    }
    return [name, version]
}

function pnpmName(name, version) {
    // Make a name/version pnpm-style name for a package name and version
    // (matches pnpm_name in js/private/pnpm_utils.bzl)

    if (version.startsWith("link:")) {
        version = "workspace"
    }

    return `${name}/${version}`
}

function parsePnpmName(pnpmName) {
    // Parse a name/version or @scope/name/version string and return
    // a [name, version] list
    const segments = pnpmName.split('/')
    if (segments.length != 2 && segments.length != 3) {
        console.error(`unexpected pnpm versioned name ${pnpmName}`)
        process.exit(1)
    }
    const version = segments.pop()
    const name = segments.join('/')
    return [name, version]
}

function gatherTransitiveClosure(
    packages,
    noOptional,
    deps,
    transitiveClosure
) {
    if (!deps) {
        return
    }
    for (let name of Object.keys(deps)) {
        let version = deps[name]

        // An alias, use it
        if (version.charAt(0) === "/") {
            const [aliasName, aliasVersion] = parsePnpmName(version)
            name = aliasName.substring(1)
            version = aliasVersion
        }

        if (!transitiveClosure[name]) {
            transitiveClosure[name] = []
        }
        if (transitiveClosure[name].includes(version)) {
            continue
        }
        transitiveClosure[name].push(version)

        const packageInfo = packages[pnpmName(name, version)]
        const dependencies = noOptional
            ? packageInfo.dependencies
            : {
                  ...packageInfo.dependencies,
                  ...packageInfo.optionalDependencies,
              }
        gatherTransitiveClosure(
            packages,
            noOptional,
            dependencies,
            transitiveClosure
        )
    }
}

async function main(argv) {
    if (argv.length !== 3) {
        console.error(
            'Usage: node translate_pnpm_lock.js [pnpmLockJson] [outputJson] [workspacePath]'
        )
        process.exit(1)
    }
    const pnpmLockJson = argv[0]
    const outputJson = argv[1]
    const workspacePath = argv[2]

    const lockfile = require(pnpmLockJson)

    const lockVersion = lockfile.lockfileVersion
    if (!lockVersion) {
        console.error('unknown lockfile version')
        process.exit(1)
    }

    // TODO: support a range: lockVersion >= 5.3 and lockVersion < 6.0
    const expectedLockVersion = '5.3'
    if (lockVersion != expectedLockVersion) {
        console.error(
            `translate_pnpm_lock expected pnpm lockfile version ${expectedLockVersion}, found ${lockVersion}`
        )
        process.exit(1)
    }

    const lockPackages = lockfile.packages
    if (!lockPackages) {
        console.error('no packages in lockfile')
        process.exit(1)
    }

    let importers = {}
    let packages = {}
    let directDependencies = []
    if (lockfile.specifiers) {
        // If there's one single project in the lockfile
        // we will find 'specifiers' there along 'dependencies' etc
        directDependencies = getDirectDependencies(lockfile)
    } else if (lockfile.importers) {
        // If there are multiple projects in the lockfile
        // they will be under the 'importers' key
        for (var importer_name in lockfile.importers) {
            let importer_info = lockfile.importers[importer_name];
            // Root level project, if there is none, this should be skipped
            if (importer_name == "." && Object.keys(importer_info.specifiers).length === 0) {
                continue
            }
            project_path = importer_name.slice("../../".length) // get this programatically
            project_package = require(join(workspacePath, project_path, "package.json"))
            project_name = project_package["name"]
            project_version = "workspace"
            packages[join(project_name, project_version)] = {
                name: project_name,
                pnpmVersion: project_version,
                integrity: join(workspacePath, project_path),
                dependencies: getDirectDependencies(importer_info, true) || {},
                dev: !!importer_info.dev,
                optional: !!importer_info.optional,
                hasBin: !!importer_info.hasBin,
                requiresBuild: !!importer_info.requiresBuild,
            }
            directDependencies = directDependencies.concat(getDirectDependencies(importer_info))
        }
    } else {
        console.error('no specifiers or importers in lockfile')
        process.exit(2)
    }

    // writeFileSync("importers.json", JSON.stringify(importers, null, 2))

    for (const packagePath of Object.keys(lockPackages)) {
        const packageSnapshot = lockPackages[packagePath]
        if (!packagePath.startsWith('/')) {
            console.error(`unsupported package path ${packagePath}`)
            process.exit(1)
        }
        const package = packagePath.slice(1)
        const [name, pnpmVersion] = parsePnpmName(package)
        const resolution = packageSnapshot.resolution
        if (!resolution) {
            console.error(`package ${packagePath} has no resolution field`)
            process.exit(1)
        }
        const integrity = resolution.integrity
        if (!integrity) {
            console.error(`package ${packagePath} has no integrity field`)
            process.exit(1)
        }
        const dev = !!packageSnapshot.dev
        const optional = !!packageSnapshot.optional
        const hasBin = !!packageSnapshot.hasBin
        const requiresBuild = !!packageSnapshot.requiresBuild
        const dependencies = packageSnapshot.dependencies || {}
        const optionalDependencies = packageSnapshot.optionalDependencies || {}
        packages[package] = {
            name,
            pnpmVersion,
            integrity,
            dependencies,
            optionalDependencies,
            dev,
            optional,
            hasBin,
            requiresBuild,
        }
    }

    writeFileSync("packages.json", JSON.stringify(packages, null, 2))

    for (const package of Object.keys(packages)) {
        const packageInfo = packages[package]
        const transitiveClosure = {}
        transitiveClosure[packageInfo.name] = [packageInfo.pnpmVersion]
        const dependencies = noOptional
            ? packageInfo.dependencies
            : {
                  ...packageInfo.dependencies,
                  ...packageInfo.optionalDependencies,
              }
        gatherTransitiveClosure(
            packages,
            noOptional,
            dependencies,
            transitiveClosure
        )
        packageInfo.transitiveClosure = transitiveClosure
    }

    console.log("unique directDependencies", [...new Set(directDependencies)].length)

    result = { dependencies: [...new Set(directDependencies)], packages }

    writeFileSync(outputJson, JSON.stringify(result, null, 2))
}

; (async () => {
    await main(process.argv.slice(2))
})()
