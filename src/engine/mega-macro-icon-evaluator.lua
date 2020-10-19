local MacrosToUpdatePerMs = 2
local LastMacroScope = MegaMacroScopes.Global
local LastMacroList = nil
local LastMacroIndex = 0

local IconUpdatedCallbacks = {}
local MacroEffectData = {} -- { Type = "spell" or "item" or "equipment set" or other, Name = "", Icon = 0, Target = "" }

local function GetTextureFromPetCommand(command)
    if command == "dismiss" then
        return PetActionTextures.Dismiss
    elseif command == "attack" then
        return PetActionTextures.Attack
    elseif command == "assist" then
        return PetActionTextures.Assist
    elseif command == "passive" then
        return PetActionTextures.Passive
    elseif command == "defensive" then
        return PetActionTextures.Defensive
    elseif command == "follow" then
        return PetActionTextures.Follow
    elseif command == "moveto" then
        return PetActionTextures.MoveTo
    elseif command == "stay" then
        return PetActionTextures.Stay
    end
end

local function IterateNextMacroInternal(nextScopeAttempts)
    LastMacroIndex = LastMacroIndex + 1

    if LastMacroIndex > #LastMacroList then
        -- limit the recursive iteration to going through each scope once
        if nextScopeAttempts > 5 then
            return false
        end

        if LastMacroScope == MegaMacroScopes.Global then
            LastMacroScope = MegaMacroScopes.Class
        elseif LastMacroScope == MegaMacroScopes.Class then
            LastMacroScope = MegaMacroScopes.Specialization
        elseif LastMacroScope == MegaMacroScopes.Specialization then
            LastMacroScope = MegaMacroScopes.Character
        elseif LastMacroScope == MegaMacroScopes.Character then
            LastMacroScope = MegaMacroScopes.CharacterSpecialization
        elseif LastMacroScope == MegaMacroScopes.CharacterSpecialization then
            LastMacroScope = MegaMacroScopes.Global
        end

        LastMacroIndex = 0
        LastMacroList = MegaMacro.GetMacrosInScope(LastMacroScope)

        return IterateNextMacroInternal(nextScopeAttempts + 1)
    end

    return true
end

local function IterateNextMacro()
    return IterateNextMacroInternal(0)
end

local function GetAbilityData(ability)
    local slotId = tonumber(ability)

    if slotId then
        local itemId = GetInventoryItemID("player", slotId)
        if itemId then
            local itemName, _, _, _, _, _, _, _, _, itemTexture = GetItemInfo(itemId)
            return "item", itemId, itemName, itemTexture
        else
            return "unknown", nil, nil, MegaMacroTexture
        end
    else
        local spellName, _, texture, _, _, _, spellId = MM.GetSpellInfo(ability)
        if spellId then
            local shapeshiftFormIndex = GetShapeshiftForm()
            local isActiveStance = shapeshiftFormIndex and shapeshiftFormIndex > 0 and spellId == select(4, GetShapeshiftFormInfo(shapeshiftFormIndex))
            return "spell", spellId, spellName, isActiveStance and MegaMacroActiveStanceTexture or texture
        end

        local itemId
        itemId, _, _, _, texture = MM.GetItemInfoInstant(ability)
        if texture then
            if MM.GetToyInfo(itemId) then
                spellName, spellId = MM.GetItemSpell(itemId)
                return "spell", spellId, spellName, texture
            else
                return "item", itemId, ability, texture
            end
        end

        return "unknown", nil, ability, MegaMacroTexture
    end
end

