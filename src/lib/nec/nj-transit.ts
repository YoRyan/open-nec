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

const destinationNodes = [
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
 * @param desinations An array of destination names to present to the player.
 */
export function createDestinationSignSelector(e: FrpEngine, destinations: string[] = destinationNames) {
    // If our rail vehicle has a destination encoded in its #, then emit that
    // one at startup.
    const rvDestination$ = frp.compose(
        e.createFirstUpdateStream(),
        frp.map(_ => getRvNumberDestination(e)),
        rejectUndefined(),
        frp.hub()
    );
    // We don't set the player's control value upon load, so if it was set by
    // rail vehicle # it will be out of sync until they change it, but that's
    // okay.
    const playerMenu = new ui.ScrollingMenu("Set Destination Signs", destinations);
    const wrapDestination$ = frp.compose(
        e.createOnCvChangeStreamFor("Destination"),
        frp.map(v => Math.round(v)),
        frp.map(v => {
            if (v < 1) {
                return destinations.length;
            } else if (v > destinations.length) {
                return 1;
            } else {
                return undefined;
            }
        }),
        rejectUndefined(),
        frp.hub()
    );
    const newDestination$ = frp.compose(
        e.createOnCvChangeStreamFor("Destination"),
        frp.map(v => Math.round(v)),
        frp.filter(v => v >= 1 && v <= destinations.length),
        rejectRepeats(),
        frp.merge(wrapDestination$),
        // Sometimes this fires for other units...
        frp.filter(_ => e.eng.GetIsEngineWithKey()),
        frp.hub()
    );
    wrapDestination$(v => {
        e.rv.SetControlValue("Destination", v);
    });
    newDestination$(index => {
        playerMenu.setSelection(index - 1);
        playerMenu.showPopup();
    });

    const sendToConsist$ = frp.compose(rvDestination$, frp.merge(newDestination$));
    sendToConsist$(index => {
        const content = `${index}`;
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
        rejectUndefined()
    );
    const showDestination$ = frp.compose(readFromConsist$, frp.merge(rvDestination$), frp.merge(newDestination$));
    showDestination$(selected => {
        for (let i = 0; i < destinationNodes.length; i++) {
            e.rv.ActivateNode(destinationNodes[i], i === selected - 1);
        }
    });
}

function getRvNumberDestination(v: FrpVehicle) {
    const [, , letter] = string.find(v.rv.GetRVNumber(), "^(%a)");
    if (letter !== undefined) {
        return string.byte(string.upper(letter as string)) - string.byte("A") + 1;
    } else {
        return undefined;
    }
}

/**
 * Drive animations for passenger coach doors. The player has the option of
 * locking the doors open until they close them manually. AI trains obey the
 * simulator's commands.
 * @param v The coach or cab car.
 * @param openTimeS The time taken to open or close the doors.
 * @returns A behavior that returns the door states for both sides of the car as
 * numbers scaled from 0 (closed) to 1 (open).
 */
export function createManualDoorsBehavior(
    v: FrpVehicle,
    openTimeS: number = 1
): frp.Behavior<[left: number, right: number]> {
    const leftDoor = frp.stepper(
        createManualDoorsStream(v, openTimeS, () => (v.rv.GetControlValue("DoorsOpenCloseLeft") as number) > 0.5),
        0
    );
    const rightDoor = frp.stepper(
        createManualDoorsStream(v, openTimeS, () => (v.rv.GetControlValue("DoorsOpenCloseRight") as number) > 0.5),
        0
    );
    return frp.liftN((left, right) => [left, right], leftDoor, rightDoor);
}

function createManualDoorsStream(
    v: FrpVehicle,
    openTimeS: number,
    doorsOpen: frp.Behavior<boolean>
): frp.Stream<number> {
    type DoorsAccum = {
        position: number;
        stayOpen: boolean;
    };

    const manualEnabled = () => (v.rv.GetControlValue("DoorsManual") as number) > 0.5;
    const manualClose = () => (v.rv.GetControlValue("DoorsManualClose") as number) >= 1;
    return frp.compose(
        v.createUpdateStream(),
        frp.fold(
            (accum: DoorsAccum, dt) => {
                let position: number;
                let stayOpen: boolean;
                if (frp.snapshot(doorsOpen)) {
                    position = Math.min(accum.position + dt / openTimeS, 1);
                    stayOpen = frp.snapshot(manualEnabled);
                } else if (v.rv.GetIsPlayer() && accum.stayOpen) {
                    position = accum.position;
                    stayOpen = !frp.snapshot(manualClose);
                } else {
                    position = Math.max(accum.position - dt / openTimeS, 0);
                    stayOpen = false;
                }
                return { position, stayOpen };
            },
            {
                position: 0,
                stayOpen: false,
            }
        ),
        frp.map(accum => accum.position)
    );
}

/**
 * Create popups for the manual door enable/disable control value.
 * @param e The player's engine.
 */
export function createManualDoorsPopup(e: FrpEngine) {
    ui.createStatusPopup(
        e,
        () => (e.rv.GetControlValue("DoorsManual") as number) > 0.5,
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
        () => (e.rv.GetControlValue("HEP") as number) > 0.5,
        "Head-End Power",
        new Map([
            [true, "Enabled"],
            [false, "Disabled"],
        ])
    );
}
