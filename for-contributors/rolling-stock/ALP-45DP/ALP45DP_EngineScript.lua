local L0_1, L1_1, L2_1, L3_1, L4_1, L5_1, L6_1, L7_1, L8_1, L9_1
L0_1 = Consist
if not L0_1 then
  L0_1 = {}
  Consist = L0_1
  L0_1 = Consist
  L1_1 = Consist
  L0_1.__index = L1_1
  L0_1 = Consist
  L1_1 = true
  L0_1.DEBUG = L1_1
  L0_1 = Consist
  L0_1.MIN_LENGTH_CHANGE = 10
  L0_1 = Consist
  L0_1.CONTROL_ConsistUnitCount = "ConsistUnitCount"
  L0_1 = Consist
  L0_1.CONSIST_Direction = 12001
  L0_1 = Consist
  L0_1.CONSIST_Count = 12020
  L0_1 = Consist
  L0_1.CONSIST_Length = 12021
  L0_1 = Consist
  function L1_1(A0_2, ...)
    local L2_2, L3_2, L4_2, L5_2
    L2_2 = A0_2.DEBUG
    if not L2_2 then
      return
    end
    L2_2 = print
    L3_2 = "[Consist]"
    L4_2 = unpack
    L5_2 = arg
    L4_2, L5_2 = L4_2(L5_2)
    L2_2(L3_2, L4_2, L5_2)
  end
  L0_1.print = L1_1
  L0_1 = Consist
  function L1_1(A0_2)
    local L1_2, L2_2, L3_2
    L1_2 = false
    A0_2.isEngineWithKey = L1_2
    L1_2 = false
    A0_2.isFlipped = L1_2
    A0_2.consistLength = 0
    A0_2.unitCount = 0
    A0_2.unitCountRear = -1
    A0_2.unitCountFront = -1
    L1_2 = false
    A0_2.isCoupledRear = L1_2
    L1_2 = false
    A0_2.isCoupledFront = L1_2
    L2_2 = A0_2
    L1_2 = A0_2.print
    L3_2 = "Initialise()"
    L1_2(L2_2, L3_2)
  end
  L0_1.Initialise = L1_1
  L0_1 = Consist
  function L1_1(A0_2, A1_2, A2_2, A3_2)
  end
  L0_1.OnControlValueChange = L1_1
  L0_1 = Consist
  function L1_1(A0_2, A1_2)
    local L2_2, L3_2, L4_2, L5_2, L6_2, L7_2, L8_2, L9_2, L10_2
    L2_2 = A0_2.isEngineWithKey
    L3_2 = A0_2.consistLength
    L4_2 = Call
    L5_2 = "GetIsEngineWithKey"
    L4_2 = L4_2(L5_2)
    L4_2 = L4_2 == 1
    A0_2.isEngineWithKey = L4_2
    L4_2 = Call
    L5_2 = "GetConsistLength"
    L4_2 = L4_2(L5_2)
    A0_2.consistLength = L4_2
    L4_2 = A0_2.consistLength
    L4_2 = L4_2 - L3_2
    L5_2 = A0_2.isEngineWithKey
    if not L5_2 then
      L5_2 = math
      L5_2 = L5_2.abs
      L6_2 = L4_2
      L5_2 = L5_2(L6_2)
      L6_2 = A0_2.MIN_LENGTH_CHANGE
      if L5_2 > L6_2 then
        L6_2 = A0_2
        L5_2 = A0_2.OnLengthChange
        L7_2 = L3_2
        L5_2(L6_2, L7_2)
      end
      return
    end
    L5_2 = A0_2.isEngineWithKey
    if L5_2 then
      if L2_2 then
        L5_2 = math
        L5_2 = L5_2.abs
        L6_2 = L4_2
        L5_2 = L5_2(L6_2)
        L6_2 = A0_2.MIN_LENGTH_CHANGE
        if not (L5_2 > L6_2) then
          goto lbl_87
        end
      end
      A0_2.unitCount = -1
      A0_2.unitCountRear = -1
      A0_2.unitCountFront = -1
      L5_2 = false
      A0_2.isFlipped = L5_2
      L5_2 = Call
      L6_2 = "SendConsistMessage"
      L7_2 = Consist
      L7_2 = L7_2.CONSIST_Direction
      L8_2 = "1"
      L9_2 = 1
      L5_2(L6_2, L7_2, L8_2, L9_2)
      L5_2 = Call
      L6_2 = "SendConsistMessage"
      L7_2 = Consist
      L7_2 = L7_2.CONSIST_Direction
      L8_2 = "0"
      L9_2 = 0
      L5_2(L6_2, L7_2, L8_2, L9_2)
      L5_2 = Call
      L6_2 = "SendConsistMessage"
      L7_2 = A0_2.CONSIST_Count
      L8_2 = "0"
      L9_2 = 1
      L5_2 = L5_2(L6_2, L7_2, L8_2, L9_2)
      A0_2.isCoupledRear = L5_2
      L5_2 = Call
      L6_2 = "SendConsistMessage"
      L7_2 = A0_2.CONSIST_Count
      L8_2 = "0"
      L9_2 = 0
      L5_2 = L5_2(L6_2, L7_2, L8_2, L9_2)
      A0_2.isCoupledFront = L5_2
      L5_2 = A0_2.unitCountRear
      L6_2 = A0_2.isCoupledRear
      L5_2 = L5_2 * L6_2
      A0_2.unitCountRear = L5_2
      L5_2 = A0_2.unitCountFront
      L6_2 = A0_2.isCoupledFront
      L5_2 = L5_2 * L6_2
      A0_2.unitCountFront = L5_2
      L6_2 = A0_2
      L5_2 = A0_2.OnLengthChange
      L7_2 = L3_2
      L5_2(L6_2, L7_2)
    end
    ::lbl_87::
    L5_2 = A0_2.unitCount
    if L5_2 <= 0 then
      L5_2 = A0_2.unitCountRear
      if 0 <= L5_2 then
        L5_2 = A0_2.unitCountFront
        if 0 <= L5_2 then
          L5_2 = Call
          L6_2 = "GetControlValue"
          L7_2 = A0_2.CONTROL_ConsistUnitCount
          L8_2 = 0
          L5_2 = L5_2(L6_2, L7_2, L8_2)
          if not L5_2 then
            L5_2 = 0
          end
          L6_2 = A0_2.unitCountFront
          L7_2 = A0_2.unitCountRear
          L6_2 = L6_2 + L7_2
          A0_2.unitCount = L6_2
          A0_2.unitCountRear = -1
          A0_2.unitCountFront = -1
          L6_2 = A0_2.unitCount
          if L5_2 ~= L6_2 then
            L6_2 = Call
            L7_2 = "SetControlValue"
            L8_2 = "ConsistUnitCount"
            L9_2 = 0
            L10_2 = A0_2.unitCount
            L6_2(L7_2, L8_2, L9_2, L10_2)
            L6_2 = A0_2.unitCount
            if L5_2 < L6_2 then
              L7_2 = A0_2
              L6_2 = A0_2.OnUnitsAdded
              L8_2 = L5_2
              L6_2(L7_2, L8_2)
            else
              L6_2 = A0_2.unitCount
              if L5_2 > L6_2 then
                L7_2 = A0_2
                L6_2 = A0_2.OnUnitsRemoved
                L8_2 = L5_2
                L6_2(L7_2, L8_2)
              end
            end
          end
        end
      end
    end
  end
  L0_1.Update = L1_1
  L0_1 = Consist
  function L1_1(A0_2, A1_2, A2_2, A3_2)
    local L4_2, L5_2, L6_2, L7_2, L8_2, L9_2, L10_2, L11_2, L12_2
    L4_2 = false
    L5_2 = Consist
    L5_2 = L5_2.CONSIST_Direction
    if A1_2 == L5_2 then
      L6_2 = A0_2
      L5_2 = A0_2.print
      L7_2 = string
      L7_2 = L7_2.format
      L8_2 = "OnConsistMessage(Direction, %s, %s) %s"
      L9_2 = A2_2
      L10_2 = A3_2
      L11_2 = tostring
      L12_2 = A0_2.isFlipped
      L11_2, L12_2 = L11_2(L12_2)
      L7_2, L8_2, L9_2, L10_2, L11_2, L12_2 = L7_2(L8_2, L9_2, L10_2, L11_2, L12_2)
      L5_2(L6_2, L7_2, L8_2, L9_2, L10_2, L11_2, L12_2)
      L5_2 = tonumber
      L6_2 = A2_2
      L5_2 = L5_2(L6_2)
      if not L5_2 then
        L5_2 = 0
      end
      L6_2 = A3_2 ~= L5_2
      A0_2.isFlipped = L6_2
    else
      L5_2 = Consist
      L5_2 = L5_2.CONSIST_Count
      if A1_2 == L5_2 then
        L6_2 = A0_2
        L5_2 = A0_2.print
        L7_2 = string
        L7_2 = L7_2.format
        L8_2 = "OnConsistMessage(Count, %s, %s)"
        L9_2 = A2_2
        L10_2 = A3_2
        L7_2, L8_2, L9_2, L10_2, L11_2, L12_2 = L7_2(L8_2, L9_2, L10_2)
        L5_2(L6_2, L7_2, L8_2, L9_2, L10_2, L11_2, L12_2)
        L4_2 = true
        L5_2 = tonumber
        L6_2 = A2_2
        L5_2 = L5_2(L6_2)
        if not L5_2 then
          L5_2 = 0
        end
        L5_2 = L5_2 + 1
        L6_2 = Call
        L7_2 = "SendConsistMessage"
        L8_2 = A1_2
        L9_2 = L5_2
        L10_2 = A3_2
        L6_2 = L6_2(L7_2, L8_2, L9_2, L10_2)
        L6_2 = L6_2 == 1
        L7_2 = A3_2 == 0 and L7_2
        A0_2.isCoupledRear = L7_2
        L7_2 = A3_2 == 1 and L7_2
        A0_2.isCoupledFront = L7_2
        if not L6_2 then
          A3_2 = 1 - A3_2
          L8_2 = A0_2
          L7_2 = A0_2.print
          L9_2 = string
          L9_2 = L9_2.format
          L10_2 = "SendConsistMessage(Length, %s, %s)"
          L11_2 = L5_2
          L12_2 = A3_2
          L9_2, L10_2, L11_2, L12_2 = L9_2(L10_2, L11_2, L12_2)
          L7_2(L8_2, L9_2, L10_2, L11_2, L12_2)
          L7_2 = Call
          L8_2 = "SendConsistMessage"
          L9_2 = Consist
          L9_2 = L9_2.CONSIST_Length
          L10_2 = L5_2
          L11_2 = A3_2
          L7_2(L8_2, L9_2, L10_2, L11_2)
        end
      else
        L5_2 = Consist
        L5_2 = L5_2.CONSIST_Length
        if A1_2 == L5_2 then
          L6_2 = A0_2
          L5_2 = A0_2.print
          L7_2 = string
          L7_2 = L7_2.format
          L8_2 = "OnConsistMessage(Length, %s, %s)"
          L9_2 = A2_2
          L10_2 = A3_2
          L7_2, L8_2, L9_2, L10_2, L11_2, L12_2 = L7_2(L8_2, L9_2, L10_2)
          L5_2(L6_2, L7_2, L8_2, L9_2, L10_2, L11_2, L12_2)
          L5_2 = A0_2.isEngineWithKey
          if L5_2 then
            if A3_2 == 0 then
              L5_2 = tonumber
              L6_2 = A2_2
              L5_2 = L5_2(L6_2)
              if not L5_2 then
                L5_2 = 0
              end
              A0_2.unitCountRear = L5_2
            elseif A3_2 == 1 then
              L5_2 = tonumber
              L6_2 = A2_2
              L5_2 = L5_2(L6_2)
              if not L5_2 then
                L5_2 = 0
              end
              A0_2.unitCountFront = L5_2
            end
          end
        end
      end
    end
    return L4_2
  end
  L0_1.OnConsistMessage = L1_1
  L0_1 = Consist
  function L1_1(A0_2)
    local L1_2
    L1_2 = A0_2.isFlipped
    return L1_2
  end
  L0_1.IsFlipped = L1_1
  L0_1 = Consist
  function L1_1(A0_2)
    local L1_2
    L1_2 = A0_2.isCoupledRear
    return L1_2
  end
  L0_1.IsCoupledRear = L1_1
  L0_1 = Consist
  function L1_1(A0_2)
    local L1_2
    L1_2 = A0_2.isCoupleFront
    return L1_2
  end
  L0_1.IsCoupledFront = L1_1
  L0_1 = Consist
  function L1_1(A0_2, A1_2, A2_2)
    local L3_2, L4_2, L5_2, L6_2, L7_2
    L3_2 = A0_2.isEngineWithKey
    if L3_2 then
      L3_2 = SysCall
      L4_2 = "ScenarioManager:ShowAlertMessageExt"
      L5_2 = A1_2
      L6_2 = A2_2
      L7_2 = 3
      L3_2(L4_2, L5_2, L6_2, L7_2)
    end
    L4_2 = A0_2
    L3_2 = A0_2.print
    L5_2 = A2_2
    L3_2(L4_2, L5_2)
  end
  L0_1.ShowMessage = L1_1
  L0_1 = Consist
  function L1_1(A0_2, A1_2)
    local L2_2, L3_2, L4_2, L5_2, L6_2, L7_2, L8_2, L9_2
    L2_2 = A0_2.consistLength
    L2_2 = L2_2 - A1_2
    L4_2 = A0_2
    L3_2 = A0_2.print
    L5_2 = string
    L5_2 = L5_2.format
    L6_2 = "OnLengthChange(%s) length:%s, change:%s"
    L7_2 = A1_2
    L8_2 = A0_2.consistLength
    L9_2 = L2_2
    L5_2, L6_2, L7_2, L8_2, L9_2 = L5_2(L6_2, L7_2, L8_2, L9_2)
    L3_2(L4_2, L5_2, L6_2, L7_2, L8_2, L9_2)
  end
  L0_1.OnLengthChange = L1_1
  L0_1 = Consist
  function L1_1(A0_2, A1_2)
    local L2_2, L3_2, L4_2, L5_2, L6_2, L7_2, L8_2, L9_2
    L2_2 = A0_2.unitCount
    L2_2 = L2_2 - A1_2
    L4_2 = A0_2
    L3_2 = A0_2.print
    L5_2 = string
    L5_2 = L5_2.format
    L6_2 = "OnUnitsAdded(%s) count:%s, added:%s"
    L7_2 = A1_2
    L8_2 = A0_2.unitCount
    L9_2 = L2_2
    L5_2, L6_2, L7_2, L8_2, L9_2 = L5_2(L6_2, L7_2, L8_2, L9_2)
    L3_2(L4_2, L5_2, L6_2, L7_2, L8_2, L9_2)
  end
  L0_1.OnUnitsAdded = L1_1
  L0_1 = Consist
  function L1_1(A0_2, A1_2)
    local L2_2, L3_2, L4_2, L5_2, L6_2, L7_2, L8_2, L9_2
    L2_2 = A0_2.unitCount
    L2_2 = A1_2 - L2_2
    L4_2 = A0_2
    L3_2 = A0_2.print
    L5_2 = string
    L5_2 = L5_2.format
    L6_2 = "OnUnitsRemoved(%s) count:%s, removed:%s"
    L7_2 = A1_2
    L8_2 = A0_2.unitCount
    L9_2 = L2_2
    L5_2, L6_2, L7_2, L8_2, L9_2 = L5_2(L6_2, L7_2, L8_2, L9_2)
    L3_2(L4_2, L5_2, L6_2, L7_2, L8_2, L9_2)
  end
  L0_1.OnUnitsRemoved = L1_1
