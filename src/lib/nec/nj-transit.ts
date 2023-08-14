/**
 * Common scriptables for NJ Transit equipment.
 */

import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { rejectRepeats, rejectUndefined } from "lib/frp-extra";
import { FrpVehicle } from "lib/frp-vehicle";
import * as rw from "lib/railworks";
import * as ui from "lib/ui";

export const destinationNames = ["Trenton", "New York", "Long Branch", "Hoboken", "Dover", "Bay Head"];
export const destinationNodes = [
    "Dest_Trenton",
    "Dest_NewYork",
    "Dest_LongBranch",
    "Dest_Hoboken",
    "Dest_Dover",
    "Dest_BayHead",
];

/**
 * Read and set destination signs for NJT rolling stock. Also creates a nice
 * selection menu for the player.
 * @param e The engine or cab car.
 * @returns A stream of indices into destinationNodes.
 */
export function createDestinationSignStream(e: FrpEngine) {
    // If our rail vehicle has a destination encoded in its #, then emit that
    // one at startup. Unless we are the player and we are resuming from a save;
    // then use the control value.
    const playerDestination = () => {
        const cv = e.rv.GetControlValue("Destination", 0);
        return cv !== undefined ? Math.round(cv) - 1 : undefined;
    };
    const firstDestination$ = frp.compose(
        e.createFirstUpdateStream(),
        frp.map(resume => {
            const playerCv = e.eng.GetIsEngineWithKey() && resume ? frp.snapshot(playerDestination) : undefined;
            const startIndex = playerCv ?? getRvNumberDestination(e);
            return startIndex;
        }),
        rejectUndefined()
    );
    // We don't set the player's control value on first load, so if it was set
    // by rail vehicle # it will be out of sync until they change it, but that's
    // okay.
    const playerMenu = new ui.ScrollingMenu("Set Destination Signs", destinationNames);
    const newDestination$ = frp.compose(
        e.createOnCvChangeStreamFor("Destination", 0),
        frp.map(v => Math.round(v) - 1),
        rejectRepeats(),
        frp.hub()
    );
    newDestination$(index => {
        playerMenu.setSelection(index);
        playerMenu.showPopup();
    });

    const sendToConsist$ = frp.compose(firstDestination$, frp.merge(newDestination$));
    sendToConsist$(index => {
        const content = `${index + 1}`; // Maintain compatibility with DTG scripts.
        e.rv.SendConsistMessage(c.ConsistMessageId.NjtDestination, content, rw.ConsistDirection.Forward);
        e.rv.SendConsistMessage(c.ConsistMessageId.NjtDestination, content, rw.ConsistDirection.Backward);
    });

    // Read and forward consist messages.
    const consistMessage$ = frp.compose(
        e.createOnConsistMessageStream(),
        frp.filter(([id]) => id === c.ConsistMessageId.NjtDestination),
        frp.hub()
    );
    consistMessage$(msg => {
        e.rv.SendConsistMessage(...msg);
    });

    const readFromConsist$ = frp.compose(
        consistMessage$,
        frp.map(([, content]) => tonumber(content)),
        rejectUndefined(),
        frp.map(index => index - 1)
    );
    return frp.compose(readFromConsist$, frp.merge(firstDestination$), frp.merge(newDestination$));
}

function getRvNumberDestination(v: FrpVehicle) {
    const [, , letter] = string.find(v.rv.GetRVNumber(), "^(%a)");
    if (letter !== undefined) {
        return string.byte(string.upper(letter as string)) - string.byte("A");
    } else {
        return undefined;
    }
}

/**
 * Create popups for the manual door enable/disable control value.
 * @param e The player's engine.
 */
export function createManualDoorsPopup(e: FrpEngine) {
    ui.createStatusPopup(
        e,
        () => (e.rv.GetControlValue("DoorsManual", 0) as number) > 0.5,
        "Manual Door Control",
        new Map([
            [true, "Enabled"],
            [false, "Disabled"],
        ])
    );
}

/**
 * Create popups for the HEP enable/disable control value.
 * @param e The player's engine.
 */
export function createHepPopup(e: FrpEngine) {
    ui.createStatusPopup(
        e,
        () => (e.rv.GetControlValue("HEP", 0) as number) > 0.5,
        "Head-End Power",
        new Map([
            [true, "Enabled"],
            [false, "Disabled"],
        ])
    );
}