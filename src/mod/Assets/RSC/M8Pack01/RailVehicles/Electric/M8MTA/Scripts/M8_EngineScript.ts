/**
 * Metro-North Kawasaki M8
 */

import * as ale from "lib/alerter";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import * as xt from "lib/frp-extra";
import * as vh from "lib/frp-vehicle";
import * as m from "lib/math";
import { AduAspect } from "lib/nec/adu";
import * as cs from "lib/nec/cabsignals";
import * as adu from "lib/nec/twospeed-adu";
import * as ps from "lib/power-supply";
import * as rw from "lib/railworks";
import * as fx from "lib/special-fx";
import * as ui from "lib/ui";

enum ConsistMessageId {
    MotorSounds = 10200,
    ConsistStatus = 10201,
}

type MotorSounds = [lowPitch: number, highPitch: number, volume: number, compressor?: number];

const dualModeOrder: [ps.EngineMode.Overhead, ps.EngineMode.ThirdRail] = [
    ps.EngineMode.Overhead,
    ps.EngineMode.ThirdRail,
];
const dualModeSwitchS = 10;
// Try to limit the performance impact of consist messages.
const consistUpdateS = 0.25;

const me = new FrpEngine(() => {
    const isFanRailer = me.rv.GetTotalMass() === 65.7;

    // Dual mode power supply
    const rvPowerMode = me.rv.GetRVNumber()[0] === "T" ? ps.EngineMode.ThirdRail : ps.EngineMode.Overhead;
    const electrification = ps.createElectrificationBehaviorWithControlValues(me, {
        [ps.Electrification.Overhead]: "PowerOverhead",
        [ps.Electrification.ThirdRail]: "Power3rdRail",
    });
    // These control values aren't set properly in the engine blueprints. We'll
    // fix them, but only for the first time--not when resuming from a save.
    const firstSettledUpdate$ = frp.compose(me.createFirstUpdateAfterControlsSettledStream(), frp.hub());
    const fixPowerValues$ = frp.compose(
        firstSettledUpdate$,
        frp.filter(resumeFromSave => !resumeFromSave)
    );
    fixPowerValues$(_ => {
        me.rv.SetControlValue(rvPowerMode === ps.EngineMode.ThirdRail ? "Power3rdRail" : "PowerOverhead", 1);
        // We need to wait until controls are settled to set this CV, otherwise
        // it will slew.
        me.rv.SetControlValue("Panto", rvPowerMode === ps.EngineMode.ThirdRail ? 2 : 1);
    });
    const modeSelectPlayer = frp.liftN(
        (firstUpdate, cv) => {
            if (firstUpdate === undefined) {
                // Avoid any potential timing issues.
                return rvPowerMode;
            } else {
                return cv < 1.5 ? ps.EngineMode.Overhead : ps.EngineMode.ThirdRail;
            }
        },
        frp.stepper(firstSettledUpdate$, undefined),
        () => me.rv.GetControlValue("Panto") as number
    );
    const modePosition = ps.createDualModeEngineBehavior({
        e: me,
        modes: dualModeOrder,
        getPlayerMode: modeSelectPlayer,
        getAiMode: rvPowerMode,
        getPlayerCanSwitch: () => me.rv.GetControlValue("Regulator") === 0,
        transitionS: dualModeSwitchS,
        instantSwitch: xt.nullStream,
        positionFromSaveOrConsist: () => (me.rv.GetControlValue("PowerStart") as number) - 1,
    });
    const setModePosition$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        xt.mapBehavior(modePosition),
        xt.rejectRepeats()
    );
    setModePosition$(position => {
        me.rv.SetControlValue("PowerStart", position + 1);
    });
    const energyOn = () => (me.rv.GetControlValue("PantographControl") as number) > 0.5;
    const pantoUp = () => {
        const cv = me.rv.GetControlValue("Panto") as number;
        return cv > 0.5 && cv < 1.5;
    };
    const isPowerAvailable = frp.liftN(
        (position, energyOn, pantoUp) => {
            const isPowerReady = ps.dualModeEngineHasPower(
                position,
                ps.EngineMode.Overhead,
                ps.EngineMode.ThirdRail,
                electrification
            );
            return isPowerReady && energyOn && (position === 0 ? pantoUp : true);
        },
        modePosition,
        energyOn,
        pantoUp
    );

    // Pantograph animation and spark
    const pantoAnim = new fx.Animation(me, "panto", 2);
    const pantoUp$ = frp.compose(
        me.createPlayerUpdateStream(),
        xt.mapBehavior(pantoUp),
        frp.merge(
            frp.compose(
                me.createAiUpdateStream(),
                frp.map(au => au.direction !== vh.SensedDirection.None),
                frp.map(moving => moving && rvPowerMode === ps.EngineMode.Overhead)
            )
        )
    );
    pantoUp$(up => {
        pantoAnim.setTargetPosition(up ? 1 : 0);
    });
    const sparkLight = new rw.Light("Spark");
    const pantoSpark$ = frp.compose(
        fx.createPantographSparkStream(me, electrification),
        frp.map(spark => spark && frp.snapshot(energyOn)),
        frp.map(spark => spark && pantoAnim.getPosition() >= 1)
    );
    pantoSpark$(spark => {
        me.rv.ActivateNode("panto_spark", spark);
        sparkLight.Activate(spark);
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
    const suppression = () => (me.rv.GetControlValue("ThrottleAndBrake") as number) <= -0.4;
    const [aduState$, aduEvents$] = adu.create({
        atc: cs.metroNorthAtc,
        e: me,
        acknowledge,
        suppression,
        atcCutIn,
        acsesCutIn,
        equipmentSpeedMps: 80 * c.mph.toMps,
        pulseCodeControlValue: "SignalSpeedLimit",
    });
    const aduStateHub$ = frp.compose(aduState$, frp.hub());
    aduStateHub$(({ aspect, trackSpeedMph }) => {
        me.rv.SetControlValue("SigN", aspect === cs.FourAspect.Clear ? 1 : 0);
        me.rv.SetControlValue("SigL", aspect === cs.FourAspect.ApproachLimited ? 1 : 0);
        me.rv.SetControlValue("SigM", aspect === cs.FourAspect.Approach ? 1 : 0);
        me.rv.SetControlValue("SigR", aspect === cs.FourAspect.Restricting ? 1 : 0);
        me.rv.SetControlValue("SigS", aspect === AduAspect.Stop ? 1 : 0);

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
            me.rv.SetControlValue("TrackSpeedHundreds", h);
            me.rv.SetControlValue("TrackSpeedTens", t);
            me.rv.SetControlValue("TrackSpeedUnits", u);
        } else {
            me.rv.SetControlValue("TrackSpeedHundreds", -1);
            me.rv.SetControlValue("TrackSpeedTens", -1);
            me.rv.SetControlValue("TrackSpeedUnits", -1);
        }
    });
    const aduState = frp.stepper(aduStateHub$, undefined);
    // Alerter
    const alerterReset$ = me.createOnCvChangeStreamFor("ThrottleAndBrake");
    const alerter$ = frp.compose(
        ale.create({ e: me, acknowledge, acknowledgeStream: alerterReset$, cutIn: alerterCutIn }),
        frp.hub()
    );
    const alerterState = frp.stepper(alerter$, undefined);
    // Safety system sounds
    // Unfortunately, we cannot display the AWS symbol without also playing the
    // fast beep-beep sound, which we use for the alerter.
    const safetyAlarm$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        fx.loopSound(
            0.5,
            frp.liftN(aduState => (aduState?.atcAlarm || aduState?.acsesAlarm) ?? false, aduState)
        )
    );
    safetyAlarm$(play => {
        me.rv.SetControlValue("SpeedReductionAlert", play ? 1 : 0);
    });
    const alerterAlarm$ = frp.compose(
        alerter$,
        frp.map(({ alarm }) => alarm)
    );
    alerterAlarm$(play => {
        me.rv.SetControlValue("AWS", play ? 1 : 0);
    });
    const upgradeEvents$ = frp.compose(
        aduEvents$,
        frp.filter(evt => evt === adu.AduEvent.Upgrade)
    );
    const upgradeSound$ = frp.compose(me.createPlayerWithKeyUpdateStream(), fx.triggerSound(1, upgradeEvents$));
    upgradeSound$(play => {
        me.rv.SetControlValue("SpeedIncreaseAlert", play ? 1 : 0);
    });

    // Throttle, dynamic brake, and air brake controls
    const isPenaltyBrake = frp.liftN(
        (aduState, alerterState) => (aduState?.penaltyBrake || alerterState?.penaltyBrake) ?? false,
        aduState,
        alerterState
    );
    const combinedPower = () => me.rv.GetControlValue("ThrottleAndBrake") as number;
    const throttle = frp.liftN(
        (isPenaltyBrake, isPowerAvailable, input) => (isPenaltyBrake || !isPowerAvailable ? 0 : Math.max(input, 0)),
        isPenaltyBrake,
        isPowerAvailable,
        combinedPower
    );
    const throttle$ = frp.compose(me.createPlayerWithKeyUpdateStream(), xt.mapBehavior(throttle));
    throttle$(v => {
        me.rv.SetControlValue("Regulator", v);
    });
    const brake = frp.liftN(
        (isPenaltyBrake, input, fullService) => (isPenaltyBrake ? fullService : Math.max(-input, 0)),
        isPenaltyBrake,
        combinedPower,
        0.85
    );
    const blendedBrakes$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        xt.mapBehavior(brake),
        frp.map(isFanRailer ? fanRailerBlendedBraking : vanillaBlendedBraking)
    );
    blendedBrakes$(([air, dynamic]) => {
        me.rv.SetControlValue("TrainBrakeControl", air);
        me.rv.SetControlValue("DynamicBrake", dynamic);
    });

    // Blueprintless notches for the master controller
    me.slewControlValue("ThrottleAndBrake", v => {
        const coast = 0.0667;
        const minimum = 0.2;
        if (v > coast && v < minimum) {
            return minimum; // Min power
        } else if (v > -coast && v < coast) {
            return 0;
        } else if (v > -minimum && v < -coast) {
            return -minimum; // Min brake
        } else if (v > -0.99 && v < -0.9) {
            return -0.9; // Max brake
        } else if (v < -0.99) {
            return -1; // Emergency
        } else {
            return v;
        }
    });

    // Motor sounds
    const motorSoundsPlayerSend$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.fold(
            (last, pu): MotorSounds => {
                // Player motor sound algorithm by DTG
                const [, lastHighPitch, lastVolume] = last;
                const aSpeedMph = Math.abs(pu.speedMps) * c.mps.toMph;
                const power = me.rv.GetControlValue("Regulator") as number;
                const brake = me.rv.GetControlValue("TrainBrakeControl") as number;
                const compressor = me.rv.GetControlValue("CompressorState") as number;

                const [speedCurveMult, lowPitchSpeedCurveMult] = [0.07, 0.05];
                const [acOffset, acSpeedMax] = [-0.3, 0.75];
                const [dcOffset, dcSpeedMax] = [0.1, 1];
                const [dcSpeedCurveUpPitch, dcSpeedCurveUpMult] = [0.6, 0.4];
                const [volumeIncDecMax, pitchIncDecMax] = [4, 1];
                const acDcSpeedMin = 0.23;

                const v1 = Math.min(1, power * 3);
                const v2 = Math.max(v1, Math.max(0, Math.min(1, aSpeedMph * 3 - 4.02336)) * Math.min(1, brake * 5));

                const lowPitch = aSpeedMph * lowPitchSpeedCurveMult;
                let hp2: number;
                if (frp.snapshot(modePosition) < 0.5) {
                    const hp1 = aSpeedMph * speedCurveMult * v2 + acOffset;
                    hp2 = Math.min(hp1, acSpeedMax);
                } else {
                    const hp1 = speedCurveMult * aSpeedMph * v2 + dcOffset;
                    hp2 =
                        hp1 > dcSpeedCurveUpPitch && v1 === v2
                            ? hp1 + (hp1 - dcSpeedCurveUpPitch) * dcSpeedCurveUpMult
                            : hp1;
                }
                const highPitch = clampDelta(lastHighPitch, Math.min(hp2, dcSpeedMax), pitchIncDecMax * pu.dt);

                const vol1 = highPitch > acDcSpeedMin + 0.01 ? 1 : v2;
                const volume = clampDelta(lastVolume, vol1, volumeIncDecMax * pu.dt);

                return [lowPitch, highPitch, volume, compressor];
            },
            [0, 0, 0, 0] as MotorSounds
        ),
        frp.hub()
    );
    motorSoundsPlayerSend$(sound => {
        const msg = sound.map(v => `${Math.round((v ?? 0) * 1e3)}`).join(":");
        me.rv.SendConsistMessage(ConsistMessageId.MotorSounds, msg, rw.ConsistDirection.Forward);
        me.rv.SendConsistMessage(ConsistMessageId.MotorSounds, msg, rw.ConsistDirection.Backward);
    });
    const motorSoundsPlayer$ = frp.compose(
        motorSoundsPlayerSend$,
        frp.map((sound): MotorSounds => {
            const [lowPitch, highPitch, volume] = sound;
            return [lowPitch, highPitch, volume, undefined];
        })
    );
    const motorSoundsHelperReceive$ = frp.compose(
        me.createOnConsistMessageStream(),
        frp.filter(([id]) => id === ConsistMessageId.MotorSounds)
    );
    motorSoundsHelperReceive$(msg => {
        me.rv.SendConsistMessage(...msg);
    });
    const motorSoundsHelper$ = frp.compose(
        motorSoundsHelperReceive$,
        frp.map(([, msg]) => msg.split(":").map(s => tonumber(s) ?? 0) as MotorSounds)
    );
    const motorSounds$ = frp.compose(
        me.createAiUpdateStream(),
        frp.map((au): MotorSounds => {
            // AI motor sound algorithm by DTG
            const speedCurveMult = 0.07;
            const aSpeedMph = Math.abs(au.speedMps) * c.mps.toMph;
            const aAccelMps2 = Math.abs(me.rv.GetAcceleration());

            const lowPitch = aSpeedMph;
            const highPitch = aSpeedMph * speedCurveMult;
            const volume = Math.min(aAccelMps2 * 5, 1);
            const compressor = 0;
            return [lowPitch, highPitch, volume, compressor];
        }),
        frp.merge(motorSoundsPlayer$),
        frp.merge(motorSoundsHelper$)
    );
    const motorLowPitch$ = frp.compose(
        motorSounds$,
        frp.map(([lowPitch]) => lowPitch),
        xt.rejectRepeats()
    );
    const motorHighPitch$ = frp.compose(
        motorSounds$,
        frp.map(([, highPitch]) => highPitch),
        xt.rejectRepeats()
    );
    const motorVolume$ = frp.compose(
        motorSounds$,
        frp.map(([, , volume]) => volume),
        xt.rejectRepeats()
    );
    const motorCompressor$ = frp.compose(
        motorSounds$,
        frp.map(([, , , compressor]) => compressor),
        xt.rejectRepeats(),
        xt.rejectUndefined()
    );
    motorLowPitch$(v => {
        me.rv.SetControlValue("MotorLowPitch", v);
    });
    motorHighPitch$(v => {
        me.rv.SetControlValue("MotorHighPitch", v);
    });
    motorVolume$(v => {
        me.rv.SetControlValue("MotorVolume", v);
    });
    motorCompressor$(v => {
        me.rv.SetControlValue("CompressorState", v);
    });
    me.rv.SetControlValue("FanSound", 1);

    // Consist display
    const consistStatusSend$ = frp.compose(
        me.createPlayerWithoutKeyUpdateStream(),
        frp.throttle(consistUpdateS),
        frp.filter(pu => {
            const [frontCoupled] = pu.couplings;
            return !frontCoupled;
        })
    );
    consistStatusSend$(pu => {
        const msg = `${consistMotorStatus()}:${consistDoorStatus(pu)}`;
        me.rv.SendConsistMessage(ConsistMessageId.ConsistStatus, msg, rw.ConsistDirection.Backward);
    });
    const consistStatusForward$ = frp.compose(
        me.createOnConsistMessageStream(),
        frp.filter(([id]) => id === ConsistMessageId.ConsistStatus)
    );
    consistStatusForward$(([, prev, dir]) => {
        const msg = `${consistMotorStatus()}:${consistDoorStatus()}`;
        me.rv.SendConsistMessage(ConsistMessageId.ConsistStatus, `${msg};${prev}`, dir);
    });
    const consistStatusReceive$ = frp.compose(
        me.createOnConsistMessageStream(),
        frp.filter(([id]) => id === ConsistMessageId.ConsistStatus),
        frp.map(([, msg]) => msg)
    );
    const consistStatusDisplay$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        // Prevent the last car from flickering.
        frp.filter(_ => frp.snapshot(me.areControlsSettled)),
        xt.mapBehavior(frp.stepper(consistStatusReceive$, undefined))
    );
    consistStatusDisplay$(status => {
        const behind = status?.split(";") ?? [];
        me.rv.SetControlValue("Cars", behind.length);
        for (let i = 0; i < behind.length; i++) {
            const [motor, doors] = behind[i].split(":").map(s => tonumber(s) ?? 0);
            me.rv.SetControlValue(`Motor_${i + 2}`, motor);
            me.rv.SetControlValue(`Doors_${i + 2}`, doors);
        }
    });

    // Driving display
    const speedoMphDigits$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        xt.mapBehavior(me.createSpeedometerDigitsMphBehavior(3))
    );
    speedoMphDigits$(([[h, t, u]]) => {
        me.rv.SetControlValue("SpeedoHundreds", h);
        me.rv.SetControlValue("SpeedoTens", t);
        me.rv.SetControlValue("SpeedoUnits", u);
    });
    const brakePipePsiDigits$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("AirBrakePipePressurePSI"),
        threeDigitDisplay
    );
    brakePipePsiDigits$(([[h, t, u]]) => {
        me.rv.SetControlValue("PipeHundreds", h);
        me.rv.SetControlValue("PipeTens", t);
        me.rv.SetControlValue("PipeUnits", u);
    });
    const brakeCylinderPsiDigits$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("TrainBrakeCylinderPressurePSI"),
        threeDigitDisplay
    );
    brakeCylinderPsiDigits$(([[h, t, u]]) => {
        me.rv.SetControlValue("CylinderHundreds", h);
        me.rv.SetControlValue("CylinderTens", t);
        me.rv.SetControlValue("CylinderUnits", u);
    });
    const acDcPower$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        xt.mapBehavior(
            frp.liftN(
                (selected, isPowerAvailable): [number, number] => {
                    const status = isPowerAvailable ? 2 : 1;
                    return selected === ps.EngineMode.Overhead ? [status, 0] : [0, status];
                },
                modeSelectPlayer,
                isPowerAvailable
            )
        )
    );
    acDcPower$(([ac, dc]) => {
        me.rv.SetControlValue("PowerAC", ac);
        me.rv.SetControlValue("PowerDC", dc);
    });

    // Ditch lights
    const ditchLights = [new rw.Light("Fwd_DitchLightLeft"), new rw.Light("Fwd_DitchLightRight")];
    const ditchLightsPlayer$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("Headlights"),
        frp.map(v => v > 0.5 && v < 1.5)
    );
    const ditchLightsAi$ = frp.compose(
        me.createAiUpdateStream(),
        frp.map(au => {
            const [frontCoupled] = au.couplings;
            return !frontCoupled && au.direction === vh.SensedDirection.Forward;
        })
    );
    const ditchLights$ = frp.compose(
        me.createPlayerWithoutKeyUpdateStream(),
        frp.map(_ => false),
        frp.merge(ditchLightsPlayer$),
        frp.merge(ditchLightsAi$),
        xt.rejectRepeats()
    );
    ditchLights$(on => {
        me.rv.ActivateNode("left_ditch_light", on);
        me.rv.ActivateNode("right_ditch_light", on);
        for (const light of ditchLights) {
            light.Activate(on);
        }
    });

    // Dome light
    const cabLight = new rw.Light("Cablight");
    const cabLightPlayer$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("Cablight"),
        frp.map(v => v > 0.5)
    );
    const cabLight$ = frp.compose(
        me.createPlayerWithoutKeyUpdateStream(),
        frp.merge(me.createAiUpdateStream()),
        frp.map(_ => false),
        frp.merge(cabLightPlayer$),
        xt.rejectRepeats()
    );
    cabLight$(on => {
        cabLight.Activate(on);
    });

    // Passenger interior lights
    const inPassengerView = frp.liftN(
        camera => camera === vh.VehicleCamera.Carriage,
        frp.stepper(me.createOnCameraStream(), vh.VehicleCamera.Outside)
    );
    let passCameraLights: rw.Light[] = [];
    for (let i = 0; i < 6; i++) {
        const n = i * 2 + 1;
        passCameraLights.push(new rw.Light(`PVLight_0${n < 10 ? "0" : ""}${n}`));
    }
    const passCameraLight$ = frp.compose(
        me.createPlayerUpdateStream(),
        xt.mapBehavior(inPassengerView),
        frp.merge(
            frp.compose(
                me.createAiUpdateStream(),
                frp.map(_ => false)
            )
        ),
        xt.rejectRepeats()
    );
    passCameraLight$(on => {
        passCameraLights.forEach(light => light.Activate(on));
    });

    // Door hallway lights
    const hallLights = [new rw.Light("HallLight_001"), new rw.Light("HallLight_002")];
    const doorsOpen$ = frp.compose(
        me.createVehicleUpdateStream(),
        frp.map((vu): [left: boolean, right: boolean] => vu.doorsOpen),
        frp.hub()
    );
    const hallLights$ = frp.compose(
        doorsOpen$,
        frp.map(([l, r]) => l || r),
        xt.rejectRepeats()
    );
    hallLights$(on => {
        hallLights.forEach(light => light.Activate(on));
        me.rv.ActivateNode("round_lights_off", !on);
        me.rv.ActivateNode("round_lights_on", on);
    });

    // Door status lights
    const doorLightLeft$ = frp.compose(
        doorsOpen$,
        frp.map(([l]) => l),
        xt.rejectRepeats()
    );
    const doorLightRight$ = frp.compose(
        doorsOpen$,
        frp.map(([, r]) => r),
        xt.rejectRepeats()
    );
    doorLightLeft$(on => {
        me.rv.ActivateNode("SL_doors_L", on);
    });
    doorLightRight$(on => {
        me.rv.ActivateNode("SL_doors_R", on);
    });

    // Brake status lights
    const brakeLight$ = frp.compose(
        fx.createBrakeLightStreamForEngine(
            me,
            () => (me.rv.GetControlValue("TrainBrakeCylinderPressurePSI") as number) > 34
        ),
        xt.rejectRepeats()
    );
    brakeLight$(on => {
        me.rv.ActivateNode("SL_green", !on);
        me.rv.ActivateNode("SL_yellow", on);
    });
    const handBrakeLightPlayer$ = frp.compose(
        me.createPlayerUpdateStream(),
        me.mapGetCvStream("HandBrake"),
        frp.map(v => v === 1)
    );
    const handBrakeLight$ = frp.compose(
        me.createAiUpdateStream(),
        frp.map(_ => false),
        frp.merge(handBrakeLightPlayer$),
        xt.rejectRepeats()
    );
    handBrakeLight$(on => {
        me.rv.ActivateNode("SL_blue", on);
    });

    // Pantograph gate
    const pantoGateAnim = new fx.Animation(me, "ribbons", 1);
    const pantoGate$ = frp.compose(
        me.createPlayerUpdateStream(),
        frp.merge(me.createAiUpdateStream()),
        frp.map(u => {
            const [frontCoupled] = u.couplings;
            return frontCoupled;
        })
    );
    pantoGate$(coupled => {
        pantoGateAnim.setTargetPosition(coupled ? 1 : 0);
    });

    // Process OnControlValueChange events.
    const onCvChange$ = me.createOnCvChangeStream();
    onCvChange$(([name, value]) => {
        me.rv.SetControlValue(name, value);
    });

    // Enable updates.
    me.e.BeginUpdate();
});
me.setup();