local function UpdateMacro(macro)
    local icon = macro.StaticTexture or MegaMacroTexture
    local effectType = nil
    local effectId = nil
    local effectName = nil
    local target = nil

    if icon == MegaMacroTexture then
        local codeInfo = MegaMacroCodeInfo.Get(macro)
        local codeInfoLength = #codeInfo

        for i=1, codeInfoLength do
            local command = codeInfo[i]

            if command.Type == "showtooltip" or command.Type == "use" or command.Type == "cast" then
                local ability, tar = SecureCmdOptionParse(command.Body)

                if ability ~= nil then
                    effectType, effectId, effectName, icon = GetAbilityData(ability)
                    target = tar
                    break
                end
            elseif command.Type == "castsequence" then
                local sequenceCode, tar = SecureCmdOptionParse(command.Body)

                if sequenceCode ~= nil then
                    local _, item, spell = QueryCastSequence(sequenceCode)
                    local ability = item or spell

                    if ability ~= nil then
                        effectType, effectId, effectName, icon = GetAbilityData(ability)
                        target = tar
                        break
                    end

                    break
                end
            elseif command.Type == "stopmacro" then
                local shouldStop = SecureCmdOptionParse(command.Body)
                if shouldStop == "TRUE" then
                    break
                end
            elseif command.Type == "petcommand" then
                local shouldRun = SecureCmdOptionParse(command.Body)
                if shouldRun == "TRUE" then
                    effectType = "other"
                    icon = GetTextureFromPetCommand(command.Command)
                    if command.Command == "dismiss" then
                        effectName = "Dismiss Pet"
                    end
                    break
                end
            elseif command.Type == "equipset" then
                local setName = SecureCmdOptionParse(command.Body)
                if setName then
                    local setId = C_EquipmentSet.GetEquipmentSetID(setName)
                    effectType = "equipment set"
                    effectName = setName
                    if setId then
                        _, icon = C_EquipmentSet.GetEquipmentSetInfo(setId)
                    end
                end
            end
        end

        if effectType == nil and codeInfoLength > 0 then
            if codeInfo[codeInfoLength].Type == "fallbackAbility" then
                local ability = codeInfo[codeInfoLength].Body
                effectType, effectId, effectName, icon = GetAbilityData(ability)
            elseif codeInfo[codeInfoLength].Type == "fallbackSequence" then
                local ability = QueryCastSequence(codeInfo[codeInfoLength].Body)
                effectType, effectId, effectName, icon = GetAbilityData(ability)
            elseif codeInfo[codeInfoLength].Type == "fallbackPetCommand" then
                icon = GetTextureFromPetCommand(codeInfo[codeInfoLength].Body)
            elseif codeInfo[codeInfoLength].Type == "fallbackEquipmentSet" then
                effectType = "equipment set"
                effectName = codeInfo[codeInfoLength].Body
                icon = GetEquipmentSetInfoByName(effectName)
            end
        end
    end

    local currentData = MacroEffectData[macro.Id]

    if not currentData then
        currentData = {}
        MacroEffectData[macro.Id] = currentData
    end

    if currentData.Type ~= effectType
        or currentData.Id ~= effectId
        or currentData.Name ~= effectName
        or currentData.Icon ~= icon
        or currentData.Target ~= target then
        
        currentData.Type = effectType
        currentData.Id = effectId
        currentData.Name = effectName
        currentData.Icon = icon
        currentData.Target = target

        local macroIndex = MegaMacroEngine.GetMacroIndexFromId(macro.Id)
        if macroIndex then
            if effectType == "spell" then
                SetMacroSpell(macroIndex, effectName, target)
            elseif effectType == "item" then
                SetMacroItem(macroIndex, effectName, target)
            else
                -- clear
                SetMacroSpell(macroIndex, "", nil)
            end
        end

        for i=1, #IconUpdatedCallbacks do
            IconUpdatedCallbacks[i](macro.Id, icon)
        end
    end
end

local function UpdateNextMacro()
    if not IterateNextMacro() then
        return false
    end

    local macro = LastMacroList[LastMacroIndex]
    UpdateMacro(macro)

    return true
end

local function UpdateAllMacros()
    MacroEffectData = {}

    LastMacroScope = MegaMacroScopes.Global
    LastMacroList = MegaMacroGlobalData.Macros
    LastMacroIndex = 0

    for _=1, (MacroLimits.MaxGlobalMacros + MacroLimits.MaxCharacterMacros) do
        local previousLastMacroScope = LastMacroScope
        local previousLastMacroList = LastMacroList
        local previousLastMacroIndex = LastMacroIndex

        if not IterateNextMacro() then
            break
        end

        if MacroEffectData[LastMacroList[LastMacroIndex].Id] then
            LastMacroScope = previousLastMacroScope
            LastMacroList = previousLastMacroList
            LastMacroIndex = previousLastMacroIndex
            break
        end

        local macro = LastMacroList[LastMacroIndex]
        UpdateMacro(macro)

        if not UpdateNextMacro() then
            break
        end
    end
end

MegaMacroIconEvaluator = {}

function MegaMacroIconEvaluator.Initialize()
    UpdateAllMacros()
end

function MegaMacroIconEvaluator.Update(elapsedMs)
    local macrosToScan = elapsedMs * MacrosToUpdatePerMs

    for _=1, macrosToScan do
        if not UpdateNextMacro() then
            break
        end
    end
end

-- callback takes 2 parameters: macroId and texture
function MegaMacroIconEvaluator.OnIconUpdated(fn)
    table.insert(IconUpdatedCallbacks, fn)
end

function MegaMacroIconEvaluator.ChangeMacroKey(oldId, newId)
    MacroEffectData[newId] = MacroEffectData[oldId]
end

function MegaMacroIconEvaluator.UpdateMacro(macro)
    UpdateMacro(macro)
end

function MegaMacroIconEvaluator.GetCachedData(macroId)
    return MacroEffectData[macroId]
end

function MegaMacroIconEvaluator.RemoveMacroFromCache(macroId)
    MacroEffectData[macroId] = nil
end

function MegaMacroIconEvaluator.ResetCache()
    UpdateAllMacros()
end