import colors from "@colors/colors";
import { ChildProcess, fork } from "child_process";
import * as fsp from "fs/promises";
import { glob } from "glob";
import { Path } from "path-scurry";
import { exit } from "process";
import { parseArgs } from "util";
import { Job, globBundleFiles, transpile } from "./build-worker.js";

async function main() {
    const { values, positionals } = parseArgs({
        strict: false,
        options: {
            workers: { type: "string", short: "w", default: "0" },
        },
    });

    const workers = parseInt(values.workers as string);
    const transpiler = workers > 0 ? new MultiProcessTranspiler(workers) : new SingleProcessTranspiler();

    const [mode] = positionals;
    switch (mode ?? "build") {
        // Watch mode transpiles files when they get changed.
        case "watch":
            await watch(transpiler);
            break;
        // Build mode transpiles everything and then exits.
        case "build":
        default:
            await build(transpiler);
            break;
    }
    return 0;
}

async function watch(transpiler: Transpiler) {
    const queue = new WatchQueue(transpiler);
    // Transpile everything when a common library or type definition changes.
    for (const bundle of await globBundleFiles()) {
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
    private readonly minIntervalMs = 2 * 1000;
    private lastAll: number | undefined = undefined;
    private lastByFile: { [key: string]: number } = {};
    private readonly transpiler: Transpiler;
    constructor(transpiler: Transpiler) {
        this.transpiler = transpiler;
    }
    async all() {
        const now = nowTime();
        if (this.allStale()) {
            console.log("Transpiling all ...");

            this.lastAll = now;
            await build(this.transpiler);
        }
    }
    async file(file: Path) {
        const now = nowTime();
        const key = file.fullpath();
        const lastThis = this.lastByFile[key];
        if (this.allStale() && (lastThis === undefined || now - lastThis > this.minIntervalMs)) {
            console.log(`Transpiling ${file.relative()} ...`);

            this.lastByFile[key] = now;
            reportTimedResult(file, await this.transpiler.timedTranspileMs(file));
        }
    }
    private allStale() {
        return this.lastAll === undefined || nowTime() - this.lastAll > this.minIntervalMs;
    }
}

interface Transpiler {
    timedTranspileMs(entryFile: Path): Promise<number>;
}

/**
 * Just calls the transpiler--no fancy workers. Includes a mutex so transpile
 * times are reported correctly.
 */
class SingleProcessTranspiler implements Transpiler {
    private mutex = false;
    private waitingForMutex: (() => void)[] = [];
    async timedTranspileMs(entryFile: Path) {
        await this.getMutex();

        const startMs = nowTime();
        await transpile({
            entryPathFromSrc: entryFile.relative(),
        });
        const endMs = nowTime();

        this.releaseMutex();
        return endMs - startMs;
    }
    private async getMutex() {
        if (!this.mutex) {
            this.mutex = true;
        } else {
            return await new Promise<void>(resolve => {
                this.waitingForMutex.push(resolve);
            });
        }
    }
    private releaseMutex() {
        const next = this.waitingForMutex.pop();
        if (next !== undefined) {
            next();
        } else {
            this.mutex = false;
        }
    }
}

/**
 * Spawns other Node processes running build-worker.ts and uses them as a worker
 * pool.
 */
class MultiProcessTranspiler implements Transpiler {
    private workersToSpawn: number;
    private waitingForWorker: ((worker: ChildProcess) => void)[] = [];
    private spareWorkers: ChildProcess[] = [];
    constructor(maxWorkers: number) {
        this.workersToSpawn = maxWorkers;
    }
    async timedTranspileMs(entryFile: Path) {
        const worker = await this.getWorker();
        worker.send({
            entryPathFromSrc: entryFile.relative(),
        } as Job);

        const startMs = nowTime();
        await new Promise<void>(resolve => {
            worker.on("message", resolve);
        });
        const endMs = nowTime();

        this.returnWorker(worker);
        return endMs - startMs;
    }
    private async getWorker() {
        const spareWorker = this.spareWorkers.pop();
        if (spareWorker !== undefined) {
            return spareWorker;
        } else if (this.workersToSpawn > 0) {
            this.workersToSpawn--;
            return fork("./build-worker.ts", { stdio: ["ipc", "inherit", "inherit"] });
        } else {
            return await new Promise<ChildProcess>(resolve => {
                this.waitingForWorker.push(resolve);
            });
        }
    }
    private returnWorker(worker: ChildProcess) {
        worker.removeAllListeners("message");
        const next = this.waitingForWorker.pop();
        if (next !== undefined) {
            next(worker);
        } else {
            this.spareWorkers.push(worker);
        }
    }
}

async function build(transpiler: Transpiler) {
    const entryPoints = await globEntryPoints();
    await Promise.all(
        entryPoints.map(async entry => {
            reportTimedResult(entry, await transpiler.timedTranspileMs(entry));
        })
    );
}

async function globEntryPoints() {
    return await glob("mod/**/*.ts", { cwd: "./src", withFileTypes: true });
}

function reportTimedResult(file: Path, ms: number) {
    console.log(`${colors.gray(file.relative())} ${ms}ms`);
}

function nowTime() {
    return new Date().getTime();
}

async function waitForever() {
    return new Promise((_resolve, _reject) => {});
}

exit(await main());