function vanillaBlendedBraking(pct: number): [air: number, dynamic: number] {
    const brakePipePsi = me.rv.GetControlValue("AirBrakePipePressurePSI") as number;
    return [pct, Math.max((150 - brakePipePsi) * 0.01428, 0)];
}

function fanRailerBlendedBraking(pct: number): [air: number, dynamic: number] {
    const isEmergency = pct > 0.99;
    if (isEmergency) {
        return [1, 0];
    }

    const [minMph, maxMph] = [3, 8];
    const [minAir, maxAir] = [0.03, 0.4];
    const aSpeedMph = Math.abs(me.rv.GetSpeed()) * c.mps.toMph;
    if (aSpeedMph > maxMph) {
        return [Math.min(pct, minAir), pct];
    } else if (aSpeedMph > minMph) {
        const dynamicPct = (aSpeedMph - minMph) / (maxMph - minMph);
        return [Math.max(maxAir * (1 - dynamicPct) * pct, Math.min(minAir, pct)), dynamicPct * pct];
    } else {
        return [maxAir * pct, 0];
    }
}

function clampDelta(current: number, target: number, maxChange: number) {
    if (target > current) {
        return Math.min(target, current + maxChange);
    } else if (target < current) {
        return Math.max(target, current - maxChange);
    } else {
        return target;
    }
}

function consistMotorStatus() {
    const amps = me.rv.GetControlValue("Ammeter") as number;
    if (amps >= 30) {
        return 1;
    } else if (amps >= -30) {
        return 0;
    } else {
        return -1;
    }
}

function consistDoorStatus(vu?: vh.VehicleUpdate) {
    const doorsOpen = () => [
        (me.rv.GetControlValue("DoorsOpenCloseLeft") as number) === 1,
        (me.rv.GetControlValue("DoorsOpenCloseRight") as number) === 1,
    ];
    const [l, r] = vu === undefined ? frp.snapshot(doorsOpen) : vu.doorsOpen;
    if (l) {
        return -1;
    } else if (r) {
        return 1;
    } else {
        return 0;
    }
}

function threeDigitDisplay(eventStream: frp.Stream<number>) {
    return frp.compose(
        eventStream,
        frp.map(n => Math.round(Math.abs(n))),
        frp.map(n => m.digits(n, 3))
    );
}
