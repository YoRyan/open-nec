import { spawn } from "child_process";
import * as fs from "fs";
import * as fsp from "fs/promises";
import { glob } from "glob";
import minimist from "minimist";
import * as path from "path";
import { Path } from "path-scurry";
import { exit } from "process";
import { Writable } from "stream";
import ts from "typescript";
import * as tstl from "typescript-to-lua";

async function main() {
    const mode = argv._.length === 0 ? "build" : argv._[0];
    switch (mode) {
        // Watch mode transpiles files when they get changed.
        case "watch":
            await watch();
            break;
        // Build mode transpiles everything and then exits.
        case "build":
        default:
            await build();
            break;
    }
    return 0;
}

async function watch() {
    const queue = new WatchQueue();
    // Transpile everything when a common library or type definition changes.
    for (const bundle of await globVirtualBundle()) {
        (async () => {
            const watcher = fsp.watch(bundle.fullpath());
            for await (const _ of watcher) {
                queue.all();
            }
        })();
    }
    // Transpile each entry point individually.
    for (const entry of await globEntryPoints()) {
        (async () => {
            const watcher = fsp.watch(entry.fullpath());
            for await (const _ of watcher) {
                queue.file(entry);
            }
        })();
    }
    await waitForever();
}

class WatchQueue {
    readonly minIntervalMs = 2 * 1000;
    lastAll: number | undefined = undefined;
    lastByFile: { [key: string]: number } = {};
    async all() {
        const now = nowTime();
        if (this.allStale()) {
            console.log("Transpiling all ...");

            this.lastAll = now;
            await build();
        }
    }
    async file(file: Path) {
        const now = nowTime();
        const key = file.fullpath();
        const lastThis = this.lastByFile[key];
        if (this.allStale() && (lastThis === undefined || now - lastThis > this.minIntervalMs)) {
            console.log(`Transpiling ${file.relative()} ...`);

            this.lastByFile[key] = now;
            await this.buildFile(file);
        }
    }
    private allStale() {
        return this.lastAll === undefined || nowTime() - this.lastAll > this.minIntervalMs;
    }
    private async buildFile(file: Path) {
        const bundle = await readVirtualBundle();
        await timedTranspile(file, bundle);
    }
}

function nowTime() {
    return new Date().getTime();
}

async function build() {
    const bundle = await readVirtualBundle();
    const entryPoints = await globEntryPoints();
    await Promise.all(entryPoints.map(async entry => await timedTranspile(entry, bundle)));
}

async function readVirtualBundle() {
    const bundleFiles = await globVirtualBundle();
    return await Promise.all(bundleFiles.map(readVirtualFile));
}

async function globVirtualBundle() {
    return (
        await Promise.all([
            glob(
                [
                    "node_modules/lua-types/5.0.d.ts",
                    "node_modules/lua-types/core/index-5.0.d.ts",
                    "node_modules/lua-types/core/coroutine.d.ts",
                    "node_modules/lua-types/core/5.0/*",
                    "node_modules/lua-types/special/5.0.d.ts",
                ],
                { withFileTypes: true }
            ),
            glob(["@types/**/*", "lib/**/*.ts"], { cwd: "./src", withFileTypes: true }),
        ])
    ).flat();
}

async function globEntryPoints() {
    return await glob("mod/**/*.ts", { cwd: "./src", withFileTypes: true });
}

async function timedTranspile(entryFile: Path, virtualBundle: [string, string][]) {
    const startMs = nowTime();
    await transpile(entryFile, virtualBundle);
    const endMs = nowTime();

    console.log(`${entryFile.relative()} - ${endMs - startMs}ms`);
}

async function transpile(entryFile: Path, virtualBundle: [string, string][]) {
    // Create a virtual project that includes the entry point file.
    const virtualProject = Object.fromEntries([await readVirtualFile(entryFile), ...virtualBundle]);

    // Call TypeScriptToLua.
    const bundleFile = (entryFile.parent ?? entryFile).resolve(path.basename(entryFile.name, ".ts") + ".lua");
    const result = tstl.transpileVirtualProject(virtualProject, {
        target: ts.ScriptTarget.ESNext,
        types: ["lua-types/5.0", "@typescript-to-lua/language-extensions"],
        baseUrl: ".",
        strict: true,
        luaTarget: tstl.LuaTarget.Lua50,
        sourceMapTraceback: false,
        luaBundle: bundleFile.relative(),
        luaBundleEntry: entryFile.relative(),
    });
    printDiagnostics(result.diagnostics);

    // Write the result.
    for (const tf of result.transpiledFiles) {
        if (!tf.lua) continue;

        const luaPath = path.join("./dist", path.relative("./mod", tf.outPath));
        const dirPath = path.dirname(luaPath);
        const outPath = path.join(dirPath, path.basename(luaPath, ".lua") + ".out");
        fs.mkdirSync(dirPath, { recursive: true });
        // "Lua" mode permits inspection of the transpiled Lua source.
        if (argv.lua) {
            await fsp.writeFile(luaPath, tf.lua);
        } else {
            await compileLua(outPath, tf.lua);
        }
    }
}

async function readVirtualFile(file: Path) {
    const contents = await fsp.readFile(file.fullpath(), { encoding: "utf-8" });
    return [file.relative(), contents] as [string, string];
}

function printDiagnostics(diagnostics: ts.Diagnostic[]) {
    if (diagnostics.length > 0) {
        console.log(
            ts.formatDiagnosticsWithColorAndContext(diagnostics, {
                getCurrentDirectory: () => ts.sys.getCurrentDirectory(),
                getCanonicalFileName: f => f,
                getNewLine: () => "\n",
            })
        );
    }
}

async function compileLua(outPath: string, lua: string) {
    const luac = spawn("luac", ["-o", outPath, "-"], { stdio: ["pipe", "inherit", "inherit"] });
    await writeStreamAsync(luac.stdin, lua);
}

async function writeStreamAsync(stream: Writable, chunk: any) {
    return new Promise((resolve, reject) => {
        stream.write(chunk, err => {
            if (err === null || err === undefined) {
                resolve(undefined);
            } else {
                reject(err);
            }
        });
    });
}

async function waitForever() {
    return new Promise((_resolve, _reject) => {});
}

const argv = minimist(process.argv.slice(2), {
    boolean: ["lua"],
    default: { lua: false },
});
exit(await main());
