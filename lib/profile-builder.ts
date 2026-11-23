// Build-time profile composer.
//
// The Nix layer supplies only file paths and the profile declaration; this
// script owns package-root resolution, bundle ordering, projection and the
// final profile manifest.  It intentionally uses Node's builtin modules only.
declare const require: (name: string) => any;
declare const process: any;

const fs: any = require("node:fs");
const path: any = require("node:path");
const { execFileSync }: any = require("node:child_process");

interface NixMetadata {
  packageName: string | null;
  packagePath: string;
  patchPath: string | null;
  explicitPatch: string | null;
}

interface ClassEntry {
  kind: "in-box" | "install-bundle" | "nix";
  name?: string;
  packageName?: string | null;
  packagePath?: string;
  patchPath?: string | null;
}

interface Metadata {
  nixMetadata: NixMetadata[];
  classes: ClassEntry[];
}

interface Options {
  out: string;
  name: string;
  metadata: string;
  template: string;
  templateSource: string;
  install: string;
  patches: string;
  patchSource: string;
  reader: string;
}

function fail(message: string): never {
  console.error(`dsh profile: ${message}`);
  throw new Error(`dsh profile: ${message}`);
}

function parseArgs(argv: string[]): Options {
  const values: Record<string, string> = {};
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i];
    if (!key.startsWith("--") || i + 1 >= argv.length) {
      fail(`invalid argument ${key}`);
    }
    const name = key
      .slice(2)
      .replace(/-([a-z])/g, (_match: string, letter: string) =>
        letter.toUpperCase(),
      );
    values[name] = argv[i + 1];
    i += 1;
  }
  const required = ["out", "name", "metadata", "patches", "reader"] as const;
  for (const key of required) {
    if (values[key] === undefined) fail(`missing --${key}`);
  }
  return {
    out: values.out,
    name: values.name,
    metadata: values.metadata,
    template: values.template ?? "",
    templateSource: values.templateSource ?? "",
    install: values.install ?? "",
    patches: values.patches,
    patchSource: values.patchSource ?? "",
    reader: values.reader,
  };
}

function readJson(file: string, what: string): any {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    fail(`cannot read ${what} at ${file}: ${String(error)}`);
  }
}

function packageManifest(root: string): any | null {
  const file = path.join(root, "package.json");
  if (!fs.existsSync(file)) return null;
  return readJson(file, `package manifest ${file}`);
}

