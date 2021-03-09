--------------------------------------------------------------------------------------
-- Simulation Script for AEM7 electric locomotive
-- RailWorks 2: Train Simulator
--------------------------------------------------------------------------------------
--
-- Controls brake simulation, speed intervention and cruise control.
--
--------------------------------------------------------------------------------------

-- Boolean.

	TRUE = 1
	FALSE = 0

	ON = 1
	OFF = 0

-- Cab signal states.

	NONE = 0
	CLR = 1
	CABSPD8 = 2
	CABSPD6 = 3
	APPLIM = 4
	APPMED = 5
	APP = 6
	RESTRICT = 7

-- Speed limits for each cab aspect. Allow 4mph threshold. Note APPROACH and APPROACH MEDIUM have same speed limit.

	LOCOLIMIT = 129
	CAB8LIMIT = 84
	CAB6LIMIT = 64
	APPLIMLIMIT = 49
	APPLIMIT = 34
	RESTLIMIT = 24

-- Seconds of time to wait before intervening on speed.

	INTERVENE_TIME = 10

-- Seconds of time interval before alerter is started.

	ALERT_CYCLE = 120

-- Seconds of time alerter (audio and visual) is on before penalty is applied.

	ALERT_TIME1 = 5
	ALERT_TIME2 = 10

-- Low speed threshold for alerter.

	ALERT_LOW_SPEED = 20

-- Duration to play alerter sound when alerter is disabled. This is for cab sigal change alerts.

	CAB_ALERT_TIME = 0.6

-- For cab signal light flash rate.

	LIGHT_FLASH_ON_SECS = 0.5



function Setup ()

-- For acceleration calculation.
	gLastTime = 0
	gLastSpeed = 0
	gDampedAcceleration = {}
	for i=0, 24 do
		gDampedAcceleration[i] = 0
	end
	gAccelerationindex = 0

-- For cruise control. The power setting the cruise wants.

	gCruiseRegulator = 0

-- For speed intervention.

	gIntervene = 0

-- For Alerter cycle counting and penalty counting.

	gAlertCycleCounter = 0
	gAlertTimeCounter = 0

-- For Alerter cycle reset from controls.

	gLastPower = 0
	gLastBrake = 0

-- Counter to play alerter sound when alerter is disabled. This is for cab sigal change alerts.

	gSignalAlertCounter = 0

-- State of flashing for alert light.
	gTimeSinceLastFlash = 0
	gLightFlashOn = FALSE

end



function Update (interval)


-- Get some simulation and engine blueprint parameters.

	CurrentTime = Call( "*:GetSimulationTime", 0 )
	CurrentSpeed = Call( "*:GetControlValue", "SpeedometerMPH", 0 )
	SetSpeed = Call( "*:GetControlValue", "CruiseSet", 0 )
	SpeedControl = Call( "*:GetControlValue", "SpeedControl", 0 )
	WheelSlip = Call( "*:GetControlValue", "Wheelslip", 0 )

	PowerLever = Call( "*:GetControlValue", "VirtualThrottle", 0 )
	BrakeLever = Call( "*:GetControlValue", "VirtualBrake", 0 )
	CutIn = Call( "*:GetControlValue", "CutIn", 0 )

	Trackspeed = Call( "*:GetControlValue", "TrackSpeed", 0 )
	Cabsignal = Call( "*:GetControlValue", "CabSignal", 0 )
	Overspeed = Call( "*:GetControlValue", "OverSpeed", 0 )

	AlertReset = Call( "*:GetControlValue", "AWSReset", 0 )
	AlertControl = Call( "*:GetControlValue", "AlertControl", 0 )
	AlertSound = Call( "*:GetControlValue", "AWSWarnCount", 0 )
	AlertLight = Call( "*:GetControlValue", "AlertLight", 0 )
	Current = Call( "*:GetControlValue", "Ammeter", 0 )



-- Current for dynamic brake sound.

	if Current <= 0 then
		Call( "*:SetControlValue", "DynamicCurrent", 0, math.abs( Current ))
	end


