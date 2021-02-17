-- Constants, lookup tables, and code for Amtrak's Pennsylvania Railroad-derived
-- pulse code cab signaling and Automatic Train Control system.

Atc = {}
Atc.__index = Atc

Atc.pulse_code = {restricting = "Restricting",
                  approach = "Approach",
                  approach_medium = "ApproachMedium",
                  cab_speed_60 = "CabSpeed60",
                  cab_speed_80 = "CabSpeed80",
                  clear_100 = "Clear100",
                  clear_125 = "Clear125",
                  clear_150 = "Clear150"}

-- Get the pulse code that corresponds to a signal message. If nil, then the
-- message can be ignored.
function Atc.get_pulse_code(message)
  if string.sub(message, 1, 3) == "sig" then
    local code = string.sub(message, 4, 4)
    -- DTG "Clear"
    if code == "1" then
      -- Note that we have no way to distinguish between the different speeds of
      -- Clear aspects.
      return Atc.pulse_code.clear_125
    elseif code == "2" then
      return Atc.pulse_code.cab_speed_80
    elseif code == "3" then
      return Atc.pulse_code.cab_speed_60
    -- DTG "Approach Limited (45mph)"
    elseif code == "4" then
      return Atc.pulse_code.approach_medium
    -- DTG "Approach Medium (30mph)"
    elseif code == "5" then
      return Atc.pulse_code.approach
    -- DTG "Approach (30mph)"
    elseif code == "6" then
      return Atc.pulse_code.approach
    elseif code == "7" then
      return Atc.pulse_code.restricting
    else
      return nil
    end
  else
    return nil
  end
end