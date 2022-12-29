/** @noSelfInFile */

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

    private readonly onInit: (this: void) => void;
    private updatingEveryFrame = false;

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
        Initialise = this.onInit;
        Update = dt => {
            this.updateSource.call(dt);
            if (!this.updatingEveryFrame) {
                // EndUpdate() must be called from the Update() callback.
                this.e.EndUpdate();
            }
        };
        OnSave = () => this.saveSource.call();
        OnResume = () => this.resumeSource.call();
    }

    /**
     * Set the update loop to update every frame, or only upon the execution of
     * any callback.
     * @param everyFrame Whether to update every frame.
     */
    activateUpdatesEveryFrame(everyFrame: boolean) {
        if (!this.updatingEveryFrame && everyFrame) {
            this.e.BeginUpdate();
        }
        this.updatingEveryFrame = everyFrame;
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
