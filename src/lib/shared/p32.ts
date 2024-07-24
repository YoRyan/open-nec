/**
 * Metro-North/Amtrak GE P32AC-DM
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
import * as fx from "lib/special-fx";
import * as ui from "lib/ui";

export const dualModeOrder: [ps.EngineMode.ThirdRail, ps.EngineMode.Diesel] = [
    ps.EngineMode.ThirdRail,
    ps.EngineMode.Diesel,
];
export const dualModeSwitchS = 20;

const ditchLightsFadeS = 0.3;
const ditchLightFlashS = 0.65;
const taskLightFadeS = 0.8 / 2;

export function onInit(me: FrpEngine, isAmtrak: boolean) {
    // Dual-mode power supply
    const electrification = ps.createElectrificationBehaviorWithControlValues(me, {
        [ps.Electrification.Overhead]: "PowerOverhead",
        [ps.Electrification.ThirdRail]: "Power3rdRail",
    });
    const modeAuto = () => (me.rv.GetControlValue("ExpertPowerMode") as number) > 0.5;
    ui.createAutoPowerStatusPopup(me, modeAuto);
    const modeAutoSwitch$ = ps.createDualModeAutoSwitchStream(me, ...dualModeOrder, modeAuto);
    modeAutoSwitch$(mode => {
        me.rv.SetControlValue("PowerMode", mode === ps.EngineMode.Diesel ? 1 : 0);
    });
    const modeSelect = () => {
        const cv = Math.round(me.rv.GetControlValue("PowerMode") as number);
        return cv < 0.5 ? ps.EngineMode.ThirdRail : ps.EngineMode.Diesel;
    };
    const modePosition = ps.createDualModeEngineBehavior({
        e: me,
        modes: dualModeOrder,
        getPlayerMode: modeSelect,
        getAiMode: modeSelect,
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
    const acsesCutIn = () => (me.rv.GetControlValue("ACSESCutIn") as number) > 0.5;
    ui.createAtcStatusPopup(me, atcCutIn);
    ui.createAcsesStatusPopup(me, acsesCutIn);
    const alerterCutIn = frp.liftN((atcCutIn, acsesCutIn) => atcCutIn || acsesCutIn, atcCutIn, acsesCutIn);
    ui.createAlerterStatusPopup(me, alerterCutIn);

    // Safety systems and ADU
    const acknowledge = me.createAcknowledgeBehavior();
    const suppression = () => (me.rv.GetControlValue("TrainBrakeControl") as number) >= 0.4;
    const [aduState$, aduEvents$] = adu.create({
        atc: isAmtrak ? cs.fourAspectAtc : cs.metroNorthAtc,
        e: me,
        acknowledge,
        suppression,
        atcCutIn,
        acsesCutIn,
        equipmentSpeedMps: (isAmtrak ? 110 : 80) * c.mph.toMps,
        pulseCodeControlValue: "SignalSpeedLimit",
    });
    const aduStateHub$ = frp.compose(aduState$, frp.hub());
    aduStateHub$(({ aspect, trackSpeedMph }) => {
        me.rv.SetControlValue("SigN", aspect === cs.FourAspect.Clear ? 1 : 0);
        me.rv.SetControlValue("SigL", aspect === cs.FourAspect.ApproachLimited ? 1 : 0);
        me.rv.SetControlValue("SigM", aspect === cs.FourAspect.Approach ? 1 : 0);
        me.rv.SetControlValue("SigR", aspect === cs.FourAspect.Restricting || aspect === AduAspect.Stop ? 1 : 0);

        me.rv.SetControlValue(
            "SignalSpeed",
            {
                [AduAspect.Stop]: 0,
                [cs.FourAspect.Restricting]: 15,
                [cs.FourAspect.Approach]: 30,
                [cs.FourAspect.ApproachLimited]: 45,
                [cs.FourAspect.Clear]: -1,
            }[aspect]
        );

        if (trackSpeedMph !== undefined) {
            const [[h, t, u]] = m.digits(trackSpeedMph, 3);
            me.rv.SetControlValue("TrackHundreds", h);
            me.rv.SetControlValue("TrackTens", t);
            me.rv.SetControlValue("TrackUnits", u);
        } else {
            me.rv.SetControlValue("TrackHundreds", -1);
            me.rv.SetControlValue("TrackTens", -1);
            me.rv.SetControlValue("TrackUnits", -1);
        }
    });
    const aduState = frp.stepper(aduStateHub$, undefined);
    // Alerter
    const alerter$ = frp.compose(ale.create({ e: me, acknowledge, cutIn: alerterCutIn }), frp.hub());
    const alerterState = frp.stepper(alerter$, undefined);
    alerter$(({ alarm }) => {
        me.rv.SetControlValue("AlerterVisual", alarm ? 1 : 0);
    });
    // Safety system sounds
    const upgradeEvents$ = frp.compose(
        aduEvents$,
        frp.filter(evt => evt === adu.AduEvent.Upgrade)
    );
    const upgradeSound$ = frp.compose(me.createPlayerWithKeyUpdateStream(), fx.triggerSound(1, upgradeEvents$));
    const alarmsUpdate$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                (aduState, alerterState, upgradeSound) => {
                    return {
                        aws: aduState?.atcAlarm || aduState?.acsesAlarm || alerterState?.alarm || upgradeSound,
                        awsWarnCount: (aduState?.atcAlarm || aduState?.acsesAlarm || alerterState?.alarm) ?? false,
                    };
                },
                aduState,
                alerterState,
                frp.stepper(upgradeSound$, false)
            )
        )
    );
    alarmsUpdate$(({ aws, awsWarnCount }) => {
        me.rv.SetControlValue("AWS", aws ? 1 : 0);
        me.rv.SetControlValue("AWSWarnCount", awsWarnCount ? 1 : 0);
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
    const fullService = 0.85;
    const setPenaltyBrake$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.filter(_ => frp.snapshot(isPenaltyBrake)),
        frp.map(_ => fullService)
    );
    setPenaltyBrake$(v => {
        me.rv.SetControlValue("TrainBrakeControl", v);
    });
    // DTG's "blended braking" algorithm
    const dynamicBrake = frp.liftN(
        (modePosition, brakePipePsi) => {
            const isDiesel = modePosition === 1;
            return isDiesel ? (70 - brakePipePsi) * 0.01428 : 0;
        },
        modePosition,
        () => me.rv.GetControlValue("AirBrakePipePressurePSI") as number
    );
    const dynamicBrake$ = frp.compose(me.createPlayerWithKeyUpdateStream(), mapBehavior(dynamicBrake));
    dynamicBrake$(v => {
        me.rv.SetControlValue("DynamicBrake", v);
    });

    // Ditch lights
    const ditchLights = [
        new fx.FadeableLight(me, ditchLightsFadeS, "DitchLight_L"),
        new fx.FadeableLight(me, ditchLightsFadeS, "DitchLight_R"),
    ];
    const areHeadLightsOn = () => {
        const cv = me.rv.GetControlValue("Headlights") as number;
        return cv > 0.5 && cv < 1.5;
    };
    const areDitchLightsOn = frp.liftN(
        (headLights, crossingLight) => headLights && crossingLight,
        areHeadLightsOn,
        () => (me.rv.GetControlValue("CrossingLight") as number) > 0.5
    );
    const hornSequencer$ = frp.compose(me.createPlayerWithKeyUpdateStream(), me.mapGetCvStream("CylinderCock"));
    const ditchLightsHornTimeS$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("Horn"),
        frp.merge(hornSequencer$),
        frp.filter(v => v === 1),
        frp.map(_ => me.e.GetSimulationTime())
    );
    const ditchLightsFlash = frp.liftN(
        (ditchOn, bell, hornTimeS) =>
            isAmtrak && ditchOn && (bell || (hornTimeS !== undefined && me.e.GetSimulationTime() - hornTimeS <= 30)),
        areDitchLightsOn,
        () => (me.rv.GetControlValue("Bell") as number) > 0.5,
        frp.stepper(ditchLightsHornTimeS$, undefined)
    );
    const ditchLightsPlayer$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        fx.behaviorStopwatchS(ditchLightsFlash),
        frp.map((stopwatchS): [boolean, boolean] => {
            if (stopwatchS === undefined) {
                const ditchOn = frp.snapshot(areDitchLightsOn);
                return [ditchOn, ditchOn];
            } else {
                const flashLeft = stopwatchS % (ditchLightFlashS * 2) < ditchLightFlashS;
                return [flashLeft, !flashLeft];
            }
        })
    );
    const ditchLightsAi$ = frp.compose(
        me.createAiUpdateStream(),
        frp.map((au): [boolean, boolean] => {
            const ditchOn = au.direction === SensedDirection.Forward;
            return [ditchOn, ditchOn];
        })
    );
    const ditchLights$ = frp.compose(
        me.createPlayerWithoutKeyUpdateStream(),
        frp.map((_): [boolean, boolean] => [false, false]),
        frp.merge(ditchLightsPlayer$),
        frp.merge(ditchLightsAi$)
    );
    ditchLights$(([l, r]) => {
        const [left, right] = ditchLights;
        left.setOnOff(l);
        right.setOnOff(r);
    });
    const ditchNodeLeft$ = frp.compose(
        me.createUpdateStream(),
        frp.map(_ => {
            const [light] = ditchLights;
            return light.getIntensity() > 0.5;
        }),
        rejectRepeats()
    );
    const ditchNodeRight$ = frp.compose(
        me.createUpdateStream(),
        frp.map(_ => {
            const [, light] = ditchLights;
            return light.getIntensity() > 0.5;
        }),
        rejectRepeats()
    );
    ditchNodeLeft$(on => {
        me.rv.ActivateNode("ditch_left", on);
    });
    ditchNodeRight$(on => {
        me.rv.ActivateNode("ditch_right", on);
    });

    // Horn rings the bell.
    const bellControl$ = frp.compose(
        me.createOnCvChangeStreamFor("Horn"),
        frp.merge(me.createOnCvChangeStreamFor("CylinderCock")),
        frp.filter(v => v === 1),
        me.mapAutoBellStream()
    );
    bellControl$(v => {
        me.rv.SetControlValue("Bell", v);
    });

    // Diesel exhaust effect
    const exhaust = new rw.Emitter("DieselExhaust");
    const exhaustState = frp.liftN(
        (modePosition, rpm, effort): [color: number, rate: number] => {
            // DTG's exhaust logic
            if (modePosition < 0.5) {
                return [0, 0];
            } else if (rpm < 180) {
                return [0, 0];
            } else if (effort < 0.1) {
                return [0.25, 0.01];
            } else if (effort < 0.5) {
                return [0.1, 0.005];
            } else {
                return [0, 0.001];
            }
        },
        modePosition,
        () => me.rv.GetControlValue("RPM") as number,
        () => me.eng.GetTractiveEffort()
    );
    const exhaustActive$ = frp.compose(
        me.createUpdateStream(),
        mapBehavior(exhaustState),
        frp.map(([, rate]) => rate > 0),
        rejectRepeats()
    );
    const exhaustColor$ = frp.compose(
        me.createUpdateStream(),
        mapBehavior(exhaustState),
        frp.map(([color]) => color),
        rejectRepeats()
    );
    const exhaustRate$ = frp.compose(
        me.createUpdateStream(),
        mapBehavior(exhaustState),
        frp.map(([, rate]) => rate),
        rejectRepeats()
    );
    exhaustActive$(active => {
        exhaust.SetEmitterActive(active);
    });
    exhaustColor$(color => {
        exhaust.SetEmitterColour(color, color, color);
    });
    exhaustRate$(rate => {
        exhaust.SetEmitterRate(rate);
    });

    // Speedometer
    const aSpeedoMph$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(me.createSpeedometerMpsBehavior()),
        frp.map(mps => mps * c.mps.toMph),
        frp.map(mph => Math.abs(mph))
    );
    aSpeedoMph$(mph => {
        const [[h, t, u]] = m.digits(Math.floor(mph), 3);
        me.rv.SetControlValue("SpeedoHundreds", h);
        me.rv.SetControlValue("SpeedoTens", t);
        me.rv.SetControlValue("SpeedoUnits", u);
        me.rv.SetControlValue("SpeedoDecimal", m.tenths(mph));
    });

    // Cockpit lights
    // Engineer's side task light
    createTaskLight(me, "CabLight_R", "CabLight");
    // Engineer's forward task light
    createTaskLight(me, "TaskLight_R", "CabLight1");
    // Secondman's forward task light
    createTaskLight(me, "TaskLight_L", "CabLight2");
    // Secondman's side task light
    createTaskLight(me, "CabLight_L", "CabLight4");
    // Dome light
    createTaskLight(me, "CabLight_M", "CabLight5");

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
    fx.setLowPlatformDoorsForEngine(me, true);

    // Enable updates.
    me.e.BeginUpdate();
}

function createTaskLight(e: FrpEngine, light: string, cv: string) {
    const fadeableLight = new fx.FadeableLight(e, taskLightFadeS, light);
    const stream$ = frp.compose(
        e.createPlayerWithKeyUpdateStream(),
        e.mapGetCvStream(cv),
        frp.map(v => v > 0.5)
    );
    stream$(on => {
        fadeableLight.setOnOff(on);
    });
}