function resolveEffectiveRoot(pkg: string): string {
  if (fs.existsSync(path.join(pkg, "package.json"))) return pkg;
  const modules = path.join(pkg, "lib", "node_modules");
  const candidates: string[] = [];
  if (fs.existsSync(modules)) {
    for (const entry of fs.readdirSync(modules, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      if (entry.name.startsWith("@")) {
        const scope = path.join(modules, entry.name);
        for (const child of fs.readdirSync(scope, { withFileTypes: true })) {
          const candidate = path.join(scope, child.name);
          if (
            child.isDirectory() &&
            fs.existsSync(path.join(candidate, "package.json"))
          ) {
            candidates.push(candidate);
          }
        }
      } else {
        const candidate = path.join(modules, entry.name);
        if (fs.existsSync(path.join(candidate, "package.json")))
          candidates.push(candidate);
      }
    }
  }
  if (candidates.length === 1) return candidates[0];
  if (candidates.length === 0) {
    fail(
      `no package.json at ${pkg}/package.json and no installed package under ${pkg}/lib/node_modules (want exactly one direct root)`,
    );
  }
  fail(
    `ambiguous installed packages under ${pkg}/lib/node_modules (found ${candidates.length}: ${candidates.join(" ")}); pass an explicit installed root path`,
  );
}

function resolveName(meta: NixMetadata, root: string): string {
  if (meta.packageName !== null && meta.packageName !== "")
    return meta.packageName;
  const manifest = packageManifest(root);
  if (
    manifest !== null &&
    typeof manifest.name === "string" &&
    manifest.name !== ""
  ) {
    return manifest.name;
  }
  fail(
    `packageName is required (set it explicitly or provide package.json name) for ${root}`,
  );
}

function hasDeclaredBundle(root: string): boolean {
  const manifest = packageManifest(root);
  return (
    manifest?.dsh?.bundle?.patch !== undefined &&
    manifest?.dsh?.bundle?.patch !== null
  );
}

function templateBundles(options: Options): string[] {
  if (options.template === "") return [];
  if (options.templateSource === "")
    fail(
      `template ${options.template} needs profileMeta or the dsh installation`,
    );
  const meta = path.join(
    options.templateSource,
    "share",
    "dsh-nix",
    "profile-templates.json",
  );
  let result: any;
  if (fs.existsSync(meta)) {
    const templates = readJson(meta, "profile template metadata");
    const entry = templates[options.template];
    result = Array.isArray(entry) ? entry : entry?.bundles;
  } else {
    const compat = path.join(
      options.templateSource,
      "lib",
      "dsh-builtin-compat.cjs",
    );
    const nodeArgs = ["--expose-internals"];
    if (fs.existsSync(compat)) nodeArgs.push("--require", compat);
    try {
      result = JSON.parse(
        execFileSync(
          process.execPath,
          [
            ...nodeArgs,
            options.reader,
            options.templateSource,
            options.template,
          ],
          {
            encoding: "utf8",
          },
        ),
      );
    } catch (error) {
      fail(`template ${options.template} could not be read: ${String(error)}`);
    }
  }
  if (!Array.isArray(result) || result.length === 0) {
    fail(`template ${options.template} returned no bundles`);
  }
  return result as string[];
}

function addBundle(bundles: string[], bundle: string, template: string): void {
  if (bundles.includes(bundle)) {
    fail(
      template === ""
        ? `duplicate bundle ${bundle}`
        : `bundle ${bundle} is already in template ${template}`,
    );
  }
  bundles.push(bundle);
}

const installIndexes = new Map<string, Map<string, string[]>>();

function installIndex(install: string): Map<string, string[]> {
  const cached = installIndexes.get(install);
  if (cached !== undefined) return cached;
  const index = new Map<string, string[]>();
  const add = (name: string, directory: string): void => {
    const entries = index.get(name) ?? [];
    entries.push(directory);
    index.set(name, entries);
  };
  const table = path.join(install, "share", "dsh-nix", "bundles.tsv");
  if (fs.existsSync(table)) {
    for (const line of fs.readFileSync(table, "utf8").split("\n")) {
      if (line === "") continue;
      const [name, directory] = line.split("\t");
      if (name && directory) add(name, directory);
    }
  } else {
    const walk = (directory: string): void => {
      for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
        if (entry.name === "node_modules") continue;
        const candidate = path.join(directory, entry.name);
        if (entry.isDirectory()) walk(candidate);
        if (entry.isFile() && entry.name === "package.json") {
          const manifest = packageManifest(directory);
          if (manifest?.name) add(manifest.name, directory);
        }
      }
    };
    walk(install);
  }
  installIndexes.set(install, index);
  return index;
}

function resolveInstallBundle(install: string, wanted: string): string {
  const matches = installIndex(install).get(wanted) ?? [];
  if (matches.length !== 1) {
    fail(
      `expected exactly one installed package named ${wanted}, found ${matches.length}`,
    );
  }
  return matches[0];
}

function symlink(source: string, destination: string): void {
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.symlinkSync(source, destination);
}

function projectPackage(
  root: string,
  destination: string,
  explicitPatch: string,
  packageName: string,
): void {
  fs.mkdirSync(destination, { recursive: true });
  const absolute = path.isAbsolute(explicitPatch);
  const patchFile = absolute ? explicitPatch : path.join(root, explicitPatch);
  if (!fs.existsSync(patchFile)) {
    fail(`explicit patchPath ${explicitPatch} for ${packageName} not found`);
  }
  const patchBase = path.basename(explicitPatch);
  if (patchBase === "package.json") {
    fail(
      `explicit patchPath ${explicitPatch} for ${packageName} must not be package.json`,
    );
  }
  for (const entry of fs.readdirSync(root)) {
    if (entry === "package.json") continue;
    if (absolute && entry === patchBase) continue;
    fs.symlinkSync(path.join(root, entry), path.join(destination, entry));
  }
  const manifest = packageManifest(root);
  if (manifest === null) fail(`package.json missing at ${root}`);
  manifest.dsh = manifest.dsh ?? {};
  manifest.dsh.bundle = manifest.dsh.bundle ?? {};
  manifest.dsh.bundle.patch = absolute ? patchBase : explicitPatch;
  fs.writeFileSync(
    path.join(destination, "package.json"),
    JSON.stringify(manifest, null, 2) + "\n",
  );
  if (absolute)
    fs.copyFileSync(explicitPatch, path.join(destination, patchBase));
}