-- Alert light flashing.

	if AlertLight == TRUE then
		gTimeSinceLastFlash = gTimeSinceLastFlash + interval
		if gTimeSinceLastFlash > LIGHT_FLASH_ON_SECS then
			gTimeSinceLastFlash = 0
			if gLightFlashOn == FALSE then
				gLightFlashOn = TRUE
				Call( "*:SetControlValue", "AWS", 0, ON )
			else
				gLightFlashOn = FALSE
				Call( "*:SetControlValue", "AWS", 0, OFF )
			end
		end
	else
		gLightFlashOn = FALSE
		gTimeSinceLastFlash = 0
		Call( "*:SetControlValue", "AWS", 0, OFF )
	end


-- Overspeed warning sound.

	if ( Overspeed == TRUE ) and ( SpeedControl == TRUE ) then
		if  BrakeLever < 0.5 then
			Call( "*:SetControlValue", "OverSpeedAlert", 0, TRUE )
		else
			Call( "*:SetControlValue", "OverSpeedAlert", 0, FALSE )
		end
	end

-- Brake cut in.
	if CutIn == FALSE then
		BrakeLever = 0
	end

-- For blended dynamic brakes.
	DynamicSet = BrakeLever/2

-- Acceleration. milesperhourpersecond.

	gDampedAcceleration[gAccelerationindex] = (CurrentSpeed - gLastSpeed) / (CurrentTime - gLastTime)
        gLastTime = CurrentTime
	gLastSpeed = CurrentSpeed

	gAccelerationindex = gAccelerationindex + 1
	if (gAccelerationindex == 25) then
		gAccelerationindex = 0
	end

	Acceleration = 0
	for i=0, 24 do
		Acceleration = Acceleration + gDampedAcceleration[i]
	end
	Acceleration = Acceleration / 25

	Call( "*:SetControlValue", "Acceleration", 0, Acceleration )

-- Cruise control.

	if ( Overspeed == FALSE ) or ( SpeedControl == FALSE ) or ( gAlertTimeCounter < ALERT_TIME2 ) then
		if SetSpeed == 10 then -- This is the cruise "off" position.
			Call( "*:SetControlValue", "Regulator", 0, PowerLever )
		else

			SpeedError = math.abs( SetSpeed - CurrentSpeed )
			SpeedErrorSign = ( SetSpeed - CurrentSpeed ) / SpeedError -- Positive if current speed is too low.
 
			if SpeedError > 20 then

				if ( SpeedErrorSign == -1 ) then -- Above required speed.
					PowerIncrement = 0
					gCruiseRegulator = 0
					if BrakeLever == 0 then
						DynamicSet = 0.8
					end
				else -- Below required speed.
					if Acceleration < 1.5 then
						PowerIncrement = 0.08
					elseif Acceleration > 1.8 then
						PowerIncrement = -0.08
					else
						PowerIncrement = 0
					end
				end

			elseif SpeedError > 10 then

				if ( SpeedErrorSign == -1 ) then -- Above required speed.
					PowerIncrement = 0
					gCruiseRegulator = 0
					if BrakeLever == 0 then
						DynamicSet = 0.4
					end
				else -- Below required speed.
					if Acceleration < 0.5 then
						PowerIncrement = 0.03
					elseif Acceleration > 0.8 then
						PowerIncrement = -0.03
					else
						PowerIncrement = 0
					end
				end

			elseif SpeedError > 5 then

				if ( SpeedErrorSign == -1 ) then -- Above required speed.
					PowerIncrement = 0
					gCruiseRegulator = 0
					if BrakeLever == 0 then
						DynamicSet = 0.1
					end
				else -- Below required speed.
					if Acceleration < 0.4 then
						PowerIncrement = 0.02
					elseif Acceleration > 0.7 then
						PowerIncrement = -0.02
					else
						PowerIncrement = 0
					end
				end

			elseif SpeedError > 0.5 then

				if ( SpeedErrorSign == -1 ) then -- Above required speed.
					if Acceleration < -0.3 then
						PowerIncrement = 0.01
					elseif Acceleration > -0.1 then
						PowerIncrement = -0.01
					else
						PowerIncrement = 0
					end
				else -- Below required speed.
					if Acceleration < 0.2 then
						PowerIncrement = 0.01
					elseif Acceleration > 0.4 then
						PowerIncrement = -0.01
					else
						PowerIncrement = 0
					end
				end

			else
				PowerIncrement = 0
			end
				
			gCruiseRegulator = gCruiseRegulator + PowerIncrement

			if gCruiseRegulator < 0 then
				gCruiseRegulator = 0
			elseif gCruiseRegulator > 1 then
				gCruiseRegulator = 1
			end

			if WheelSlip > 1.1 then
				Call( "*:SetControlValue", "Regulator", 0, 0 )
			elseif PowerLever >= gCruiseRegulator then -- Cap cruise power setting with driver setting.
				Call( "*:SetControlValue", "Regulator", 0, gCruiseRegulator )
			else
				Call( "*:SetControlValue", "Regulator", 0, PowerLever )
			end
		end
	else -- Override power application.
		Call( "*:SetControlValue", "Regulator", 0, 0 )
	end


