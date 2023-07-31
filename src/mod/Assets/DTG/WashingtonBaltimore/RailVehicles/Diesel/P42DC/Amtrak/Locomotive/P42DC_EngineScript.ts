/**
 * Amtrak GE P42DC
 */

import * as ale from "lib/alerter";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { mapBehavior, rejectRepeats } from "lib/frp-extra";
import { AduAspect } from "lib/nec/adu";
import * as cs from "lib/nec/cabsignals";
import * as adu from "lib/nec/twospeed-adu";
import * as m from "lib/math";
import * as rw from "lib/railworks";
import * as fx from "lib/special-fx";
import * as ui from "lib/ui";
import { SensedDirection } from "lib/frp-vehicle";

const ditchLightsFadeS = 0.3;
const ditchLightFlashS = 0.65;
const taskLightFadeS = 0.8 / 2;

const me = new FrpEngine(() => {
    // Safety systems cut in/out
    const atcCutIn = () => (me.rv.GetControlValue("Window Left", 0) as number) < 0.9;
    const acsesCutIn = () => (me.rv.GetControlValue("Window Right", 0) as number) < 0.9;
    ui.createAtcStatusPopup(me, atcCutIn);
    ui.createAcsesStatusPopup(me, acsesCutIn);
    const alerterCutIn = frp.liftN((atcCutIn, acsesCutIn) => atcCutIn || acsesCutIn, atcCutIn, acsesCutIn);

    // Safety systems and ADU
    const acknowledge = me.createAcknowledgeBehavior();
    const suppression = () => (me.rv.GetControlValue("TrainBrakeControl", 0) as number) >= 0.4;
    const [aduState$, aduEvents$] = adu.create(
        cs.fourAspectAtc,
        me,
        acknowledge,
        suppression,
        atcCutIn,
        acsesCutIn,
        110 * c.mph.toMps
    );
    const aduStateHub$ = frp.compose(aduState$, frp.hub());
    aduStateHub$(state => {
        me.rv.SetControlValue("ADU00", 0, state.aspect === cs.FourAspect.Clear ? 1 : 0);
        me.rv.SetControlValue("ADU01", 0, state.aspect === cs.FourAspect.ApproachLimited ? 1 : 0);
        me.rv.SetControlValue("ADU02", 0, state.aspect === cs.FourAspect.ApproachLimited ? 1 : 0);
        me.rv.SetControlValue("ADU03", 0, state.aspect === cs.FourAspect.Approach ? 1 : 0);
        me.rv.SetControlValue(
            "ADU04",
            0,
            state.aspect === cs.FourAspect.Restricting || state.aspect === AduAspect.Stop ? 1 : 0
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
        frp.filter(([name]) => name === "ThrottleAndBrake" || name === "TrainBrakeControl")
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
    const upgradeSound$ = frp.compose(me.createPlayerWithKeyUpdateStream(), fx.triggerSound(0.25, upgradeEvents$));
    const isAlarm$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                (aduState, alerterState, upgradeSound) =>
                    aduState?.atcAlarm || aduState?.acsesAlarm || alerterState?.alarm || upgradeSound,
                aduState,
                alerterState,
                frp.stepper(upgradeSound$, false)
            )
        )
    );
    isAlarm$(on => {
        me.rv.SetControlValue("AlerterAudible", 0, on ? 1 : 0);
    });

    // Throttle, dynamic brake, and air brake controls
    const isPenaltyBrake = frp.liftN(
        (aduState, alerterState) => (aduState?.penaltyBrake || alerterState?.penaltyBrake) ?? false,
        aduState,
        alerterState
    );
    // There's no virtual throttle, so just move the power handle.
    const setCombinedPower$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.filter(_ => frp.snapshot(isPenaltyBrake)),
        frp.map(_ => 0.5)
    );
    setCombinedPower$(v => {
        me.rv.SetControlValue("ThrottleAndBrake", 0, v);
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
    // Dynamic brake lockout
    const combinedPower = () => me.rv.GetControlValue("ThrottleAndBrake", 0) as number;
    const setupNotch = 0.444444;
    const dynamicLockout$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        fx.behaviorStopwatchS(frp.liftN(cp => cp < 0.5, combinedPower)),
        frp.map(brakingS => frp.snapshot(combinedPower) < setupNotch && brakingS !== undefined && brakingS < 7)
    );
    dynamicLockout$(lock => {
        if (lock) {
            me.rv.SetControlValue("ThrottleAndBrake", 0, setupNotch);
        }
        me.rv.SetControlValue("Buzzer", 0, lock ? 1 : 0);
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
            ditchOn && (bell || (hornTimeS !== undefined && me.e.GetSimulationTime() - hornTimeS <= 30)),
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
        (rpm, effort): [color: number, rate: number] => {
            // DTG's exhaust logic
            if (rpm < 180) {
                return [0, 0];
            } else if (effort < 0.1) {
                return [0.25, 0.01];
            } else if (effort < 0.5) {
                return [0.1, 0.005];
            } else {
                return [0, 0.001];
            }
        },
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
    createTaskLight(me, "CabLight_R", ["CabLight3", 0]);
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

    // Enable updates.
    me.e.BeginUpdate();

    // Set engine number.
    const [[lh, lt, lu]] = m.digits(tonumber(me.rv.GetRVNumber()) ?? 0, 3);
    me.rv.SetControlValue("LocoHundreds", 0, lh);
    me.rv.SetControlValue("LocoTens", 0, lt);
    me.rv.SetControlValue("LocoUnits", 0, lu);
});
me.setup();

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
