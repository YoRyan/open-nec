/**
 * Metro-North Kawasaki M8
 */

import * as ale from "lib/alerter";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { mapBehavior, once, rejectRepeats, rejectUndefined } from "lib/frp-extra";
import { SensedDirection, VehicleCamera, VehicleUpdate } from "lib/frp-vehicle";
import { AduAspect } from "lib/nec/adu";
import * as cs from "lib/nec/cabsignals";
import * as adu from "lib/nec/twospeed-adu";
import * as m from "lib/math";
import * as ps from "lib/power-supply";
import * as rw from "lib/railworks";
import * as fx from "lib/special-fx";
import * as ui from "lib/ui";

enum MessageId {
    MotorSounds = 10200,
    ConsistStatus = 10201,
}

type MotorSounds = [lowPitch: number, highPitch: number, volume: number, compressor?: number];

const dualModeSwitchS = 10;
// Try to limit the performance impact of consist messages.
const consistUpdateMs = (1 / 4) * 1e3;

const me = new FrpEngine(() => {
    const isFanRailer = me.rv.GetTotalMass() === 65.7;

    // Dual mode power supply
    const electrification = ps.createElectrificationBehaviorWithControlValues(me, {
        [ps.Electrification.Overhead]: ["PowerOverhead", 0],
        [ps.Electrification.ThirdRail]: ["Power3rdRail", 0],
    });
    // These control values aren't set properly in the engine blueprints. We'll
    // fix them, but only for the first time--not when resuming from a save.
    const rvPowerMode = me.rv.GetRVNumber()[0] === "T" ? ps.EngineMode.ThirdRail : ps.EngineMode.Overhead;
    const resumeFromSave = frp.stepper(me.createFirstUpdateStream(), false);
    const fixPowerValues$ = frp.compose(
        me.createUpdateStream(),
        frp.filter(_ => !frp.snapshot(resumeFromSave) && frp.snapshot(me.areControlsSettled)),
        frp.map(_ => true),
        once(),
        frp.hub()
    );
    fixPowerValues$(() => {
        me.rv.SetControlValue(rvPowerMode === ps.EngineMode.ThirdRail ? "Power3rdRail" : "PowerOverhead", 0, 1);
        // We need to wait until controls are settled to set this CV, otherwise
        // it will slew.
        me.rv.SetControlValue("Panto", 0, rvPowerMode === ps.EngineMode.ThirdRail ? 2 : 1);
    });
    const modeSelect = frp.liftN(
        (resumed, fixedValues) => {
            if (resumed || fixedValues) {
                const cv = Math.round(me.rv.GetControlValue("Panto", 0) as number);
                return cv < 1.5 ? ps.EngineMode.Overhead : ps.EngineMode.ThirdRail;
            } else {
                return rvPowerMode;
            }
        },
        resumeFromSave,
        frp.stepper(fixPowerValues$, false) // Avoid any potential timing issues.
    );
    const [modePosition$] = ps.createDualModeEngineStream(
        me,
        ps.EngineMode.Overhead,
        ps.EngineMode.ThirdRail,
        modeSelect,
        () => false,
        () => me.rv.GetControlValue("Regulator", 0) === 0,
        dualModeSwitchS,
        true,
        ["MaximumSpeedLimit", 0]
    );
    const modePosition = frp.stepper(modePosition$, 0);
    const energyOn = () => (me.rv.GetControlValue("PantographControl", 0) as number) > 0.5;
    const pantoUp = () => {
        const cv = me.rv.GetControlValue("Panto", 0) as number;
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
        me.createAiUpdateStream(),
        mapBehavior(frp.liftN(modeSelect => modeSelect === ps.EngineMode.Overhead, modeSelect)),
        frp.merge(frp.compose(me.createPlayerUpdateStream(), mapBehavior(pantoUp)))
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
    const atcCutIn = () => (me.rv.GetControlValue("ATCCutIn", 0) as number) > 0.5;
    const acsesCutIn = () => (me.rv.GetControlValue("ACSESCutIn", 0) as number) > 0.5;
    ui.createAtcStatusPopup(me, atcCutIn);
    ui.createAcsesStatusPopup(me, acsesCutIn);
    const alerterCutIn = frp.liftN((atcCutIn, acsesCutIn) => atcCutIn || acsesCutIn, atcCutIn, acsesCutIn);

    // Safety systems and ADU
    const acknowledge = me.createAcknowledgeBehavior();
    const suppression = () => (me.rv.GetControlValue("ThrottleAndBrake", 0) as number) <= -0.4;
    const [aduState$, aduEvents$] = adu.create(
        cs.metroNorthAtc,
        me,
        acknowledge,
        suppression,
        atcCutIn,
        acsesCutIn,
        80 * c.mph.toMps,
        ["SignalSpeedLimit", 0]
    );
    const aduStateHub$ = frp.compose(aduState$, frp.hub());
    aduStateHub$(state => {
        me.rv.SetControlValue("SigN", 0, state.aspect === cs.FourAspect.Clear ? 1 : 0);
        me.rv.SetControlValue("SigL", 0, state.aspect === cs.FourAspect.ApproachLimited ? 1 : 0);
        me.rv.SetControlValue("SigM", 0, state.aspect === cs.FourAspect.Approach ? 1 : 0);
        me.rv.SetControlValue("SigR", 0, state.aspect === cs.FourAspect.Restricting ? 1 : 0);
        me.rv.SetControlValue("SigS", 0, state.aspect === AduAspect.Stop ? 1 : 0);

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
            me.rv.SetControlValue("TrackSpeedHundreds", 0, h);
            me.rv.SetControlValue("TrackSpeedTens", 0, t);
            me.rv.SetControlValue("TrackSpeedUnits", 0, u);
        } else {
            me.rv.SetControlValue("TrackSpeedHundreds", 0, -1);
            me.rv.SetControlValue("TrackSpeedTens", 0, -1);
            me.rv.SetControlValue("TrackSpeedUnits", 0, -1);
        }
    });
    const aduState = frp.stepper(aduStateHub$, undefined);
    // Alerter
    const alerterReset$ = me.createOnCvChangeStreamFor("ThrottleAndBrake", 0);
    const alerter$ = frp.compose(ale.create(me, acknowledge, alerterReset$, alerterCutIn), frp.hub());
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
        me.rv.SetControlValue("SpeedReductionAlert", 0, play ? 1 : 0);
    });
    const alerterAlarm$ = frp.compose(
        alerter$,
        frp.map(state => state.alarm)
    );
    alerterAlarm$(play => {
        me.rv.SetControlValue("AWS", 0, play ? 1 : 0);
    });
    const upgradeEvents$ = frp.compose(
        aduEvents$,
        frp.filter(evt => evt === adu.AduEvent.Upgrade)
    );
    const upgradeSound$ = frp.compose(me.createPlayerWithKeyUpdateStream(), fx.triggerSound(1, upgradeEvents$));
    upgradeSound$(play => {
        me.rv.SetControlValue("SpeedIncreaseAlert", 0, play ? 1 : 0);
    });

    // Throttle, dynamic brake, and air brake controls
    const isPenaltyBrake = frp.liftN(
        (aduState, alerterState) => (aduState?.penaltyBrake || alerterState?.penaltyBrake) ?? false,
        aduState,
        alerterState
    );
    const combinedPower = () => me.rv.GetControlValue("ThrottleAndBrake", 0) as number;
    const throttle = frp.liftN(
        (isPenaltyBrake, isPowerAvailable, input) => (isPenaltyBrake || !isPowerAvailable ? 0 : Math.max(input, 0)),
        isPenaltyBrake,
        isPowerAvailable,
        combinedPower
    );
    const throttle$ = frp.compose(me.createPlayerWithKeyUpdateStream(), mapBehavior(throttle));
    throttle$(v => {
        me.rv.SetControlValue("Regulator", 0, v);
    });
    const brake = frp.liftN(
        (isPenaltyBrake, input, fullService) => (isPenaltyBrake ? fullService : Math.max(-input, 0)),
        isPenaltyBrake,
        combinedPower,
        0.85
    );
    const blendedBrakes$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(brake),
        frp.map(isFanRailer ? fanRailerBlendedBraking : vanillaBlendedBraking)
    );
    blendedBrakes$(([air, dynamic]) => {
        me.rv.SetControlValue("TrainBrakeControl", 0, air);
        me.rv.SetControlValue("DynamicBrake", 0, dynamic);
    });

    // Blueprintless notches for the master controller
    me.slewControlValue("ThrottleAndBrake", 0, v => {
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
                const power = me.rv.GetControlValue("Regulator", 0) as number;
                const brake = me.rv.GetControlValue("TrainBrakeControl", 0) as number;
                const compressor = me.rv.GetControlValue("CompressorState", 0) as number;

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
        me.rv.SendConsistMessage(MessageId.MotorSounds, msg, rw.ConsistDirection.Forward);
        me.rv.SendConsistMessage(MessageId.MotorSounds, msg, rw.ConsistDirection.Backward);
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
        frp.filter(([id]) => id === MessageId.MotorSounds)
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
        rejectRepeats()
    );
    const motorHighPitch$ = frp.compose(
        motorSounds$,
        frp.map(([, highPitch]) => highPitch),
        rejectRepeats()
    );
    const motorVolume$ = frp.compose(
        motorSounds$,
        frp.map(([, , volume]) => volume),
        rejectRepeats()
    );
    const motorCompressor$ = frp.compose(
        motorSounds$,
        frp.map(([, , , compressor]) => compressor),
        rejectRepeats(),
        rejectUndefined()
    );
    motorLowPitch$(v => {
        me.rv.SetControlValue("MotorLowPitch", 0, v);
    });
    motorHighPitch$(v => {
        me.rv.SetControlValue("MotorHighPitch", 0, v);
    });
    motorVolume$(v => {
        me.rv.SetControlValue("MotorVolume", 0, v);
    });
    motorCompressor$(v => {
        me.rv.SetControlValue("CompressorState", 0, v);
    });
    me.rv.SetControlValue("FanSound", 0, 1);

    // Consist display
    const consistStatusSend$ = frp.compose(
        me.createPlayerWithoutKeyUpdateStream(),
        frp.throttle(consistUpdateMs),
        frp.filter(pu => {
            const [frontCoupled] = pu.couplings;
            return !frontCoupled;
        })
    );
    consistStatusSend$(pu => {
        const msg = `${consistMotorStatus()}:${consistDoorStatus(pu)}`;
        me.rv.SendConsistMessage(MessageId.ConsistStatus, msg, rw.ConsistDirection.Backward);
    });
    const consistStatusForward$ = frp.compose(
        me.createOnConsistMessageStream(),
        frp.filter(([id]) => id === MessageId.ConsistStatus)
    );
    consistStatusForward$(([, prev, dir]) => {
        const msg = `${consistMotorStatus()}:${consistDoorStatus()}`;
        me.rv.SendConsistMessage(MessageId.ConsistStatus, `${msg};${prev}`, dir);
    });
    const consistStatusReceive$ = frp.compose(
        me.createOnConsistMessageStream(),
        frp.filter(([id]) => id === MessageId.ConsistStatus),
        frp.map(([, msg]) => msg)
    );
    const consistStatusDisplay$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        // Prevent the last car from flickering.
        frp.filter(_ => frp.snapshot(me.areControlsSettled)),
        mapBehavior(frp.stepper(consistStatusReceive$, undefined))
    );
    consistStatusDisplay$(status => {
        const behind = status?.split(";") ?? [];
        me.rv.SetControlValue("Cars", 0, behind.length);
        for (let i = 0; i < behind.length; i++) {
            const [motor, doors] = behind[i].split(":").map(s => tonumber(s) ?? 0);
            me.rv.SetControlValue(`Motor_${i + 2}`, 0, motor);
            me.rv.SetControlValue(`Doors_${i + 2}`, 0, doors);
        }
    });

    // Driving display
    const speedoMphDigits$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("SpeedometerMPH", 0),
        threeDigitDisplay
    );
    speedoMphDigits$(([[h, t, u]]) => {
        me.rv.SetControlValue("SpeedoHundreds", 0, h);
        me.rv.SetControlValue("SpeedoTens", 0, t);
        me.rv.SetControlValue("SpeedoUnits", 0, u);
    });
    const brakePipePsiDigits$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("AirBrakePipePressurePSI", 0),
        threeDigitDisplay
    );
    brakePipePsiDigits$(([[h, t, u]]) => {
        me.rv.SetControlValue("PipeHundreds", 0, h);
        me.rv.SetControlValue("PipeTens", 0, t);
        me.rv.SetControlValue("PipeUnits", 0, u);
    });
    const brakeCylinderPsiDigits$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("TrainBrakeCylinderPressurePSI", 0),
        threeDigitDisplay
    );
    brakeCylinderPsiDigits$(([[h, t, u]]) => {
        me.rv.SetControlValue("CylinderHundreds", 0, h);
        me.rv.SetControlValue("CylinderTens", 0, t);
        me.rv.SetControlValue("CylinderUnits", 0, u);
    });
    const acDcPower$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                (selected, isPowerAvailable): [number, number] => {
                    const status = isPowerAvailable ? 2 : 1;
                    return selected === ps.EngineMode.Overhead ? [status, 0] : [0, status];
                },
                modeSelect,
                isPowerAvailable
            )
        )
    );
    acDcPower$(([ac, dc]) => {
        me.rv.SetControlValue("PowerAC", 0, ac);
        me.rv.SetControlValue("PowerDC", 0, dc);
    });

    // Ditch lights
    const ditchLights = [new rw.Light("Fwd_DitchLightLeft"), new rw.Light("Fwd_DitchLightRight")];
    const ditchLightsPlayer$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("Headlights", 0),
        frp.map(v => v > 0.5 && v < 1.5)
    );
    const ditchLightsAi$ = frp.compose(
        me.createAiUpdateStream(),
        frp.map(au => {
            const [frontCoupled] = au.couplings;
            return !frontCoupled && au.direction === SensedDirection.Forward;
        })
    );
    const ditchLights$ = frp.compose(
        me.createPlayerWithoutKeyUpdateStream(),
        frp.map(_ => false),
        frp.merge(ditchLightsPlayer$),
        frp.merge(ditchLightsAi$),
        rejectRepeats()
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
        me.mapGetCvStream("Cablight", 0),
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
    let passLights: rw.Light[] = [];
    for (let i = 0; i < 12; i++) {
        passLights.push(new rw.Light(`PVLight_0${i < 10 ? "0" : ""}${i}`));
    }
    const isPassengerView = frp.stepper(
        frp.compose(
            me.createOnCameraStream(),
            frp.map(camera => camera === VehicleCamera.Carriage)
        ),
        false
    );
    const passLight$ = frp.compose(me.createUpdateStream(), mapBehavior(isPassengerView), rejectRepeats());
    passLight$(on => {
        for (const light of passLights) {
            light.Activate(on);
        }
    });

    // Door hallway lights
    const hallLights = [new rw.Light("HallLight_001"), new rw.Light("HallLight_002")];
    const hallLightsPlayer$ = frp.compose(
        me.createPlayerUpdateStream(),
        frp.map(pu => {
            const [l, r] = pu.doorsOpen;
            return l || r;
        })
    );
    const hallLights$ = frp.compose(
        me.createAiUpdateStream(),
        frp.map(_ => false),
        frp.merge(hallLightsPlayer$),
        rejectRepeats()
    );
    hallLights$(on => {
        for (const light of hallLights) {
            light.Activate(on);
        }
        me.rv.ActivateNode("round_lights_off", !on);
        me.rv.ActivateNode("round_lights_on", on);
    });

    // Door status lights
    const doorLightsPlayer$ = frp.compose(
        me.createPlayerUpdateStream(),
        frp.map((pu): [boolean, boolean] => pu.doorsOpen)
    );
    const doorLights$ = frp.compose(
        me.createAiUpdateStream(),
        frp.map((au): [boolean, boolean] => [au.isStopped, au.isStopped]),
        frp.merge(doorLightsPlayer$)
    );
    const doorLightLeft$ = frp.compose(
        doorLights$,
        frp.map(([l]) => l),
        rejectRepeats()
    );
    const doorLightRight$ = frp.compose(
        doorLights$,
        frp.map(([, r]) => r),
        rejectRepeats()
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
            () => (me.rv.GetControlValue("TrainBrakeCylinderPressurePSI", 0) as number) > 34
        ),
        rejectRepeats()
    );
    brakeLight$(on => {
        me.rv.ActivateNode("SL_green", !on);
        me.rv.ActivateNode("SL_yellow", on);
    });
    const handBrakeLightPlayer$ = frp.compose(
        me.createPlayerUpdateStream(),
        me.mapGetCvStream("HandBrake", 0),
        frp.map(v => v === 1)
    );
    const handBrakeLight$ = frp.compose(
        me.createAiUpdateStream(),
        frp.map(_ => false),
        frp.merge(handBrakeLightPlayer$),
        rejectRepeats()
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
    onCvChange$(([name, index, value]) => {
        me.rv.SetControlValue(name, index, value);
    });

    // Enable updates.
    me.e.BeginUpdate();
});
me.setup();

function vanillaBlendedBraking(pct: number): [air: number, dynamic: number] {
    const brakePipePsi = me.rv.GetControlValue("AirBrakePipePressurePSI", 0) as number;
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
    const amps = me.rv.GetControlValue("Ammeter", 0) as number;
    if (amps >= 30) {
        return 1;
    } else if (amps >= -30) {
        return 0;
    } else {
        return -1;
    }
}

function consistDoorStatus(vu?: VehicleUpdate) {
    const doorsOpen = () => [
        (me.rv.GetControlValue("DoorsOpenCloseLeft", 0) as number) === 1,
        (me.rv.GetControlValue("DoorsOpenCloseRight", 0) as number) === 1,
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