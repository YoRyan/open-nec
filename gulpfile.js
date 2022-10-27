import { writeFile } from "fs/promises";
import intersect from "glob-intersection";
import gulp from "gulp";
const { dest, src, watch } = gulp;
import { stream } from "gulp-execa";
import filter from "gulp-filter";
import flatmap from "gulp-flatmap";
import intermediate from "gulp-intermediate";
import rename from "gulp-rename";
import minimist from "minimist";
import path from "path";
import ts from "typescript";
import tstl from "typescript-to-lua";

const options = minimist(process.argv.slice(2), { string: "src", default: { src: "src/mod/**/*" } });

function filterSource(glob) {
    const selected = Array.isArray(options.src) ? options.src : [options.src];
    const filtered = selected.map(s => intersect(s, glob)).filter(g => g);
    if (filtered.length === 0) {
        throw "No source files matched the provided glob filter";
    }
    return filtered;
}

export default function () {
    watch([...filterSource("src/mod/**/*.ts"), "src/lib/**/*.ts"], typescript);
}

export async function typescript() {
    return awaitStream(
        src(filterSource("src/mod/**/*.ts"), { base: "src" })
            .pipe(
                flatmap((stream, file) =>
                    stream
                        .pipe(src(["src/@types/**/*", "src/lib/**/*.ts"], { base: "src" }))
                        .pipe(
                            src(
                                ["@typescript-to-lua", "lua-types", "typescript-to-lua"].map(
                                    p => `node_modules/${p}/**/*`
                                ),
                                { base: "." }
                            )
                        )
                        .pipe(
                            intermediate({}, async (tempDir, cb) => {
                                await transpileTypeScriptToLua(tempDir, file.relative);
                                cb();
                            })
                        )
                        .pipe(filter("mod/**/*.lua"))
                )
            )
            // Need to pipe through cat because node pipes can't be referenced with
            // named file descriptors; see https://stackoverflow.com/a/72906798
            .pipe(stream(({ path }) => `luac -o /dev/stdout ${escapeShellArg(path)} | cat`, { shell: true }))
            .pipe(rename(path => (path.extname = ".out")))
            .pipe(rename(path => (path.dirname = path.dirname.replace(/^mod\//, ""))))
            .pipe(dest("dist"))
    );
}

async function transpileTypeScriptToLua(tempDir, luaPath) {
    const tsconfig = path.join(tempDir, "tsconfig.json");
    // We need the root tsconfig.json node to set the value of "include".
    await writeFile(
        tsconfig,
        JSON.stringify({
            include: [path.join(tempDir, "@types"), path.join(tempDir, "mod")],
        })
    );

    const result = tstl.transpileProject(tsconfig, {
        target: ts.ScriptTarget.ESNext,
        moduleResolution: ts.ModuleResolutionKind.NodeJs,
        types: ["lua-types/5.0"],
        strict: true,
        baseUrl: tempDir,
        typeRoots: [path.join(tempDir, "@types")],
        luaTarget: tstl.LuaTarget.Lua50,
        luaLibImport: tstl.LuaLibImportKind.Inline,
        sourceMapTraceback: false,
        luaBundle: path.join(path.dirname(luaPath), path.basename(luaPath, ".ts") + ".lua"),
        // The entry path needs to be absolute so that TSTL sets the correct module name.
        luaBundleEntry: path.join(tempDir, luaPath),
    });
    printDiagnostics(result.diagnostics);
}

function printDiagnostics(diagnostics) {
    console.log(
        ts.formatDiagnosticsWithColorAndContext(diagnostics, {
            getCurrentDirectory: () => ts.sys.getCurrentDirectory(),
            getCanonicalFileName: f => f,
            getNewLine: () => "\n",
        })
    );
}

async function awaitStream(stream) {
    return new Promise((resolve, reject) => {
        stream.on("finish", resolve).on("error", reject);
    });
}

function escapeShellArg(str) {
    return `'${str.replaceAll("'", "'\\''")}'`;
}
