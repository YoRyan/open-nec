/**
 * Amtrak EMD AEM-7
 */

import * as ale from "lib/alerter";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine, PlayerLocation } from "lib/frp-engine";
import { mapBehavior, rejectRepeats } from "lib/frp-extra";
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
    const isPowerAvailable = () => ps.uniModeEngineHasPower(ps.EngineMode.Overhead, electrification);

    // Safety systems cut in/out
    // (Reverse the polarity so they are on by default.)
    const speedControlCutIn = () => (me.rv.GetControlValue("SpeedControl") as number) < 0.5;
    ui.createAtcStatusPopup(me, speedControlCutIn);
    ui.createAcsesStatusPopup(me, speedControlCutIn);
    const alerterCutIn = () => (me.rv.GetControlValue("AlertControl") as number) < 0.5;
    ui.createAlerterStatusPopup(me, alerterCutIn);

    // Safety systems and ADU
    const acknowledge = me.createAcknowledgeBehavior();
    const suppression = () => (me.rv.GetControlValue("VirtualBrake") as number) >= 0.5;
    const [aduState$, aduEvents$] = adu.create({
        atc: cs.amtrakAtc,
        e: me,
        acknowledge,
        suppression,
        atcCutIn: speedControlCutIn,
        acsesCutIn: speedControlCutIn,
        equipmentSpeedMps: 125 * c.mph.toMps,
        pulseCodeControlValue: "OverSpeed",
    });
    const aduStateHub$ = frp.compose(aduState$, frp.hub());
    aduStateHub$(state => {
        me.rv.SetControlValue(
            "CabSignal",
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
            state.aspect === cs.AmtrakAspect.ApproachMedium ||
                (state.aspect === cs.AmtrakAspect.ApproachLimited && state.aspectFlashOn)
                ? 1
                : 0
        );

        const blankTrackSpeed = 9.5;
        me.rv.SetControlValue("TrackSpeed", state.trackSpeedMph ?? blankTrackSpeed);
    });
    const aduState = frp.stepper(aduStateHub$, undefined);
    // Alerter
    const alerterReset$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.filter(([name]) => name === "VirtualThrottle" || name === "VirtualBrake")
    );
    const alerterState = frp.stepper(
        ale.create({ e: me, acknowledge, acknowledgeStream: alerterReset$, cutIn: alerterCutIn }),
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
                        aws: (aduState?.atcAlarm || aduState?.acsesAlarm || alerterState?.alarm) ?? false,
                        awsWarnCount: alerterState?.alarm ?? false,
                        overSpeedAlert: (aduState?.atcAlarm || aduState?.acsesAlarm || upgradeSound) ?? false,
                    };
                },
                aduState,
                alerterState,
                frp.stepper(upgradeSound$, false)
            )
        )
    );
    alarmsUpdate$(cvs => {
        me.rv.SetControlValue("AWS", cvs.aws ? 1 : 0);
        me.rv.SetControlValue("AWSWarnCount", cvs.awsWarnCount ? 1 : 0);
        me.rv.SetControlValue("OverSpeedAlert", cvs.overSpeedAlert ? 1 : 0);
    });

    // Cruise control
    const cruiseTargetMps = () => {
        const targetMph = me.rv.GetControlValue("CruiseSet") as number;
        return targetMph * c.mph.toMps;
    };
    const cruiseOn = frp.liftN(targetMps => targetMps > 10 * c.mph.toMps, cruiseTargetMps);
    const cruiseOutput = frp.stepper(me.createCruiseControlStream(cruiseOn, cruiseTargetMps), 0);

    // Throttle, air brake, and dynamic brake controls
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
        () => (me.rv.GetControlValue("CutIn") as number) > 0.5,
        () => me.rv.GetControlValue("VirtualBrake") as number
    );
    // DTG's "blended braking" algorithm
    const dynamicBrake = frp.liftN(airBrake => airBrake / 2, airBrake);
    const controlsUpdate$ = me.createPlayerWithKeyUpdateStream();
    controlsUpdate$(_ => {
        me.rv.SetControlValue("Regulator", frp.snapshot(throttle));
        me.rv.SetControlValue("TrainBrakeControl", frp.snapshot(airBrake));
        me.rv.SetControlValue("DynamicBrake", frp.snapshot(dynamicBrake));
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
        () => me.rv.GetControlValue("VirtualThrottle") as number
    );

    // Horn rings the bell.
    const bellControl$ = frp.compose(
        me.createOnCvChangeStreamFor("Horn"),
        frp.filter(v => v > 0),
        me.mapAutoBellStream()
    );
    bellControl$(v => {
        me.rv.SetControlValue("Bell", v);
    });

    // Cab dome lights, front and rear
    const playerLocation = me.createPlayerLocationBehavior();
    const cabLightControl = () => (me.rv.GetControlValue("CabLightControl") ?? 0) > 0.5;
    const allCabLights: [location: PlayerLocation, light: rw.Light][] = [
        [PlayerLocation.InFrontCab, new rw.Light("FrontCabLight")],
        [PlayerLocation.InRearCab, new rw.Light("RearCabLight")],
    ];
    const cabLightNonPlayer$ = frp.compose(
        me.createAiUpdateStream(),
        frp.merge(me.createPlayerWithoutKeyUpdateStream()),
        frp.map(_ => false)
    );
    allCabLights.forEach(([location, light]) => {
        const setOnOff$ = frp.compose(
            me.createPlayerWithKeyUpdateStream(),
            frp.map(_ => (frp.snapshot(playerLocation) === location ? frp.snapshot(cabLightControl) : false)),
            frp.merge(cabLightNonPlayer$),
            rejectRepeats()
        );
        setOnOff$(on => {
            light.Activate(on);
        });
    });

    // Possibly used for a sound effect?
    const dynamicCurrent$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("Ammeter"),
        frp.map(v => Math.abs(v))
    );
    dynamicCurrent$(v => {
        me.rv.SetControlValue("DynamicCurrent", v);
    });

    // Process OnControlValueChange events.
    const onCvChange$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.reject(([name]) => name === "Bell")
    );
    onCvChange$(([name, value]) => {
        me.rv.SetControlValue(name, value);
    });

    // Set consist brake lights.
    fx.createBrakeLightStreamForEngine(me);

    // Set platform door height.
    fx.setLowPlatformDoorsForEngine(me, false);

    // Enable updates.
    me.e.BeginUpdate();
});
me.setup();
