/**
 * Amtrak GE E60CP
 */

import * as ale from "lib/alerter";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { mapBehavior } from "lib/frp-extra";
import { AduAspect } from "lib/nec/adu";
import * as cs from "lib/nec/cabsignals";
import * as adu from "lib/nec/twospeed-adu";
import { loadScript } from "lib/payware";
import * as fx from "lib/special-fx";
import * as ui from "lib/ui";

const suppressPos = 0.615;

declare const REPPO_E60_ENGINESCRIPT: string;
loadScript(REPPO_E60_ENGINESCRIPT);

// Disable Reppo's safety systems.
declare var GCV: (this: void, control: string) => number | undefined;
GCV = (control: string) => {
    switch (control) {
        case "ATCCutIn":
        case "ACSESCutIn":
            return 0;
        default:
            return me.rv.GetControlValue(control);
    }
};
OnCustomSignalMessage = _ => {};

// Disable parts of Reppo's update loop.
declare var DetermineMaximumSpeedLimit: (this: void) => void;
declare var SignalingMSG: (this: void) => void;
declare var UpdateInCabAspect: (this: void) => void;
DetermineMaximumSpeedLimit = SignalingMSG = UpdateInCabAspect = () => {};

// Read cold and dark state from Reppo's script.
declare var gEnergy: boolean;
const isPoweredOn = () => gEnergy;

// Penalty flag for Reppo's script.
declare var gPenaltyApplication: 0 | 1;

const me = new FrpEngine(() => {
    const isNjt = me.rv.GetControlMaximum("ATCCutIn") === 0;

    // Safety systems cut in/out
    // (Reverse the polarity so they are on by default.)
    const alerterCutIn = () => (me.rv.GetControlValue("ACSESCutIn") as number) < 0.5;
    ui.createAlerterStatusPopup(me, alerterCutIn);
    // (The ATC cut-in is disabled for the NJT model.)
    const atcCutIn = isNjt ? alerterCutIn : () => (me.rv.GetControlValue("ATCCutIn") as number) < 0.5;
    ui.createAtcStatusPopup(me, atcCutIn);

    // Safety systems and ADU
    const acknowledge = me.createAcknowledgeBehavior();
    const suppression = () => (me.rv.GetControlValue("VirtualBrake") as number) >= suppressPos;
    const [aduState$, aduEvents$] = adu.create({
        atc: cs.fourAspectAtc,
        e: me,
        acknowledge,
        suppression,
        atcCutIn: frp.liftN((cutIn, powered) => cutIn && powered, atcCutIn, isPoweredOn),
        acsesCutIn: () => false,
        equipmentSpeedMps: 90 * c.mph.toMps,
        pulseCodeControlValue: "SignalSpeedLimit",
    });
    const aduState = frp.stepper(aduState$, undefined);
    const aduUpdate$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                (state, powered) => {
                    return { state, powered };
                },
                aduState,
                isPoweredOn
            )
        )
    );
    aduUpdate$(({ state, powered }) => {
        if (powered && state !== undefined) {
            const { aspect } = state;
            me.rv.SetControlValue("SigN_Lit", aspect === cs.FourAspect.Clear ? 1 : 0);
            me.rv.SetControlValue("SigL_Lit", aspect === cs.FourAspect.ApproachLimited ? 1 : 0);
            me.rv.SetControlValue("SigM_Lit", aspect === cs.FourAspect.Approach ? 1 : 0);
            me.rv.SetControlValue(
                "SigR_Lit",
                aspect === cs.FourAspect.Restricting || aspect === AduAspect.Stop ? 1 : 0
            );
        } else {
            for (const cv of ["SigN_Lit", "SigL_Lit", "SigM_Lit", "SigR_Lit"]) {
                me.rv.SetControlValue(cv, 0);
            }
        }
    });
    // Alerter
    const alerterState = frp.stepper(
        ale.create({
            e: me,
            acknowledge,
            cutIn: frp.liftN((cutIn, powered) => cutIn && powered, alerterCutIn, isPoweredOn),
        }),
        undefined
    );
    // Safety system sounds
    const upgradeEvents$ = frp.compose(
        aduEvents$,
        frp.filter(evt => evt === adu.AduEvent.Upgrade)
    );
    const upgradeSound$ = frp.compose(me.createPlayerWithKeyUpdateStream(), fx.triggerSound(0.3, upgradeEvents$));
    const alarmsUpdate$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                (aduState, alerterState, upgradeSound) => {
                    return {
                        awsWarnCount: (aduState?.atcAlarm || alerterState?.alarm || upgradeSound) ?? false,
                        penalty: (aduState?.penaltyBrake || alerterState?.penaltyBrake) ?? false,
                    };
                },
                aduState,
                alerterState,
                frp.stepper(upgradeSound$, false)
            )
        )
    );
    alarmsUpdate$(({ awsWarnCount, penalty }) => {
        me.rv.SetControlValue("AWSWarnCount", awsWarnCount ? 1 : 0);

        if (penalty) {
            // Tells Reppo's script to stop accepting the player's input.
            gPenaltyApplication = 1;
            // Tells Advanced Braking to apply maximum service braking.
            me.rv.SetControlValue("VirtualBrakeHandle", suppressPos);
        } else {
            gPenaltyApplication = 0;
        }
    });

    // Set consist brake lights.
    fx.createBrakeLightStreamForEngine(me);

    // Set platform door height.
    fx.createLowPlatformStreamForEngine(me, false);
});
me.setup();
