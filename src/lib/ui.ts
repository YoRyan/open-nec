/**
 * Helpers for UI popups and controls.
 */

import * as frp from "./frp";
import { FrpEngine } from "./frp-engine";
import { fsm, mapBehavior, rejectUndefined } from "./frp-extra";
import * as rw from "./railworks";

export const popupS = 5;

const scrollingMenuSize = 6;
const progressBarWidth = 40;

/**
 * Use popups to communicate the status of a behavior. Intended for invisible
 * controls such as safety systems cut in/out, etc.
 * @param e The player's engine.
 * @param behavior The behavior to monitor.
 * @param title The title shared by all popups.
 * @param status A map of possible behavior states to popup messages.
 */
export function createStatusPopup<T>(e: FrpEngine, behavior: frp.Behavior<T>, title: string, status: Map<T, string>) {
    const stream$ = frp.compose(
        e.createPlayerWithKeyUpdateStream(),
        frp.filter(_ => frp.snapshot(e.areControlsSettled)),
        mapBehavior(behavior),
        fsm<undefined | T>(undefined),
        // Ignore the first transition from undefined to false, which is usually spurious.
        frp.filter(([from, to]) => from !== to && !(from === undefined && !to)),
        frp.map(([, to]) => to),
        rejectUndefined()
    );
    stream$(to => {
        rw.ScenarioManager.ShowAlertMessageExt(title, status.get(to) ?? "Unknown", popupS, "");
    });
}

/**
 * Create popups for an ATC cut in/out control.
 * @param e The player's engine.
 * @param behavior The cut in/out behavior.
 */
export function createAtcStatusPopup(e: FrpEngine, behavior: frp.Behavior<boolean>) {
    createStatusPopup(
        e,
        behavior,
        "ATC Signal Speed Enforcement",
        new Map([
            [true, "Cut In"],
            [false, "Cut Out"],
        ])
    );
}

/**
 * Create popups for an ACSES cut in/out control.
 * @param e The player's engine.
 * @param behavior The cut in/out behavior.
 */
export function createAcsesStatusPopup(e: FrpEngine, behavior: frp.Behavior<boolean>) {
    createStatusPopup(
        e,
        behavior,
        "ACSES Track Speed Enforcement",
        new Map([
            [true, "Cut In"],
            [false, "Cut Out"],
        ])
    );
}

/**
 * Create popups for an alerter cut in/out control.
 * @param e The player's engine.
 * @param behavior The cut in/out behavior.
 */
export function createAlerterStatusPopup(e: FrpEngine, behavior: frp.Behavior<boolean>) {
    createStatusPopup(
        e,
        behavior,
        "Alerter Vigilance System",
        new Map([
            [true, "Cut In"],
            [false, "Cut Out"],
        ])
    );
}

/**
 * Create popups for an automatic power mode change control.
 * @param e The player's engine.
 * @param behavior The on/off behavior.
 */
export function createAutoPowerStatusPopup(e: FrpEngine, behavior: frp.Behavior<boolean>) {
    createStatusPopup(
        e,
        behavior,
        "Automatic Power Change",
        new Map([
            [true, "Enabled"],
            [false, "Disabled"],
        ])
    );
}

/**
 * A popup that allows the player to scroll through a long list of selections.
 */
export class ScrollingMenu {
    private readonly title: string;
    private readonly items: string[];
    private readonly nItems: number;

    private selection: number;
    private offset: number;

    /**
     * Construct a new menu.
     * @param title The title of the menu.
     * @param items A list of player-friendly labels for the menu.
     * @param initSelection The initial selection. Defaults to the first item.
     */
    constructor(title: string, items: string[], initSelection?: number) {
        initSelection ??= 0;

        this.title = title;
        this.items = items;
        this.nItems = items.length;

        this.selection = 0;
        this.offset = 0;
        this.doScroll(initSelection);
    }

    /**
     * Change the current selection and display a popup.
     * @param move The index delta to move by.
     */
    scroll(move: number) {
        this.doScroll(move);
        this.showPopup();
    }

    /**
     * Show this menu without changing the selection.
     */
    showPopup() {
        const lines: string[] = [];
        if (this.offset > 0 || this.selection >= scrollingMenuSize) {
            lines.push("...");
        }
        const window = Math.floor((this.selection - this.offset) / scrollingMenuSize);
        for (let i = 0; i < scrollingMenuSize; i++) {
            const idx = window * scrollingMenuSize + this.offset + i;
            if (idx >= this.nItems) {
                break;
            } else {
                const item = this.items[idx];
                lines.push(idx === this.selection ? `> ${item} <` : item);
            }
        }
        if (this.offset + (window + 1) * scrollingMenuSize < this.nItems) {
            lines.push("...");
        }

        rw.ScenarioManager.ShowInfoMessageExt(
            this.title,
            lines.join("\n"),
            popupS,
            rw.MessageBoxPosition.Centre,
            rw.MessageBoxSize.Small,
            false
        );
    }

    /**
     * Get the current selection index.
     */
    getSelection() {
        return this.selection;
    }

    /**
     * Set the current selection index.
     * @param index The new index.
     */
    setSelection(index: number) {
        this.doScroll(index - this.selection);
    }

    private doScroll(move: number) {
        let selection: number;
        // Allow wraparounds at the top and bottom of the menu.
        if (move > 0) {
            selection = (this.selection + move) % this.nItems;
        } else {
            const clampedMove = -(-move % this.nItems);
            selection = this.selection + clampedMove + (this.selection + clampedMove < 0 ? this.nItems : 0);
        }

        let offset: number;
        if (this.nItems <= scrollingMenuSize) {
            offset = 0;
        } else if (selection >= Math.floor(this.nItems / scrollingMenuSize) * scrollingMenuSize) {
            // For the last page, which may not have sufficient content.
            offset = Math.max(this.offset, (selection + 1) % scrollingMenuSize);
        } else {
            offset = Math.min(this.offset, selection);
        }

        [this.selection, this.offset] = [selection, offset];
    }
}

/**
 * Show a popup that communicates the current status of a long-running task.
 * @param title The popup title to use.
 * @param message Show some text above the progress bar.
 * @param from Show some text on the left side of the progress bar.
 * @param to Show some text on the right side of the progress bar.
 * @param progress The progress to show, scaled from 0 to 1.
 */
export function showProgressPopup({
    title,
    message,
    from,
    to,
    progress,
}: {
    title: string;
    message: string;
    from: string;
    to: string;
    progress: number;
}) {
    const done = Math.floor(progress * progressBarWidth * 2) / 2;
    const remaining = Math.ceil((1 - progress) * progressBarWidth * 2) / 2;
    const isHalfDone = done % 1 > 0;
    const bar = isHalfDone
        ? string.rep(":", done - 0.5) + "." + string.rep(" ", remaining - 0.5)
        : string.rep(":", done) + string.rep(" ", remaining);
    const fromTo = from === "" && to === "" ? "" : from + string.rep(" ", progressBarWidth * 0.75) + to;
    rw.ScenarioManager.ShowInfoMessageExt(
        title,
        `${message === "" ? "" : message + "\n\n"}[${bar}]${fromTo === "" ? "" : "\n\n" + fromTo}`,
        popupS,
        rw.MessageBoxPosition.Bottom + rw.MessageBoxPosition.Left,
        rw.MessageBoxSize.Small,
        false
    );
}
