--------------------------------------------------------------------------------------
-- Engine Script for AEM7 electric locomotive
-- RailWorks 2: Train Simulator
--------------------------------------------------------------------------------------
--
-- Updates controls, reads messages from signals and set engine controls for
-- cab signalling. Controls flashing of appropriate aspects.
--
--------------------------------------------------------------------------------------

-- Boolean.
	TRUE = 1
	FALSE = 0

	ON = 1
	OFF = 0

-- For light flash rate.

	LIGHT_FLASH_ON_SECS = 0.5

-- Cab signal states.

	NONE = 0
	CLR = 1
	CABSPD8 = 2
	CABSPD6 = 3
	APPLIM = 4
	APPMED = 5
	APP = 6
	RESTRICT = 7
	IGNORE = 8

function Initialise ()

-- Initial cab signal states.
	gCabSignal = NONE
	gTrackSpeed = DASH

-- State of flashing for appropriate cab signal aspects.
	gTimeSinceLastFlash = 0
	gLightFlashOn = FALSE

end


function OnControlValueChange ( name, index, value )

	if Call( "*:ControlExists", name, index ) then

		Call( "*:SetControlValue", name, index, value );

	end

end


function OnCustomSignalMessage ( Parameter )

	if ( Call( "GetIsPlayer" ) == TRUE ) then

		newsig = string.sub ( Parameter, 4, 4 )
		if (newsig+0) ~= IGNORE then
			gCabSignal = newsig
		end

		gTrackSpeed = string.sub ( Parameter, 8 )

		Print( (" consist signal: " .. gCabSignal ) )
		Print( (" consist speed: " .. gTrackSpeed) )

		currentSig = Call( "*:GetControlValue", "CabSignal", 0 )
		currentTrk = Call( "*:GetControlValue", "TrackSpeed", 0 )

-- Add zeros to comparisons to ensure the strings are converted to type number.

		if (( currentSig + 0 ) ~= ( gCabSignal + 0 )) and ((newsig+0) ~= IGNORE ) then
			Call( "*:SetControlValue", "CabSignal", 0, gCabSignal )
			Call( "*:SetControlValue", "AlertLight", 0, TRUE )
			Call( "*:SetControlValue", "AWSWarnCount", 0, TRUE )
		end

		if ( (gCabSignal+0) == APPLIM ) then
			Call( "*:SetControlValue", "CabSignal1", 0, OFF )
			Call( "BeginUpdate" )
		elseif ( (gCabSignal+0) == CABSPD8 ) or ( (gCabSignal+0) == CABSPD6 ) then
			Call( "*:SetControlValue", "CabSignal2", 0, OFF )
			Call( "BeginUpdate" )
		elseif (gCabSignal+0) == APPMED then
			Call( "*:SetControlValue", "CabSignal2", 0, ON )
			Call( "*:SetControlValue", "CabSignal1", 0, OFF )
		elseif (gCabSignal+0) == CLR then
			Call( "*:SetControlValue", "CabSignal1", 0, ON )
			Call( "*:SetControlValue", "CabSignal2", 0, OFF )
		elseif (newsig+0) ~= IGNORE then
			Call( "*:SetControlValue", "CabSignal1", 0, OFF )
			Call( "*:SetControlValue", "CabSignal2", 0, OFF )
		end

		if ( currentTrk + 0 ) ~= ( gTrackSpeed + 0 ) then
			Call( "*:SetControlValue", "TrackSpeed", 0, (gTrackSpeed + 0) )
			Call( "*:SetControlValue", "AlertLight", 0, TRUE )
			Call( "*:SetControlValue", "AWSWarnCount", 0, TRUE )
		end
	end
end


function Update ( time )

	gTimeSinceLastFlash = gTimeSinceLastFlash + time
	if gTimeSinceLastFlash > LIGHT_FLASH_ON_SECS then
		gTimeSinceLastFlash = 0
		if gLightFlashOn == FALSE then
			gLightFlashOn = TRUE
			if ((gCabSignal+0) == CABSPD8) or ((gCabSignal+0) == CABSPD6) then
				Call( "*:SetControlValue", "CabSignal1", 0, ON )
			elseif ((gCabSignal+0) == APPLIM) then
				Call( "*:SetControlValue", "CabSignal2", 0, ON )
			end
		else
			gLightFlashOn = FALSE
			if ((gCabSignal+0) == CABSPD8) or ((gCabSignal+0) == CABSPD6) then
				Call( "*:SetControlValue", "CabSignal1", 0, OFF )
			elseif ((gCabSignal+0) == APPLIM) then
				Call( "*:SetControlValue", "CabSignal2", 0, OFF )
			end

		end
	end

	if ((gCabSignal+0) ~= CABSPD6) and
	   ((gCabSignal+0) ~= CABSPD8) and
	   ((gCabSignal+0) ~= APPLIM) then
		gLightFlashOn = FALSE
		gTimeSinceLastFlash = 0
		Call ("EndUpdate")
	end

end

