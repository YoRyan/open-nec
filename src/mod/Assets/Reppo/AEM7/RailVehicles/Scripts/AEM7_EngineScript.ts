/**
 * Amtrak EMD AEM-7 (Reppo edition)
 */

import * as ale from "lib/alerter";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { mapBehavior } from "lib/frp-extra";
import { AduAspect } from "lib/nec/adu";
import * as m from "lib/math";
import * as cs from "lib/nec/cabsignals";
import * as adu from "lib/nec/twospeed-adu";
import { loadScript } from "lib/payware";
import * as fx from "lib/special-fx";
import * as ui from "lib/ui";

const suppressPos = 0.615;

declare const REPPO_AEM7_ENGINESCRIPT: string;
loadScript(REPPO_AEM7_ENGINESCRIPT);

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
declare var SCV: (this: void, control: string, value: number) => void;
SCV = (control: string, value: number) => {
    switch (control) {
        case "Ind_Overspeed":
            break;
        default:
            me.rv.SetControlValue(control, value);
            break;
    }
};
OnCustomSignalMessage = _ => {};

// Disable parts of Reppo's update loop.
declare var UpdateSignals: (this: void) => void;
declare var UpdateTrackSpeed: (this: void) => void;
declare var UpdateSignalSpeed: (this: void) => void;
declare var SignalingMSG: (this: void) => void;
declare var CabAlerts: (this: void) => void;
declare var UpdateInCabAspect: (this: void) => void;
UpdateSignals = UpdateTrackSpeed = UpdateSignalSpeed = SignalingMSG = CabAlerts = UpdateInCabAspect = () => {};

// Read cold and dark state from Reppo's script.
declare var gEnergy: boolean;
const isPoweredOn = () => gEnergy;

const me = new FrpEngine(() => {
    // Safety systems cut in/out
    // (Reverse the polarity so they are on by default.)
    const atcCutIn = () => (me.rv.GetControlValue("ATCCutIn") as number) < 0.5;
    ui.createAtcStatusPopup(me, atcCutIn);
    const acsesCutIn = () => (me.rv.GetControlValue("ACSESCutIn") as number) < 0.5;
    ui.createAcsesStatusPopup(me, acsesCutIn);
    const alerterCutIn = frp.liftN((atcCutIn, acsesCutIn) => atcCutIn || acsesCutIn, atcCutIn, acsesCutIn);
    ui.createAlerterStatusPopup(me, alerterCutIn);

    // Safety systems and ADU
    const acknowledge = me.createAcknowledgeBehavior();
    const suppression = () => (me.rv.GetControlValue("VirtualBrake") as number) >= suppressPos;
    const [aduState$, aduEvents$] = adu.create({
        atc: cs.amtrakAtc,
        e: me,
        acknowledge,
        suppression,
        atcCutIn: frp.liftN((cutIn, powered) => cutIn && powered, atcCutIn, isPoweredOn),
        acsesCutIn: frp.liftN((cutIn, powered) => cutIn && powered, acsesCutIn, isPoweredOn),
        equipmentSpeedMps: 125 * c.mph.toMps,
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
            const { aspect, aspectFlashOn } = state;
            me.rv.SetControlValue(
                "SigN_Lit",
                ((aspect === cs.AmtrakAspect.CabSpeed60 || aspect === cs.AmtrakAspect.CabSpeed80) && aspectFlashOn) ||
                    aspect === cs.AmtrakAspect.Clear100 ||
                    aspect === cs.AmtrakAspect.Clear125 ||
                    aspect === cs.AmtrakAspect.Clear150
                    ? 1
                    : 0
            );
            me.rv.SetControlValue(
                "SigL_Lit",
                aspect === cs.AmtrakAspect.Approach ||
                    aspect === cs.AmtrakAspect.ApproachMedium ||
                    aspect === cs.AmtrakAspect.ApproachLimited
                    ? 1
                    : 0
            );
            me.rv.SetControlValue(
                "SigM_Lit",
                aspect === cs.AmtrakAspect.ApproachMedium ||
                    (aspect === cs.AmtrakAspect.ApproachLimited && aspectFlashOn)
                    ? 1
                    : 0
            );
            me.rv.SetControlValue("SigR_Lit", aspect === cs.AmtrakAspect.Restricting ? 1 : 0);
            me.rv.SetControlValue(
                "SigS_Lit",
                aspect === cs.AmtrakAspect.Restricting || aspect === AduAspect.Stop ? 1 : 0
            );

            const signalSpeedMph = aspect === AduAspect.Stop ? 0 : cs.amtrakAtc.getSpeedMps(aspect) * c.mps.toMph;
            {
                const [[h, t, u]] = m.digits(signalSpeedMph, 3);
                me.rv.SetControlValue("SSHundreds", h);
                me.rv.SetControlValue("SSTens", t);
                me.rv.SetControlValue("SSUnits", u);
            }

            const { trackSpeedMph } = state;
            if (trackSpeedMph !== undefined) {
                const [[h, t, u]] = m.digits(trackSpeedMph, 3);
                me.rv.SetControlValue("TSHundreds", h);
                me.rv.SetControlValue("TSTens", t);
                me.rv.SetControlValue("TSUnits", u);
            } else {
                me.rv.SetControlValue("TSHundreds", -1);
                me.rv.SetControlValue("TSTens", -1);
                me.rv.SetControlValue("TSUnits", -1);
            }
        } else {
            for (const cv of ["SigN_Lit", "SigL_Lit", "SigM_Lit", "SigR_Lit", "SigS_Lit"]) {
                me.rv.SetControlValue(cv, 0);
            }
            for (const cv of ["SSHundreds", "SSTens", "SSUnits", "TSHundreds", "TSTens", "TSUnits"]) {
                me.rv.SetControlValue(cv, -1);
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
                        awsWarnCount: (aduState?.atcAlarm || aduState?.acsesAlarm || alerterState?.alarm) ?? false,
                        vigilAlert: alerterState?.alarm ?? false,
                        signalAlert: (aduState?.atcAlarm || aduState?.acsesAlarm || upgradeSound) ?? false,
                        overspeed: (aduState?.atcAlarm || aduState?.acsesAlarm) ?? false,
                        penalty: (aduState?.penaltyBrake || alerterState?.penaltyBrake) ?? false,
                    };
                },
                aduState,
                alerterState,
                frp.stepper(upgradeSound$, false)
            )
        )
    );
    alarmsUpdate$(({ awsWarnCount, vigilAlert, signalAlert, overspeed, penalty }) => {
        me.rv.SetControlValue("AWSWarnCount", awsWarnCount ? 1 : 0);
        me.rv.SetControlValue("VigilAlert", vigilAlert ? 1 : 0);
        me.rv.SetControlValue("SignalAlert", signalAlert ? 1 : 0);
        me.rv.SetControlValue("Ind_Overspeed", overspeed ? 1 : 0);

        if (penalty) {
            // Tells Reppo's script to stop accepting the player's input.
            me.rv.SetControlValue("Penal", 1);
            // Tells Advanced Braking to apply maximum service braking.
            me.rv.SetControlValue("VirtualBrakeHandle", suppressPos);
        } else {
            me.rv.SetControlValue("Penal", 0);
        }
    });

    // Set consist brake lights.
    fx.createBrakeLightStreamForEngine(me);

    // Set platform door height.
    fx.setLowPlatformDoorsForEngine(me, false);
});
me.setup();