end
L0_1 = Doors
if not L0_1 then
  L0_1 = {}
  Doors = L0_1
  L0_1 = Doors
  L1_1 = Doors
  L0_1.__index = L1_1
  L0_1 = Doors
  L1_1 = true
  L0_1.DEBUG = L1_1
  L0_1 = Doors
  L0_1.CONTROL_DoorsCount = "DoorsCount"
  L0_1 = Doors
  L0_1.CONTROL_DoorsCountLeft = "DoorsCountLeft"
  L0_1 = Doors
  L0_1.CONTROL_DoorsCountRight = "DoorsCountRight"
  L0_1 = Doors
  L0_1.CONTROL_DoorsManual = "DoorsManual"
  L0_1 = Doors
  L0_1.CONTROL_DoorsManualLeft = "DoorsManualLeft"
  L0_1 = Doors
  L0_1.CONTROL_DoorsManualRight = "DoorsManualRight"
  L0_1 = Doors
  L0_1.CONTROL_DoorsManualClose = "DoorsManualClose"
  L0_1 = Doors
  L0_1.CONTROL_DoorsOpenCloseLeft = "DoorsOpenCloseLeft"
  L0_1 = Doors
  L0_1.CONTROL_DoorsOpenCloseRight = "DoorsOpenCloseRight"
  L0_1 = Doors
  L0_1.CONSIST_DoorsLeft = 121011
  L0_1 = Doors
  L0_1.CONSIST_DoorsRight = 121021
  L0_1 = Doors
  L0_1.CONSIST_DoorsRefresh = 121001
  L0_1 = Doors
  L0_1.GUID_DoorControl = "ceea45ac-89d5-47ef-b428-32310b970e1c"
  L0_1 = Doors
  L0_1.GUID_Manual = "45b88cb5-720e-4765-8dbf-1bcd1423f953"
  L0_1 = Doors
  L0_1.GUID_Enabled = "506918be-655f-4489-848b-cc4860329cce"
  L0_1 = Doors
  L0_1.GUID_Disabled = "6aa23447-7b2d-400e-9dce-c0ccb66e9798"
  L0_1 = Doors
  L0_1.MESSAGE_DoorControl = "Door Control"
  L0_1 = Doors
  L0_1.MESSAGE_Manual = "Manual Door Control"
  L0_1 = Doors
  L0_1.MESSAGE_Enabled = "Enabled"
  L0_1 = Doors
  L0_1.MESSAGE_Disabled = "Disabled"
  L0_1 = Doors
  function L1_1(A0_2, ...)
    local L2_2, L3_2, L4_2, L5_2
    L2_2 = A0_2.DEBUG
    if not L2_2 then
      return
    end
    L2_2 = print
    L3_2 = "[Doors]"
    L4_2 = unpack
    L5_2 = arg
    L4_2, L5_2 = L4_2(L5_2)
    L2_2(L3_2, L4_2, L5_2)
  end
  L0_1.print = L1_1
  L0_1 = Doors
  function L1_1(A0_2, A1_2)
