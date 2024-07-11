import * as fsp from "fs/promises";
import { glob } from "glob";
import * as path from "path";
import { Path, PathScurry } from "path-scurry";
import ts from "typescript";
import * as tstl from "typescript-to-lua";

export type Job = {
    entryPathFromSrc: string;
};

export async function transpile(job: Job) {
    // Create a virtual project that includes the entry point file.
    const { entryPathFromSrc } = job;
    const entryFile = new PathScurry("./src").cwd.resolve(entryPathFromSrc);
    const bundleFiles = await globBundleFiles();
    const virtualProject = Object.fromEntries(await Promise.all([entryFile, ...bundleFiles].map(readVirtualFile)));

    // Call TypeScriptToLua.
    const bundleFile = (entryFile.parent ?? entryFile).resolve(path.basename(entryFile.name, ".ts") + ".lua");
    const result = tstl.transpileVirtualProject(virtualProject, {
        ...readCompilerOptions(),
        types: ["lua-types/5.0", "@typescript-to-lua/language-extensions"], // Drop the jest types.
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
        const outText = await injectPaywareScripts(tf.lua);
        await fsp.mkdir(dirPath, { recursive: true });
        await fsp.writeFile(outPath, outText);
        // Make multiple copies of the final output if needed.
        await copyOutput(path.relative("./dist", outPath));
    }
}

export async function globBundleFiles() {
    return [
        ...(await glob(
            [
                "node_modules/lua-types/5.0.d.ts",
                "node_modules/lua-types/core/index-5.0.d.ts",
                "node_modules/lua-types/core/coroutine.d.ts",
                "node_modules/lua-types/core/5.0/*",
                "node_modules/lua-types/special/5.0.d.ts",
            ],
            { withFileTypes: true }
        )),
        ...(await glob(["build.json", "@types/**/*", "lib/**/*.ts"], { cwd: "./src", withFileTypes: true })),
    ];
}

process.on("message", async m => {
    if (process.send === undefined) return;

    await transpile(m as Job);

    // Signal completion to the parent.
    process.send("done");
});

async function readVirtualFile(file: Path) {
    const contents = await fsp.readFile(file.fullpath(), { encoding: "utf-8" });
    return [file.relative(), contents] as [string, string];
}

function readCompilerOptions() {
    const configJson = ts.readConfigFile("./src/tsconfig.json", ts.sys.readFile);
    return ts.parseJsonConfigFileContent(configJson.config, ts.sys, ".").options;
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

async function injectPaywareScripts(lua: string) {
    const pathMap = new Map<string, string>([
        ["REPPO_AEM7_ENGINESCRIPT", "./payware/Assets/Reppo/AEM7/RailVehicles/Scripts/AEM7_EngineScript.out"],
        ["REPPO_E60_ENGINESCRIPT", "./payware/Assets/Reppo/E60CP/RailVehicles/Scripts/E60_EngineScript.out"],
    ]);
    for (const [constant, path] of pathMap.entries()) {
        if (lua.includes(constant)) {
            lua = lua.replaceAll(constant, embedLuaBytecode(await fsp.readFile(path)));
        }
    }
    return lua;
}

function embedLuaBytecode(bytes: Buffer) {
    var str = '"';
    for (const n of bytes) {
        str += "\\" + n;
    }
    str += '"';
    return str;
}

async function copyOutput(relativeOutPath: string) {
    const copyTargets: [string, string[]][] = [
        [
            "Assets/RSC/NorthEastCorridor/RailVehicles/Electric/AEM7/Default/Engine/RailVehicle_EngineScript.out",
            ["Assets/RSC/NorthEastCorridor/RailVehicles/Electric/AEM7/Default/Engine/EngineScript.out"],
        ],
        [
            "Assets/RSC/NewYorkNewHaven/RailVehicles/Electric/ACS-64/Default/CommonScripts/EngineScript.out",
            ["Assets/DTG/WashingtonBaltimore/RailVehicles/Electric/ACS-64/Default/CommonScripts/EngineScript.out"],
        ],
        [
            "Assets/RSC/AcelaPack01/RailVehicles/Electric/Acela/Default/CommonScripts/PowerCar_EngineScript.out",
            [
                "Assets/DTG/WashingtonBaltimore/RailVehicles/Electric/Acela/Default/CommonScripts/PowerCar_EngineScript.out",
            ],
        ],
        [
            "Assets/RSC/P32Pack01/RailVehicles/Passengers/Shoreliner/Driving Trailer/CommonScripts/CabCarEngineScript.out",
            [
                "Assets/DTG/HudsonLine/RailVehicles/Passengers/Shoreliner/Driving Trailer/CommonScripts/CabCarEngineScript.out",
            ],
        ],
        [
            "Assets/DTG/NorthJerseyCoast/RailVehicles/Passengers/Comet/Driving Trailer/CommonScripts/CometCab_EngineScript.out",
            [
                "Assets/DTG/NJT-Alp46/RailVehicles/Passengers/Comet/Driving Trailer/CommonScripts/CometCab_EngineScript.out",
                "Assets/DTG/GP40PHPack01/RailVehicles/Passengers/Comet/Driving Trailer/CommonScripts/CometCab_EngineScript.out",
                "Assets/DTG/F40PH2Pack01/RailVehicles/Passengers/Comet/Driving Trailer/CommonScripts/CometCab_EngineScript.out",
            ],
        ],
    ];
    const copyMap = new Map<string, string[]>(
        copyTargets.map(([source, destinations]) => [
            path.normalize(source),
            destinations.map(relative => path.normalize(path.join("./dist", relative))),
        ])
    );

    const destinations = copyMap.get(path.normalize(relativeOutPath)) ?? [];
    for (const destination of destinations) {
        await fsp.mkdir(path.dirname(destination), { recursive: true });
        await fsp.copyFile(path.join("./dist", relativeOutPath), destination);
    }
}