function resolveNix(meta: NixMetadata): {
  root: string;
  name: string;
  layer: boolean;
} {
  const root = resolveEffectiveRoot(meta.packagePath);
  const name = resolveName(meta, root);
  const layer = meta.patchPath !== null || hasDeclaredBundle(root);
  return { root, name, layer };
}

function main(): void {
  const options = parseArgs(process.argv.slice(2));
  const metadata = readJson(options.metadata, "profile metadata") as Metadata;
  if (
    !Array.isArray(metadata.classes) ||
    !Array.isArray(metadata.nixMetadata)
  ) {
    fail("profile metadata has invalid classes or nixMetadata");
  }

  const bundles = templateBundles(options);
  for (const entry of metadata.classes) {
    let bundle = "";
    if (entry.kind === "in-box" || entry.kind === "install-bundle") {
      bundle = entry.name ?? "";
    } else if (entry.kind === "nix") {
      const meta = metadata.nixMetadata.find(
        (candidate) => candidate.packagePath === entry.packagePath,
      );
      if (meta === undefined)
        fail(
          `missing nix metadata for ${entry.packagePath ?? "unknown package"}`,
        );
      const resolved = resolveNix(meta);
      if (resolved.layer) bundle = resolved.name;
    } else {
      fail(`unknown profile class ${String(entry.kind)}`);
    }
    if (bundle !== "") addBundle(bundles, bundle, options.template);
  }

  fs.mkdirSync(path.join(options.out, "node_modules"), { recursive: true });
  const dependencies: Record<string, string> = {};
  const seen = new Set<string>();
  for (const meta of metadata.nixMetadata) {
    const resolved = resolveNix(meta);
    if (seen.has(resolved.name))
      fail(`plugin packageNames must be unique (duplicate ${resolved.name})`);
    seen.add(resolved.name);
    dependencies[resolved.name] = resolved.root;
    const destination = path.join(options.out, "node_modules", resolved.name);
    if (meta.explicitPatch === null || meta.explicitPatch === "") {
      symlink(resolved.root, destination);
    } else {
      if (!path.isAbsolute(meta.explicitPatch)) {
        const normalized = path.normalize(meta.explicitPatch);
        if (
          normalized.startsWith("..") ||
          normalized.includes(`..${path.sep}`)
        ) {
          fail(
            `explicit patchPath ${meta.explicitPatch} for ${resolved.name} must stay inside the package`,
          );
        }
      }
      projectPackage(
        resolved.root,
        destination,
        meta.explicitPatch,
        resolved.name,
      );
    }
  }

  for (const entry of metadata.classes) {
    if (entry.kind !== "install-bundle") continue;
    const name = entry.name ?? "";
    if (options.install === "")
      fail(`bundle ${name} requires the dsh installation`);
    const directory = resolveInstallBundle(options.install, name);
    const manifest = packageManifest(directory);
    if (
      manifest?.dsh?.bundle?.patch === undefined ||
      manifest?.dsh?.bundle?.patch === null
    ) {
      fail(`${name} in the installation is not a bundle`);
    }
    const main = typeof manifest.main === "string" ? manifest.main : "";
    if (main === "" || !fs.existsSync(path.join(directory, main))) {
      fail(`${name} is not built in the installation (missing ${main})`);
    }
    symlink(directory, path.join(options.out, "node_modules", name));
  }

  const result = {
    name: options.name,
    version: "0.0.0",
    private: true,
    dsh: { profile: { bundles } },
    dependencies,
  };
  fs.writeFileSync(
    path.join(options.out, "package.json"),
    JSON.stringify(result, null, 2) + "\n",
  );
  fs.writeFileSync(path.join(options.out, "cordis.yml"), "[]\n");
  if (options.patchSource !== "") {
    fs.copyFileSync(
      options.patchSource,
      path.join(options.out, "cordis.patch.yml"),
    );
  } else {
    fs.writeFileSync(
      path.join(options.out, "cordis.patch.yml"),
      fs.readFileSync(options.patches, "utf8"),
    );
  }
}

main();
