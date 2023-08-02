/**
 * Metro-North/Amtrak GE P32AC-DM
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

const dualModeSwitchS = 20;
const ditchLightsFadeS = 0.3;
const ditchLightFlashS = 0.65;
const taskLightFadeS = 0.8 / 2;

export function onInit(me: FrpEngine, isAmtrak: boolean) {
    // Dual-mode power supply
    const electrification = ps.createElectrificationBehaviorWithControlValues(me, {
        [ps.Electrification.Overhead]: ["PowerOverhead", 0],
        [ps.Electrification.ThirdRail]: ["Power3rdRail", 0],
    });
    const modeSelect = () => {
        const cv = Math.round(me.rv.GetControlValue("PowerMode", 0) as number);
        // The power mode control is reversed in the Shoreliner cab car, so
        // compensate for this (while sacrificing P32-to-P32 MU capability).
        if (me.rv.GetIsPlayer() && !me.eng.GetIsEngineWithKey()) {
            return cv < 0.5 ? ps.EngineMode.Diesel : ps.EngineMode.ThirdRail;
        } else {
            return cv < 0.5 ? ps.EngineMode.ThirdRail : ps.EngineMode.Diesel;
        }
    };
    const modeAuto = () => (me.rv.GetControlValue("ExpertPowerMode", 0) as number) > 0.5;
    ui.createAutoPowerStatusPopup(me, modeAuto);
    const [modePosition$, modeSwitch$] = ps.createDualModeEngineStream(
        me,
        ps.EngineMode.ThirdRail,
        ps.EngineMode.Diesel,
        modeSelect,
        modeAuto,
        () => {
            // VirtualThrottle is the more correct control here, but it's
            // not applied within the consist.
            const throttle = me.rv.GetControlValue(
                me.eng.GetIsEngineWithKey() ? "VirtualThrottle" : "Regulator",
                0
            ) as number;
            return throttle < 0.5;
        },
        dualModeSwitchS,
        false,
        ["MaximumSpeedLimit", 0]
    );
    modeSwitch$(mode => {
        if (mode === ps.EngineMode.ThirdRail) {
            me.rv.SetControlValue("PowerMode", 0, 0);
        } else if (mode === ps.EngineMode.Diesel) {
            me.rv.SetControlValue("PowerMode", 0, 1);
        }
    });
    const modePosition = frp.stepper(modePosition$, 0);
    const isPowerAvailable = frp.liftN(
        position => ps.dualModeEngineHasPower(position, ps.EngineMode.ThirdRail, ps.EngineMode.Diesel, electrification),
        modePosition
    );
    const setPlayerPower$ = frp.compose(me.createPlayerUpdateStream(), mapBehavior(isPowerAvailable));
    setPlayerPower$(power => {
        // Unlike the virtual throttle, this works for helper engines.
        me.eng.SetPowerProportion(-1, power ? 1 : 0);
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
    const acsesCutIn = () => (me.rv.GetControlValue("ACSESCutIn", 0) as number) > 0.5;
    ui.createAtcStatusPopup(me, atcCutIn);
    ui.createAcsesStatusPopup(me, acsesCutIn);
    const alerterCutIn = frp.liftN((atcCutIn, acsesCutIn) => atcCutIn || acsesCutIn, atcCutIn, acsesCutIn);

    // Safety systems and ADU
    const acknowledge = me.createAcknowledgeBehavior();
    const suppression = () => (me.rv.GetControlValue("TrainBrakeControl", 0) as number) >= 0.4;
    const [aduState$, aduEvents$] = adu.create(
        isAmtrak ? cs.fourAspectAtc : cs.metroNorthAtc,
        me,
        acknowledge,
        suppression,
        atcCutIn,
        acsesCutIn,
        (isAmtrak ? 110 : 80) * c.mph.toMps,
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

        me.rv.SetControlValue(
            "SignalSpeed",
            0,
            {
                [AduAspect.Stop]: 0,
                [cs.FourAspect.Restricting]: 15,
                [cs.FourAspect.Approach]: 30,
                [cs.FourAspect.ApproachLimited]: 45,
                [cs.FourAspect.Clear]: -1,
            }[state.aspect]
        );

        if (state.trackSpeedMph !== undefined) {
            const [[h, t, u]] = m.digits(state.trackSpeedMph, 3);
            me.rv.SetControlValue("TrackHundreds", 0, h);
            me.rv.SetControlValue("TrackTens", 0, t);
            me.rv.SetControlValue("TrackUnits", 0, u);
        } else {
            me.rv.SetControlValue("TrackHundreds", 0, -1);
            me.rv.SetControlValue("TrackTens", 0, -1);
            me.rv.SetControlValue("TrackUnits", 0, -1);
        }
    });
    const aduState = frp.stepper(aduStateHub$, undefined);
    // Alerter
    const alerterReset$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.filter(([name]) => name === "VirtualThrottle" || name === "TrainBrakeControl")
    );
    const alerter$ = frp.compose(ale.create(me, acknowledge, alerterReset$, alerterCutIn), frp.hub());
    const alerterState = frp.stepper(alerter$, undefined);
    alerter$(state => {
        me.rv.SetControlValue("AlerterVisual", 0, state.alarm ? 1 : 0);
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
    alarmsUpdate$(cvs => {
        me.rv.SetControlValue("AWS", 0, cvs.aws ? 1 : 0);
        me.rv.SetControlValue("AWSWarnCount", 0, cvs.awsWarnCount ? 1 : 0);
    });

    // Throttle, dynamic brake, and air brake controls
    const isPenaltyBrake = frp.liftN(
        (aduState, alerterState) => (aduState?.penaltyBrake || alerterState?.penaltyBrake) ?? false,
        aduState,
        alerterState
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
    const fullService = 0.85;
    const setPenaltyBrake$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.filter(_ => frp.snapshot(isPenaltyBrake)),
        frp.map(_ => fullService)
    );
    setPenaltyBrake$(v => {
        me.rv.SetControlValue("TrainBrakeControl", 0, v);
    });
    // DTG's "blended braking" algorithm
    const dynamicBrake = frp.liftN(
        (modePosition, brakePipePsi) => {
            const isDiesel = modePosition === 1;
            return isDiesel ? (70 - brakePipePsi) * 0.01428 : 0;
        },
        modePosition,
        () => me.rv.GetControlValue("AirBrakePipePressurePSI", 0) as number
    );
    const dynamicBrake$ = frp.compose(me.createPlayerWithKeyUpdateStream(), mapBehavior(dynamicBrake));
    dynamicBrake$(v => {
        me.rv.SetControlValue("DynamicBrake", 0, v);
    });

    // Ditch lights
    const ditchLights = [
        new fx.FadeableLight(me, ditchLightsFadeS, "DitchLight_L"),
        new fx.FadeableLight(me, ditchLightsFadeS, "DitchLight_R"),
    ];
    const areHeadLightsOn = () => {
        const cv = me.rv.GetControlValue("Headlights", 0) as number;
        return cv > 0.5 && cv < 1.5;
    };
    const areDitchLightsOn = frp.liftN(
        (headLights, crossingLight) => headLights && crossingLight,
        areHeadLightsOn,
        () => (me.rv.GetControlValue("CrossingLight", 0) as number) > 0.5
    );
    const hornSequencer$ = frp.compose(me.createPlayerWithKeyUpdateStream(), me.mapGetCvStream("CylinderCock", 0));
    const ditchLightsHornTimeS$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("Horn", 0),
        frp.merge(hornSequencer$),
        frp.filter(v => v === 1),
        frp.map(_ => me.e.GetSimulationTime())
    );
    const ditchLightsFlash = frp.liftN(
        (ditchOn, bell, hornTimeS) =>
            isAmtrak && ditchOn && (bell || (hornTimeS !== undefined && me.e.GetSimulationTime() - hornTimeS <= 30)),
        areDitchLightsOn,
        () => (me.rv.GetControlValue("Bell", 0) as number) > 0.5,
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
        me.createOnCvChangeStreamFor("Horn", 0),
        frp.merge(me.createOnCvChangeStreamFor("CylinderCock", 0)),
        frp.filter(v => v === 1),
        me.mapAutoBellStream()
    );
    bellControl$(v => {
        me.rv.SetControlValue("Bell", 0, v);
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
        () => me.rv.GetControlValue("RPM", 0) as number,
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
        me.mapGetCvStream("SpeedometerMPH", 0),
        frp.map(mph => Math.abs(mph))
    );
    aSpeedoMph$(mph => {
        const [[h, t, u]] = m.digits(mph, 3);
        me.rv.SetControlValue("SpeedoHundreds", 0, h);
        me.rv.SetControlValue("SpeedoTens", 0, t);
        me.rv.SetControlValue("SpeedoUnits", 0, u);
        me.rv.SetControlValue("SpeedoDecimal", 0, m.tenths(mph));
    });

    // Cockpit lights
    // Engineer's side task light
    createTaskLight(me, "CabLight_R", ["CabLight", 0]);
    // Engineer's forward task light
    createTaskLight(me, "TaskLight_R", ["CabLight1", 0]);
    // Secondman's forward task light
    createTaskLight(me, "TaskLight_L", ["CabLight2", 0]);
    // Secondman's side task light
    createTaskLight(me, "CabLight_L", ["CabLight4", 0]);
    // Dome light
    createTaskLight(me, "CabLight_M", ["CabLight5", 0]);

    // Process OnControlValueChange events.
    const onCvChange$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.reject(([name]) => name === "Bell")
    );
    onCvChange$(([name, index, value]) => {
        me.rv.SetControlValue(name, index, value);
    });

    // Set consist brake lights.
    fx.createBrakeLightStreamForEngine(me);

    // Set platform door height.
    fx.setLowPlatformDoorsForEngine(me, true);

    // Enable updates.
    me.e.BeginUpdate();
}

function createTaskLight(e: FrpEngine, light: string, cv: [name: string, index: number]) {
    const fadeableLight = new fx.FadeableLight(e, taskLightFadeS, light);
    const stream$ = frp.compose(
        e.createPlayerWithKeyUpdateStream(),
        e.mapGetCvStream(...cv),
        frp.map(v => v > 0.5)
    );
    stream$(on => {
        fadeableLight.setOnOff(on);
    });
}
