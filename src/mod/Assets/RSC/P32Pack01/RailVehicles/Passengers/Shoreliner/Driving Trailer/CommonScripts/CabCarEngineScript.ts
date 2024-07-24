/**
 * Metro-North Bombardier Shoreliner Cab Car
 */

import * as ale from "lib/alerter";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { mapBehavior, rejectRepeats } from "lib/frp-extra";
import { SensedDirection } from "lib/frp-vehicle";
import * as m from "lib/math";
import { AduAspect } from "lib/nec/adu";
import * as cs from "lib/nec/cabsignals";
import * as adu from "lib/nec/twospeed-adu";
import * as ps from "lib/power-supply";
import * as rw from "lib/railworks";
import { dualModeOrder, dualModeSwitchS } from "lib/shared/p32";
import * as fx from "lib/special-fx";
import * as ui from "lib/ui";

const me = new FrpEngine(() => {
    // Dual-mode power supply
    const electrification = ps.createElectrificationBehaviorWithControlValues(me, {
        [ps.Electrification.Overhead]: "PowerOverhead",
        [ps.Electrification.ThirdRail]: "Power3rdRail",
    });
    const modeAuto = () => (me.rv.GetControlValue("ExpertPowerMode") as number) > 0.5;
    ui.createAutoPowerStatusPopup(me, modeAuto);
    // Annoyingly, the power modes are reversed for the Shoreliner. We'll use
    // the P32's order internally and reverse the player's input to the
    // Shoreliner. The downside is that this flips the mode if the player
    // switches ends.
    const modeAutoSwitch$ = ps.createDualModeAutoSwitchStream(me, ...dualModeOrder, modeAuto);
    modeAutoSwitch$(mode => {
        me.rv.SetControlValue("PowerMode", mode === ps.EngineMode.Diesel ? 0 : 1); // reversed
    });
    const modeSelect = () => {
        const cv = me.rv.GetControlValue("PowerMode") as number;
        return cv > 0.5 ? ps.EngineMode.ThirdRail : ps.EngineMode.Diesel; // reversed
    };
    const modePosition = ps.createDualModeEngineBehavior({
        e: me,
        modes: dualModeOrder,
        getPlayerMode: modeSelect,
        getAiMode: ps.EngineMode.Diesel,
        getPlayerCanSwitch: () => {
            const throttle = me.rv.GetControlValue("VirtualThrottle") as number;
            return throttle < 0.5;
        },
        transitionS: dualModeSwitchS,
        instantSwitch: modeAutoSwitch$,
        positionFromSaveOrConsist: () => (me.rv.GetControlValue("PowerStart") as number) - 1,
    });
    const setModePosition$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(modePosition),
        rejectRepeats()
    );
    setModePosition$(position => {
        me.rv.SetControlValue("PowerStart", position + 1);
    });
    // Power3rdRail is not set correctly in the third-rail engine blueprint, so
    // set it ourselves based on the value of PowerMode.
    const fixElectrification$ = frp.compose(
        me.createFirstUpdateAfterControlsSettledStream(),
        frp.filter(resumeFromSave => !resumeFromSave),
        mapBehavior(modeSelect),
        frp.map(mode => (mode === ps.EngineMode.ThirdRail ? 1 : 0))
    );
    fixElectrification$(thirdRail => {
        me.rv.SetControlValue("Power3rdRail", thirdRail);
    });

    // Safety systems cut in/out
    const atcCutIn = () => (me.rv.GetControlValue("ATCCutIn") as number) > 0.5;
    ui.createAtcStatusPopup(me, atcCutIn);
    const alerterCutIn = () => (me.rv.GetControlValue("ACSESCutIn") as number) > 0.5;
    ui.createAlerterStatusPopup(me, alerterCutIn);

    // Safety systems and ADU
    const acknowledge = me.createAcknowledgeBehavior();
    const suppression = frp.liftN(
        (bp, lever) => bp || lever,
        me.createBrakePressureSuppressionBehavior(),
        () => (me.rv.GetControlValue("TrainBrakeControl") as number) >= 0.4
    );
    const [aduState$, aduEvents$] = adu.create({
        atc: cs.metroNorthAtc,
        e: me,
        acknowledge,
        suppression,
        atcCutIn,
        acsesCutIn: () => false,
        equipmentSpeedMps: 80 * c.mph.toMps,
        pulseCodeControlValue: "SignalSpeedLimit",
    });
    const aduStateHub$ = frp.compose(aduState$, frp.hub());
    aduStateHub$(({ aspect }) => {
        me.rv.SetControlValue("SigN", aspect === cs.FourAspect.Clear ? 1 : 0);
        me.rv.SetControlValue("SigL", aspect === cs.FourAspect.ApproachLimited ? 1 : 0);
        me.rv.SetControlValue("SigM", aspect === cs.FourAspect.Approach ? 1 : 0);
        me.rv.SetControlValue("SigR", aspect === cs.FourAspect.Restricting || aspect === AduAspect.Stop ? 1 : 0);
    });
    const aduState = frp.stepper(aduStateHub$, undefined);
    // Alerter
    const alerterState = frp.stepper(ale.create({ e: me, acknowledge, cutIn: alerterCutIn }), undefined);
    // Safety system sounds
    const upgradeEvents$ = frp.compose(
        aduEvents$,
        frp.filter(evt => evt === adu.AduEvent.Upgrade)
    );
    const upgradeSound$ = frp.compose(me.createPlayerWithKeyUpdateStream(), fx.triggerSound(1, upgradeEvents$));
    upgradeSound$(play => {
        me.rv.SetControlValue("SpeedIncreaseAlert", play ? 1 : 0);
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
        me.rv.SetControlValue("AWS", play ? 1 : 0);
        me.rv.SetControlValue("AWSWarnCount", play ? 1 : 0);
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
        () => me.rv.GetControlValue("VirtualThrottle") as number
    );
    const throttle$ = frp.compose(me.createPlayerWithKeyUpdateStream(), mapBehavior(throttle));
    throttle$(v => {
        me.rv.SetControlValue("Regulator", v);
    });
    // There's no virtual train brake, so just move the braking handle.
    const fullService = 0.6;
    const setPenaltyBrake$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.filter(_ => frp.snapshot(isPenaltyBrake)),
        frp.map(_ => fullService)
    );
    setPenaltyBrake$(v => {
        me.rv.SetControlValue("TrainBrakeControl", v);
    });
    // DTG's "blended braking" algorithm (from the P32)
    const dynamicBrake = frp.liftN(
        (modeSelect, brakePipePsi) => {
            return modeSelect === ps.EngineMode.Diesel ? (70 - brakePipePsi) * 0.01428 : 0;
        },
        modeSelect,
        () => me.rv.GetControlValue("AirBrakePipePressurePSI") as number
    );
    const dynamicBrake$ = frp.compose(me.createPlayerWithKeyUpdateStream(), mapBehavior(dynamicBrake));
    dynamicBrake$(v => {
        me.rv.SetControlValue("DynamicBrake", v);
    });

    // Ditch lights
    const areHeadLightsOn = () => {
        const cv = me.rv.GetControlValue("Headlights") as number;
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
        me.createOnCvChangeStreamFor("Horn"),
        frp.filter(v => v === 1),
        me.mapAutoBellStream()
    );
    bellControl$(v => {
        me.rv.SetControlValue("Bell", v);
    });

    // Speedometer
    const speedoMph$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(me.createSpeedometerDigitsMphBehavior(3))
    );
    speedoMph$(([[h, t, u]]) => {
        me.rv.SetControlValue("SpeedoHundreds", h);
        me.rv.SetControlValue("SpeedoTens", t);
        me.rv.SetControlValue("SpeedoUnits", u);
    });

    // Cab dome light
    const cabLight = new rw.Light("CabLight");
    const cabLightPlayer$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("CabLight"),
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

    // Passenger interior lights
    const passExteriorLights: rw.Light[] = [];
    for (let i = 0; i < 8; i++) {
        passExteriorLights.push(new rw.Light(`Carriage Light ${i + 1}`));
    }
    const passExteriorLight$ = frp.compose(
        me.createPlayerUpdateStream(),
        frp.map(_ => true),
        frp.merge(
            frp.compose(
                me.createAiUpdateStream(),
                frp.map(_ => false)
            )
        ),
        rejectRepeats()
    );
    passExteriorLight$(on => {
        passExteriorLights.forEach(light => light.Activate(on));
    });

    // Exterior windows
    const leftWindow$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                position => position * 2,
                () => me.rv.GetControlValue("Window Left") as number
            )
        ),
        rejectRepeats()
    );
    const rightWindow$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                position => position * 2,
                () => me.rv.GetControlValue("Window Right") as number
            )
        ),
        rejectRepeats()
    );
    leftWindow$(t => {
        me.rv.SetTime("LeftWindow", t);
    });
    rightWindow$(t => {
        me.rv.SetTime("RightWindow", t);
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
