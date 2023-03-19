import * as frp from "./frp";
import * as rw from "./railworks";

/**
 * An entity is a world object that can request an Update() call. It manages an
 * update loop that runs on every Update() or event callback.
 */
export class FrpEntity {
    /**
     * Convenient access to the methods for a scripted entity.
     */
    public readonly e = new rw.ScriptedEntity("");
    /**
     * Convenient access to the methods for a rendered entity.
     */
    public readonly re = new rw.RenderedEntity("");

    private readonly updateSource = new FrpSource<number>();
    private readonly saveSource = new FrpSource<void>();
    private readonly resumeSource = new FrpSource<void>();

    private readonly onInit: () => void;

    /**
     * Construct a new entity.
     * @param onInit The callback to run when the game calls Initialise().
     */
    constructor(onInit: () => void) {
        this.onInit = onInit;
    }

    /**
     * Create an event stream of frame times from the Update() callback.
     * @returns The new stream of numbers.
     */
    createUpdateStream() {
        return this.updateSource.createStream();
    }

    /**
     * Create an event stream from the OnSave() callback.
     * @returns The new stream.
     */
    createOnSaveStream() {
        return this.saveSource.createStream();
    }

    /**
     * Create an event stream from the OnResume() callback.
     * @returns The new stream.
     */
    createOnResumeStream() {
        return this.resumeSource.createStream();
    }

    /**
     * Set the global callback functions to execute this entity.
     */
    setup() {
        Initialise = this.chain(Initialise, () => this.onInit());
        Update = this.chain(Update, dt => this.updateSource.call(dt));
        OnSave = this.chain(OnSave, () => this.saveSource.call());
        OnResume = this.chain(OnResume, () => this.resumeSource.call());
    }

    /**
     * Append new code to a global callback that may or may not already exist.
     * This is a common modding technique for grafting behavior onto other Lua
     * scripts.
     * @param old The existing callback, if any.
     * @param ours The callback we want to call after the existing one.
     * @returns A new callback that combines both.
     */
    protected chain<T extends any[]>(
        old: (this: void, ...args: T) => void | undefined,
        ours: (this: void, ...args: T) => void
    ): (this: void, ...args: T) => void {
        return (...args: T) => {
            if (old !== undefined) {
                old(...args);
            }
            ours(...args);
        };
    }
}

/**
 * A list of callbacks that proxies access to a single event stream source.
 */
export class FrpSource<T> {
    private readonly nexts: ((arg0: T) => void)[] = [];

    /**
     * Create a new event stream and register its callback to this list.
     */
    createStream(): frp.Stream<T> {
        return next => {
            this.nexts.push(next);
        };
    }

    /**
     * Call the callbacks in this list with the provided value.
     * @param value The value to run the callbacks with.
     */
    call(value: T) {
        for (const next of this.nexts) {
            next(value);
        }
    }
}
