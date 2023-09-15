/**
 * Metro-North Bombardier Shoreliner Cab Car
 */

import * as ale from "lib/alerter";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { mapBehavior, once, rejectRepeats } from "lib/frp-extra";
import { AduAspect } from "lib/nec/adu";
import * as cs from "lib/nec/cabsignals";
import * as adu from "lib/nec/twospeed-adu";
import * as m from "lib/math";
import * as ps from "lib/power-supply";
import * as rw from "lib/railworks";
import * as fx from "lib/special-fx";
import * as ui from "lib/ui";
import { SensedDirection } from "lib/frp-vehicle";

// Annoyingly, the power modes are reversed for the Shoreliner. We'll use the
// P32's order internally and reverse the player's input to the Shoreliner. The
// downside is that this flips the mode if the player switches ends.
const dualModeOrder: [ps.EngineMode.ThirdRail, ps.EngineMode.Diesel] = [ps.EngineMode.ThirdRail, ps.EngineMode.Diesel];
const dualModeSwitchS = 20;

const me = new FrpEngine(() => {
    // Dual-mode power supply
    const electrification = ps.createElectrificationBehaviorWithControlValues(me, {
        [ps.Electrification.Overhead]: ["PowerOverhead", 0],
        [ps.Electrification.ThirdRail]: ["Power3rdRail", 0],
    });
    const modeAuto = () => (me.rv.GetControlValue("ExpertPowerMode", 0) as number) > 0.5;
    ui.createAutoPowerStatusPopup(me, modeAuto);
    const modeAutoSwitch$ = ps.createDualModeAutoSwitchStream(me, ...dualModeOrder, modeAuto);
    modeAutoSwitch$(mode => {
        me.rv.SetControlValue("PowerMode", 0, mode === ps.EngineMode.Diesel ? 0 : 1); // reversed
    });
    const modeSelect = () => {
        const cv = Math.round(me.rv.GetControlValue("PowerMode", 0) as number);
        return cv > 0.5 ? ps.EngineMode.ThirdRail : ps.EngineMode.Diesel; // reversed
    };
    const modePosition = ps.createDualModeEngineBehavior(
        me,
        ...dualModeOrder,
        modeSelect,
        ps.EngineMode.Diesel, // doesn't matter
        () => {
            const throttle = me.rv.GetControlValue("VirtualThrottle", 0) as number;
            return throttle < 0.5;
        },
        dualModeSwitchS,
        modeAutoSwitch$,
        () => (me.rv.GetControlValue("PowerStart", 0) as number) - 1
    );
    const setModePosition$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(modePosition),
        rejectRepeats()
    );
    setModePosition$(position => {
        me.rv.SetControlValue("PowerStart", 0, position + 1);
    });
    // Power3rdRail is not set correctly in the third-rail engine blueprint, so
    // set it ourselves based on the value of PowerMode.
    const resumeFromSave = frp.stepper(me.createFirstUpdateStream(), false);
    const fixElectrification$ = frp.compose(
        me.createUpdateStream(),
        frp.filter(_ => !frp.snapshot(resumeFromSave) && frp.snapshot(me.areControlsSettled)),
        once(),
        mapBehavior(modeSelect),
        frp.map(mode => (mode === ps.EngineMode.ThirdRail ? 1 : 0))
    );
    fixElectrification$(thirdRail => {
        me.rv.SetControlValue("Power3rdRail", 0, thirdRail);
    });

    // Safety systems cut in/out
    const atcCutIn = () => (me.rv.GetControlValue("ATCCutIn", 0) as number) > 0.5;
    ui.createAtcStatusPopup(me, atcCutIn);
    const alerterCutIn = () => (me.rv.GetControlValue("ACSESCutIn", 0) as number) > 0.5;
    ui.createAlerterStatusPopup(me, alerterCutIn);

    // Safety systems and ADU
    const acknowledge = me.createAcknowledgeBehavior();
    const suppression = () => (me.rv.GetControlValue("TrainBrakeControl", 0) as number) >= 0.4;
    const [aduState$, aduEvents$] = adu.create(
        cs.metroNorthAtc,
        me,
        acknowledge,
        suppression,
        atcCutIn,
        () => false,
        80 * c.mph.toMps,
        ["SignalSpeedLimit", 0]
    );
    const aduStateHub$ = frp.compose(aduState$, frp.hub());
    aduStateHub$(state => {
        me.rv.SetControlValue("SigN", 0, state.aspect === cs.FourAspect.Clear ? 1 : 0);
        me.rv.SetControlValue("SigL", 0, state.aspect === cs.FourAspect.ApproachLimited ? 1 : 0);
        me.rv.SetControlValue("SigM", 0, state.aspect === cs.FourAspect.Approach ? 1 : 0);
        me.rv.SetControlValue(
            "SigR",
            0,
            state.aspect === cs.FourAspect.Restricting || state.aspect === AduAspect.Stop ? 1 : 0
        );
    });
    const aduState = frp.stepper(aduStateHub$, undefined);
    // Alerter
    const alerterReset$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.filter(([name]) => name === "VirtualThrottle" || name === "TrainBrakeControl")
    );
    const alerterState = frp.stepper(ale.create(me, acknowledge, alerterReset$, alerterCutIn), undefined);
    // Safety system sounds
    const upgradeEvents$ = frp.compose(
        aduEvents$,
        frp.filter(evt => evt === adu.AduEvent.Upgrade)
    );
    const upgradeSound$ = frp.compose(me.createPlayerWithKeyUpdateStream(), fx.triggerSound(1, upgradeEvents$));
    upgradeSound$(play => {
        me.rv.SetControlValue("SpeedIncreaseAlert", 0, play ? 1 : 0);
    });
    const alarmsUpdate$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                (aduState, alerterState) =>
                    (aduState?.atcAlarm || aduState?.acsesAlarm || alerterState?.alarm) ?? false,
                aduState,
                alerterState
            )
        )
    );
    alarmsUpdate$(play => {
        me.rv.SetControlValue("AWS", 0, play ? 1 : 0);
        me.rv.SetControlValue("AWSWarnCount", 0, play ? 1 : 0);
    });

    // Throttle, dynamic brake, and air brake controls
    const isPenaltyBrake = frp.liftN(
        (aduState, alerterState) => (aduState?.penaltyBrake || alerterState?.penaltyBrake) ?? false,
        aduState,
        alerterState
    );
    const isPowerAvailable = frp.liftN(
        position => ps.dualModeEngineHasPower(position, ...dualModeOrder, electrification),
        modePosition
    );
    const throttle = frp.liftN(
        (isPenaltyBrake, isPowerAvailable, input) => (isPenaltyBrake || !isPowerAvailable ? 0 : input),
        isPenaltyBrake,
        isPowerAvailable,
        () => me.rv.GetControlValue("VirtualThrottle", 0) as number
    );
    const throttle$ = frp.compose(me.createPlayerWithKeyUpdateStream(), mapBehavior(throttle));
    throttle$(v => {
        me.rv.SetControlValue("Regulator", 0, v);
    });
    // There's no virtual train brake, so just move the braking handle.
    const fullService = 0.6;
    const setPenaltyBrake$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.filter(_ => frp.snapshot(isPenaltyBrake)),
        frp.map(_ => fullService)
    );
    setPenaltyBrake$(v => {
        me.rv.SetControlValue("TrainBrakeControl", 0, v);
    });
    // DTG's "blended braking" algorithm (from the P32)
    const dynamicBrake = frp.liftN(
        (modeSelect, brakePipePsi) => {
            return modeSelect === ps.EngineMode.Diesel ? (70 - brakePipePsi) * 0.01428 : 0;
        },
        modeSelect,
        () => me.rv.GetControlValue("AirBrakePipePressurePSI", 0) as number
    );
    const dynamicBrake$ = frp.compose(me.createPlayerWithKeyUpdateStream(), mapBehavior(dynamicBrake));
    dynamicBrake$(v => {
        me.rv.SetControlValue("DynamicBrake", 0, v);
    });

    // Ditch lights
    const areHeadLightsOn = () => {
        const cv = me.rv.GetControlValue("Headlights", 0) as number;
        return cv > 0.5 && cv < 1.5;
    };
    const ditchLightsPlayer$ = frp.compose(me.createPlayerWithKeyUpdateStream(), mapBehavior(areHeadLightsOn));
    const ditchLightsAi$ = frp.compose(
        me.createAiUpdateStream(),
        frp.map(au => au.direction === SensedDirection.Forward)
    );
    const ditchLights$ = frp.compose(
        me.createPlayerWithoutKeyUpdateStream(),
        frp.map(_ => false),
        frp.merge(ditchLightsPlayer$),
        frp.merge(ditchLightsAi$),
        rejectRepeats()
    );
    ditchLights$(on => {
        me.rv.ActivateNode("ditch_left", on);
        me.rv.ActivateNode("ditch_right", on);
    });

    // Horn rings the bell.
    const bellControl$ = frp.compose(
        me.createOnCvChangeStreamFor("Horn", 0),
        frp.filter(v => v === 1),
        me.mapAutoBellStream()
    );
    bellControl$(v => {
        me.rv.SetControlValue("Bell", 0, v);
    });

    // Speedometer
    const aSpeedoMph$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("SpeedometerMPH", 0),
        frp.map(mph => Math.abs(mph))
    );
    aSpeedoMph$(mph => {
        const [[h, t, u]] = m.digits(mph, 3);
        me.rv.SetControlValue("SpeedoHundreds", 0, h);
        me.rv.SetControlValue("SpeedoTens", 0, t);
        me.rv.SetControlValue("SpeedoUnits", 0, u);
    });

    // Cab dome light
    const cabLight = new rw.Light("CabLight");
    const cabLightPlayer$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("CabLight", 0),
        frp.map(v => v > 0.5)
    );
    const cabLight$ = frp.compose(
        me.createPlayerWithoutKeyUpdateStream(),
        frp.merge(me.createAiUpdateStream()),
        frp.map(_ => false),
        frp.merge(cabLightPlayer$),
        rejectRepeats()
    );
    cabLight$(on => {
        cabLight.Activate(on);
    });

    // Exterior windows
    const windowsUpdate$ = me.createPlayerWithKeyUpdateStream();
    windowsUpdate$(_ => {
        me.rv.SetTime("LeftWindow", (me.rv.GetControlValue("Window Left", 0) as number) * 2);
        me.rv.SetTime("RightWindow", (me.rv.GetControlValue("Window Right", 0) as number) * 2);
    });

    // Process OnControlValueChange events.
    const onCvChange$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.reject(([name]) => name === "Bell")
    );
    onCvChange$(([name, index, value]) => {
        me.rv.SetControlValue(name, index, value);
    });

    // Set consist brake lights.
    const brakeLight$ = frp.compose(fx.createBrakeLightStreamForEngine(me), rejectRepeats());
    brakeLight$(on => {
        me.rv.ActivateNode("brakelight", on);
    });

    // Set platform door height.
    fx.setLowPlatformDoorsForEngine(me, true);

    // Enable updates.
    me.e.BeginUpdate();
});
me.setup();