-- Overspeed.

	if ( CurrentSpeed > LOCOLIMIT ) or
	   (( Trackspeed ~= 0) and ( CurrentSpeed > ( Trackspeed + 4 ))) or
	   (( Cabsignal == CABSPD8 ) and ( CurrentSpeed > CAB8LIMIT )) or
	   (( Cabsignal == CABSPD6 ) and ( CurrentSpeed > CAB6LIMIT )) or
	   (( Cabsignal == APPLIM ) and ( CurrentSpeed > APPLIMLIMIT )) or
	   ((( Cabsignal == APPMED ) or ( Cabsignal == APP )) and ( CurrentSpeed > APPLIMIT )) or
	   (( Cabsignal == RESTRICT ) and ( CurrentSpeed > RESTLIMIT )) then
		if ( Overspeed == FALSE ) then
			Call( "*:SetControlValue", "OverSpeed", 0, TRUE )
		end
	elseif ( Overspeed == TRUE ) then
		Call( "*:SetControlValue", "OverSpeed", 0, FALSE )
		Call( "*:SetControlValue", "OverSpeedAlert", 0, FALSE )
	end

-- Alerter resets.

	if AlertReset == TRUE then
		gAlertCycleCounter = 0
		if gAlertTimeCounter < ALERT_TIME2 then
			gAlertTimeCounter = 0
			Call( "*:SetControlValue", "AWSWarnCount", 0, FALSE )
			Call( "*:SetControlValue", "AlertLight", 0, FALSE )
		end
	end

	if ( PowerLever ~= gLastPower ) or ( BrakeLever ~= gLastBrake ) then
		gAlertCycleCounter = 0
	end

	gLastPower = PowerLever
	gLastBrake = BrakeLever

	if AlertControl == FALSE then
		if AlertSound == TRUE then
			gSignalAlertCounter = gSignalAlertCounter + interval
			if gSignalAlertCounter >= CAB_ALERT_TIME then
				Call( "*:SetControlValue", "AWSWarnCount", 0, FALSE )
				Call( "*:SetControlValue", "AlertLight", 0, FALSE )
				gSignalAlertCounter = 0
			end
		end
	end

-- Speed intervention, including from vigilence alerting.

	if SpeedControl == TRUE then
		if Overspeed == TRUE then
			if gIntervene < INTERVENE_TIME then
				gIntervene = gIntervene + interval
			end
		end
	end

	if ( AlertControl == TRUE ) and ( CurrentSpeed > ALERT_LOW_SPEED ) then
		gAlertCycleCounter = gAlertCycleCounter + interval
		if gAlertCycleCounter >= ALERT_CYCLE then
			if AlertLight == FALSE then
				Call( "*:SetControlValue", "AlertLight", 0, TRUE )
			end
			gAlertTimeCounter = gAlertTimeCounter + interval
			if gAlertTimeCounter >= ALERT_TIME1 then
				if AlertSound == FALSE then
					Call( "*:SetControlValue", "AWSWarnCount", 0, TRUE )
				end
			end
		end
	end

	if ( SpeedControl == FALSE ) and ( AlertControl == FALSE ) then
		Call( "*:SetControlValue", "TrainBrakeControl", 0, BrakeLever )
		Call( "*:SetControlValue", "DynamicBrake", 0, DynamicSet )

	else

		if ( BrakeLever >= 0.5 ) and ( PowerLever == 0 ) then
			gIntervene = 0
			gAlertTimeCounter = 0
		end

		if (( gIntervene >= INTERVENE_TIME ) or ( gAlertTimeCounter >=  ALERT_TIME2 )) and ( BrakeLever < 0.5 ) then
			BrakeLever = 0.5
			DynamicSet = 1
		end

		Call( "*:SetControlValue", "TrainBrakeControl", 0, BrakeLever )
		Call( "*:SetControlValue", "DynamicBrake", 0, DynamicSet )
	end

end



