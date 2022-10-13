/**
 * Amtrak EMD AEM-7
 */

import * as ale from "lib/alerter";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine, PlayerLocation } from "lib/frp-engine";
import { mapBehavior } from "lib/frp-extra";
import { AduAspect } from "lib/nec/adu";
import * as cs from "lib/nec/cabsignals";
import * as adu from "lib/nec/twospeed-adu";
import * as ps from "lib/power-supply";
import * as rw from "lib/railworks";
import * as fx from "lib/special-fx";
import * as ui from "lib/ui";

const me = new FrpEngine(() => {
    // Electric power supply
    const electrification = ps.createElectrificationBehaviorWithLua(me, ps.Electrification.Overhead);

    // Safety systems cut in/out
    // (Reverse the polarity so they are on by default.)
    const speedControlCutIn = () => (me.rv.GetControlValue("SpeedControl", 0) as number) < 0.5;
    ui.createAtcStatusPopup(me, speedControlCutIn);
    ui.createAcsesStatusPopup(me, speedControlCutIn);
    const alerterCutIn = () => (me.rv.GetControlValue("AlertControl", 0) as number) < 0.5;
    ui.createAlerterStatusPopup(me, alerterCutIn);

    // Safety systems and ADU
    const acknowledge = me.createAcknowledgeBehavior();
    const suppression = () => (me.rv.GetControlValue("VirtualBrake", 0) as number) >= 0.5;
    const [aduState$, aduEvents$] = adu.create(
        cs.amtrakAtc,
        me,
        acknowledge,
        suppression,
        speedControlCutIn,
        speedControlCutIn,
        125 * c.mph.toMps,
        ["OverSpeed", 0]
    );
    const aduStateHub$ = frp.compose(aduState$, frp.hub());
    aduStateHub$(state => {
        me.rv.SetControlValue(
            "CabSignal",
            0,
            {
                [AduAspect.Stop]: 7, // The AEM-7 does not have a proper Stop aspect.
                [cs.AmtrakAspect.Restricting]: 7,
                [cs.AmtrakAspect.Approach]: 6,
                [cs.AmtrakAspect.ApproachMedium]: 6,
                [cs.AmtrakAspect.ApproachLimited]: 4,
                [cs.AmtrakAspect.CabSpeed60]: 3,
                [cs.AmtrakAspect.CabSpeed80]: 2,
                [cs.AmtrakAspect.Clear100]: 0,
                [cs.AmtrakAspect.Clear125]: 0,
                [cs.AmtrakAspect.Clear150]: 0,
            }[state.aspect]
        );
        // Top green head
        me.rv.SetControlValue(
            "CabSignal1",
            0,
            ((state.aspect === cs.AmtrakAspect.CabSpeed60 || state.aspect === cs.AmtrakAspect.CabSpeed80) &&
                state.aspectFlashOn) ||
                state.aspect === cs.AmtrakAspect.Clear100 ||
                state.aspect === cs.AmtrakAspect.Clear125 ||
                state.aspect === cs.AmtrakAspect.Clear150
                ? 1
                : 0
        );
        // Bottom green head
        me.rv.SetControlValue(
            "CabSignal2",
            0,
            state.aspect === cs.AmtrakAspect.ApproachMedium ||
                (state.aspect === cs.AmtrakAspect.ApproachLimited && state.aspectFlashOn)
                ? 1
                : 0
        );

        const blankTrackSpeed = 9.5;
        me.rv.SetControlValue("TrackSpeed", 0, state.trackSpeedMph ?? blankTrackSpeed);
    });
    const aduState = frp.stepper(aduStateHub$, undefined);
    // Alerter
    const alerterReset$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.filter(([name]) => name === "VirtualThrottle" || name === "VirtualBrake")
    );
    const alerterState = frp.stepper(ale.create(me, acknowledge, alerterReset$, alerterCutIn), undefined);
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
                        aws: (aduState?.alarm || alerterState?.alarm) ?? false,
                        awsWarnCount: alerterState?.alarm ?? false,
                        overSpeedAlert: (aduState?.alarm ?? false) || upgradeSound,
                    };
                },
                aduState,
                alerterState,
                frp.stepper(upgradeSound$, false)
            )
        )
    );
    alarmsUpdate$(cvs => {
        me.rv.SetControlValue("AWS", 0, cvs.aws ? 1 : 0);
        me.rv.SetControlValue("AWSWarnCount", 0, cvs.awsWarnCount ? 1 : 0);
        me.rv.SetControlValue("OverSpeedAlert", 0, cvs.overSpeedAlert ? 1 : 0);
    });

    // Cruise control
    const cruiseTargetMps = () => {
        const targetMph = me.rv.GetControlValue("CruiseSet", 0) as number;
        return targetMph * c.mph.toMps;
    };
    const cruiseOn = frp.liftN(targetMps => targetMps > 10 * c.mph.toMps, cruiseTargetMps);
    const cruiseOutput = frp.stepper(me.createCruiseControlStream(cruiseOn, cruiseTargetMps), 0);

    // Throttle, air brake, and dynamic brake controls
    const isPowerAvailable = () => ps.uniModeEngineHasPower(ps.EngineMode.Overhead, electrification);
    const isPenaltyBrake = frp.liftN(
        (aduState, alerterState) => (aduState?.penaltyBrake || alerterState?.penaltyBrake) ?? false,
        aduState,
        alerterState
    );
    const airBrake = frp.liftN(
        (isPenaltyBrake, cutIn, input) => {
            if (!cutIn) {
                return 1;
            } else if (isPenaltyBrake) {
                return 0.99;
            } else {
                return input;
            }
        },
        isPenaltyBrake,
        () => (me.rv.GetControlValue("CutIn", 0) as number) > 0.5,
        () => me.rv.GetControlValue("VirtualBrake", 0) as number
    );
    // DTG's "blended braking" algorithm
    const dynamicBrake = frp.liftN(airBrake => airBrake / 2, airBrake);
    const controlsUpdate$ = me.createPlayerWithKeyUpdateStream();
    controlsUpdate$(_ => {
        me.rv.SetControlValue("Regulator", 0, frp.snapshot(throttle));
        me.rv.SetControlValue("TrainBrakeControl", 0, frp.snapshot(airBrake));
        me.rv.SetControlValue("DynamicBrake", 0, frp.snapshot(dynamicBrake));
    });
    const throttle = frp.liftN(
        (isPowerAvailable, isPenaltyBrake, airBrake, cruiseOn, cruiseOutput, input) => {
            if (!isPowerAvailable || isPenaltyBrake || airBrake > 0) {
                return 0;
            } else if (cruiseOn) {
                return Math.min(cruiseOutput, input);
            } else {
                return input;
            }
        },
        isPowerAvailable,
        isPenaltyBrake,
        airBrake,
        cruiseOn,
        cruiseOutput,
        () => me.rv.GetControlValue("VirtualThrottle", 0) as number
    );

    // Cab dome lights, front and rear
    const cabLightFront = new rw.Light("FrontCabLight");
    const cabLightRear = new rw.Light("RearCabLight");
    const playerLocation = me.createPlayerLocationBehavior();
    const cabLightControl = () => (me.rv.GetControlValue("CabLightControl", 0) as number) > 0.5;
    const cabLightFrontOn = frp.liftN(
        (player, control) => player === PlayerLocation.InFrontCab && control,
        playerLocation,
        cabLightControl
    );
    const cabLightRearOn = frp.liftN(
        (player, control) => player === PlayerLocation.InRearCab && control,
        playerLocation,
        cabLightControl
    );
    const cabLightUpdate$ = me.createUpdateStream();
    cabLightUpdate$(_ => {
        cabLightFront.Activate(frp.snapshot(cabLightFrontOn));
        cabLightRear.Activate(frp.snapshot(cabLightRearOn));
    });

    // Possibly used for a sound effect?
    const dynamicCurrent$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("Ammeter", 0),
        frp.map(v => Math.abs(v))
    );
    dynamicCurrent$(v => {
        me.rv.SetControlValue("DynamicCurrent", 0, v);
    });

    // Process OnControlValueChange events.
    const onCvChange$ = me.createOnCvChangeStream();
    onCvChange$(([name, index, value]) => {
        me.rv.SetControlValue(name, index, value);
    });

    // Set consist brake lights.
    fx.createBrakeLightStreamForEngine(me);

    // Enable updates.
    me.activateUpdatesEveryFrame(true);
});
me.setup();
