/**
 * Metro-North Bombardier M7
 */

import * as ale from "lib/alerter";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { mapBehavior, rejectRepeats, rejectUndefined } from "lib/frp-extra";
import { VehicleCamera, VehicleUpdate } from "lib/frp-vehicle";
import { AduAspect } from "lib/nec/adu";
import * as cs from "lib/nec/cabsignals";
import * as adu from "lib/nec/twospeed-adu";
import * as m from "lib/math";
import * as ps from "lib/power-supply";
import * as rw from "lib/railworks";
import * as fx from "lib/special-fx";
import * as ui from "lib/ui";

enum ConsistMessageId {
    MotorSounds = 10200,
    ConsistStatus = 10201,
}

type MotorSounds = [lowPitch: number, highPitch: number, volume: number, compressor?: number];

// Try to limit the performance impact of consist messages.
const consistUpdateMs = (1 / 4) * 1e3;

const me = new FrpEngine(() => {
    const isFanRailer = me.rv.GetTotalMass() === 56;

    // Electric power supply
    const electrification = ps.createElectrificationBehaviorWithControlValues(me, {
        [ps.Electrification.Overhead]: ["PowerOverhead", 0],
        [ps.Electrification.ThirdRail]: ["Power3rdRail", 0],
    });
    const isPowerAvailable = () => ps.uniModeEngineHasPower(ps.EngineMode.ThirdRail, electrification);
    // Power3rdRail defaults to 0.
    me.rv.SetControlValue("Power3rdRail", 0, 1);

    // Safety systems cut in/out
    const atcCutIn = () => (me.rv.GetControlValue("ATCCutIn", 0) as number) > 0.5;
    ui.createAtcStatusPopup(me, atcCutIn);
    const alerterCutIn = () => (me.rv.GetControlValue("ACSESCutIn", 0) as number) > 0.5;
    ui.createAlerterStatusPopup(me, alerterCutIn);

    // Safety systems and ADU
    const acknowledge = me.createAcknowledgeBehavior();
    const suppression = () => (me.rv.GetControlValue("ThrottleAndBrake", 0) as number) <= -0.4;
    const [aduState$, aduEvents$] = adu.create(
        cs.metroNorthAtc,
        me,
        acknowledge,
        suppression,
        atcCutIn,
        () => false,
        80 * c.mph.toMps,
        ["CurrentMNRRSignal", 0]
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
    const alerterReset$ = me.createOnCvChangeStreamFor("ThrottleAndBrake", 0);
    const alerter$ = frp.compose(ale.create(me, acknowledge, alerterReset$, alerterCutIn), frp.hub());
    const alerterState = frp.stepper(alerter$, undefined);
    // Safety system sounds
    // Unfortunately, we cannot display the AWS symbol without also playing the
    // fast beep-beep sound, which we use for the alerter.
    const safetyAlarm$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(frp.liftN(aduState => (aduState?.atcAlarm || aduState?.acsesAlarm) ?? false, aduState))
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
        me.rv.SetControlValue("AWSWarnCount", 0, play ? 1 : 0);
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
                const [dcOffset, dcSpeedMax] = [0.1, 1];
                const [dcSpeedCurveUpPitch, dcSpeedCurveUpMult] = [0.6, 0.4];
                const [volumeIncDecMax, pitchIncDecMax] = [4, 1];
                const acDcSpeedMin = 0.23;

                const v1 = Math.min(1, power * 3);
                const v2 = Math.max(v1, Math.max(0, Math.min(1, aSpeedMph * 3 - 4.02336)) * Math.min(1, brake * 5));

                const lowPitch = aSpeedMph * lowPitchSpeedCurveMult;
                const hp1 = speedCurveMult * aSpeedMph * v2 + dcOffset;
                const hp2 =
                    hp1 > dcSpeedCurveUpPitch && v1 === v2
                        ? hp1 + (hp1 - dcSpeedCurveUpPitch) * dcSpeedCurveUpMult
                        : hp1;
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
    speedoMphDigits$(([[h, t, u], guide]) => {
        me.rv.SetControlValue("SpeedoHundreds", 0, h);
        me.rv.SetControlValue("SpeedoTens", 0, t);
        me.rv.SetControlValue("SpeedoUnits", 0, u);
        me.rv.SetControlValue("SpeedoGuide", 0, guide);
    });
    const brakePipePsiDigits$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("AirBrakePipePressurePSI", 0),
        threeDigitDisplay
    );
    brakePipePsiDigits$(([[h, t, u], guide]) => {
        me.rv.SetControlValue("PipeHundreds", 0, h);
        me.rv.SetControlValue("PipeTens", 0, t);
        me.rv.SetControlValue("PipeUnits", 0, u);
        me.rv.SetControlValue("PipeGuide", 0, guide);
    });
    const brakeCylinderPsiDigits$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("TrainBrakeCylinderPressurePSI", 0),
        threeDigitDisplay
    );
    brakeCylinderPsiDigits$(([[h, t, u], guide]) => {
        me.rv.SetControlValue("CylinderHundreds", 0, h);
        me.rv.SetControlValue("CylinderTens", 0, t);
        me.rv.SetControlValue("CylinderUnits", 0, u);
        me.rv.SetControlValue("CylGuide", 0, guide);
    });
    const indicatorsUpdate$ = me.createPlayerWithKeyUpdateStream();
    indicatorsUpdate$(pu => {
        const [leftDoor, rightDoor] = pu.doorsOpen;
        me.rv.SetControlValue("DoorsState", 0, leftDoor || rightDoor ? 1 : 0);
        me.rv.SetControlValue("PenaltyIndicator", 0, frp.snapshot(isPenaltyBrake) ? 1 : 0);
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
    const playerCamera = frp.stepper(me.createOnCameraStream(), VehicleCamera.Outside);
    const passExteriorLight = new rw.Light("RoomLight_PassView");
    const passCameraLights: rw.Light[] = [];
    for (let i = 0; i < 9; i++) {
        passCameraLights.push(new rw.Light(`RoomLight_0${i + 1}`));
    }
    const passLightsNonPlayer$ = frp.compose(
        me.createAiUpdateStream(),
        frp.map(_ => false)
    );
    const passExteriorLight$ = frp.compose(
        me.createPlayerUpdateStream(),
        mapBehavior(frp.liftN(camera => camera === VehicleCamera.Outside, playerCamera)),
        frp.merge(passLightsNonPlayer$),
        rejectRepeats()
    );
    const passCameraLight$ = frp.compose(
        me.createPlayerUpdateStream(),
        mapBehavior(frp.liftN(camera => camera === VehicleCamera.Carriage, playerCamera)),
        frp.merge(passLightsNonPlayer$),
        rejectRepeats()
    );
    passExteriorLight$(on => {
        passExteriorLight.Activate(on);
    });
    passCameraLight$(on => {
        passCameraLights.forEach(light => light.Activate(on));
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
