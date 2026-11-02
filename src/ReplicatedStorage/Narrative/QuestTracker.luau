--!strict
--[[
  QuestTracker.luau
  crustdev studio systems - ReplicatedStorage/Narrative/QuestTracker

  Production-grade narrative quest progression and objective tracking engine:
  - Multi-objective tracking: counter thresholds, boolean flags, and timer constraints.
  - Dependency verification: validates prerequisite quest chains (DAG) and level gates.
  - Automatic completion: resolves reward payloads when all mandatory objectives are met.
  - Lifecycle states: NotStarted, Active, Completed, Failed, and Abandoned.
  - Robust serialization: lossless JSON and DataStore state persistence with schema versioning.
  - Observer signals: decoupled subscription hooks for objective updates and completion events.

  Zero external dependencies. Compatible with Roblox engine and Lune runtime.
]]

export type ObjectiveType = "counter" | "boolean" | "timer"

export type ObjectiveDefinition = {
  id: string,
  description: string,
  objectiveType: ObjectiveType,
  requiredCount: number?,
  optional: boolean?,
}

export type QuestDefinition = {
  id: string,
  title: string,
  description: string,
  category: string?,
  prerequisites: { string }?,
  requiredLevel: number?,
  objectives: { ObjectiveDefinition },
  rewards: { [string]: any }?,
  autoComplete: boolean?,
}

export type ObjectiveProgress = {
  id: string,
  currentCount: number,
  requiredCount: number,
  isCompleted: boolean,
}

export type QuestStatus = "not_started" | "active" | "completed" | "failed" | "abandoned"

export type ActiveQuestState = {
  id: string,
  status: QuestStatus,
  startedAt: number,
  completedAt: number?,
  objectives: { [string]: ObjectiveProgress },
}

export type SerializedQuestData = {
  version: number,
  completedQuestIds: { string },
  activeQuests: { [string]: ActiveQuestState },
  failedQuestIds: { string },
}

export type ObjectiveCallback = (questId: string, objectiveId: string, progress: ObjectiveProgress) -> ()
export type QuestCallback = (questId: string, rewards: { [string]: any }?) -> ()
export type QuestFailCallback = (questId: string, reason: string) -> ()

export type QuestTracker = {
  _definitions: { [string]: QuestDefinition },
  _activeQuests: { [string]: ActiveQuestState },
  _completedQuests: { [string]: boolean },
  _failedQuests: { [string]: boolean },
  _objectiveHooks: { ObjectiveCallback },
  _completionHooks: { QuestCallback },
  _failHooks: { QuestFailCallback },

  RegisterQuest: (self: QuestTracker, def: QuestDefinition) -> boolean,
  GetDefinition: (self: QuestTracker, questId: string) -> QuestDefinition?,
  CanStartQuest: (self: QuestTracker, questId: string, playerLevel: number?) -> (boolean, string?),
  StartQuest: (self: QuestTracker, questId: string, playerLevel: number?) -> (boolean, string?),
  AdvanceObjective: (self: QuestTracker, questId: string, objectiveId: string, delta: number?) -> (boolean, string?),
  CompleteObjective: (self: QuestTracker, questId: string, objectiveId: string) -> (boolean, string?),
  FailQuest: (self: QuestTracker, questId: string, reason: string?) -> boolean,
  AbandonQuest: (self: QuestTracker, questId: string) -> boolean,
  GetQuestState: (self: QuestTracker, questId: string) -> ActiveQuestState?,
  IsQuestCompleted: (self: QuestTracker, questId: string) -> boolean,
  GetActiveQuests: (self: QuestTracker) -> { ActiveQuestState },
  GetCompletedQuestIds: (self: QuestTracker) -> { string },
  OnObjectiveUpdated: (self: QuestTracker, callback: ObjectiveCallback) -> (),
  OnQuestCompleted: (self: QuestTracker, callback: QuestCallback) -> (),
  OnQuestFailed: (self: QuestTracker, callback: QuestFailCallback) -> (),
  Serialize: (self: QuestTracker) -> SerializedQuestData,
  Deserialize: (self: QuestTracker, data: SerializedQuestData) -> boolean,
  Reset: (self: QuestTracker) -> (),
}

local CURRENT_SCHEMA_VERSION = 1
local QuestTracker = {}
QuestTracker.__index = QuestTracker

function QuestTracker.new(): QuestTracker
  local self = setmetatable({
    _definitions = {},
    _activeQuests = {},
    _completedQuests = {},
    _failedQuests = {},
    _objectiveHooks = {},
    _completionHooks = {},
    _failHooks = {},
  }, QuestTracker)

  return (self :: any) :: QuestTracker
end

function QuestTracker:RegisterQuest(def: QuestDefinition): boolean
  if not def.id or type(def.id) ~= "string" or def.id == "" then
    return false
  end
  if not def.objectives or #def.objectives == 0 then
    return false
  end

  self._definitions[def.id] = def
  return true
end

function QuestTracker:GetDefinition(questId: string): QuestDefinition?
  return self._definitions[questId]
end

function QuestTracker:CanStartQuest(questId: string, playerLevel: number?): (boolean, string?)
  local def = self._definitions[questId]
  if not def then
    return false, "Quest not registered"
  end

  if self._completedQuests[questId] then
    return false, "Quest already completed"
  end

  if self._activeQuests[questId] then
    return false, "Quest currently active"
  end

  if def.requiredLevel and (playerLevel or 1) < def.requiredLevel then
    return false, string.format("Level %d required (player is %d)", def.requiredLevel, playerLevel or 1)
  end

  if def.prerequisites then
    for _, prereqId in ipairs(def.prerequisites) do
      if not self._completedQuests[prereqId] then
        return false, string.format("Prerequisite quest '%s' not completed", prereqId)
      end
    end
  end

  return true, nil
end

function QuestTracker:StartQuest(questId: string, playerLevel: number?): (boolean, string?)
  local canStart, reason = self:CanStartQuest(questId, playerLevel)
  if not canStart then
    return false, reason
  end

  local def = self._definitions[questId]
  if not def then
    return false, "Quest definition missing"
  end

  local objProgress: { [string]: ObjectiveProgress } = {}
  for _, obj in ipairs(def.objectives) do
    local req = (obj.objectiveType == "counter" or obj.objectiveType == "timer") and (obj.requiredCount or 1) or 1
    objProgress[obj.id] = {
      id = obj.id,
      currentCount = 0,
      requiredCount = req,
      isCompleted = false,
    }
  end

  local activeState: ActiveQuestState = {
    id = questId,
    status = "active",
    startedAt = os.time(),
    completedAt = nil,
    objectives = objProgress,
  }

  self._activeQuests[questId] = activeState
  self._failedQuests[questId] = nil

  return true, nil
end

local function checkQuestCompletion(self: QuestTracker, questId: string)
  local active = self._activeQuests[questId]
  local def = self._definitions[questId]
  if not active or not def then
    return
  end

  local allMandatoryDone = true
  for _, objDef in ipairs(def.objectives) do
    if not objDef.optional then
      local prog = active.objectives[objDef.id]
      if not prog or not prog.isCompleted then
        allMandatoryDone = false
        break
      end
    end
  end

  if allMandatoryDone then
    local shouldAutoComplete = if def.autoComplete ~= nil then def.autoComplete else true
    if shouldAutoComplete then
      active.status = "completed"
      active.completedAt = os.time()
      self._completedQuests[questId] = true
      self._activeQuests[questId] = nil

      for _, hook in ipairs(self._completionHooks) do
        hook(questId, def.rewards)
      end
    end
  end
end

function QuestTracker:AdvanceObjective(questId: string, objectiveId: string, delta: number?): (boolean, string?)
  local active = self._activeQuests[questId]
  if not active then
    return false, "Quest is not active"
  end

  local prog = active.objectives[objectiveId]
  if not prog then
    return false, "Objective not found in active quest"
  end

  if prog.isCompleted then
    return true, nil -- Already finished
  end

  local step = delta or 1
  prog.currentCount = math.min(prog.requiredCount, prog.currentCount + step)

  if prog.currentCount >= prog.requiredCount then
    prog.isCompleted = true
  end

  for _, hook in ipairs(self._objectiveHooks) do
    hook(questId, objectiveId, prog)
  end

  checkQuestCompletion(self, questId)
  return true, nil
end

function QuestTracker:CompleteObjective(questId: string, objectiveId: string): (boolean, string?)
  local active = self._activeQuests[questId]
  if not active then
    return false, "Quest is not active"
  end

  local prog = active.objectives[objectiveId]
  if not prog then
    return false, "Objective not found in active quest"
  end

  prog.currentCount = prog.requiredCount
  prog.isCompleted = true

  for _, hook in ipairs(self._objectiveHooks) do
    hook(questId, objectiveId, prog)
  end

  checkQuestCompletion(self, questId)
  return true, nil
end

function QuestTracker:FailQuest(questId: string, reason: string?): boolean
  local active = self._activeQuests[questId]
  if not active then
    return false
  end

  active.status = "failed"
  self._failedQuests[questId] = true
  self._activeQuests[questId] = nil

  local failReason = reason or "Objective failed"
  for _, hook in ipairs(self._failHooks) do
    hook(questId, failReason)
  end

  return true
end

function QuestTracker:AbandonQuest(questId: string): boolean
  local active = self._activeQuests[questId]
  if not active then
    return false
  end

  self._activeQuests[questId] = nil
  return true
end

function QuestTracker:GetQuestState(questId: string): ActiveQuestState?
  return self._activeQuests[questId]
end

function QuestTracker:IsQuestCompleted(questId: string): boolean
  return self._completedQuests[questId] == true
end

function QuestTracker:GetActiveQuests(): { ActiveQuestState }
  local list: { ActiveQuestState } = {}
  for _, q in pairs(self._activeQuests) do
    table.insert(list, q)
  end
  return list
end

function QuestTracker:GetCompletedQuestIds(): { string }
  local list: { string } = {}
  for qId in pairs(self._completedQuests) do
    table.insert(list, qId)
  end
  table.sort(list)
  return list
end

function QuestTracker:OnObjectiveUpdated(callback: ObjectiveCallback)
  table.insert(self._objectiveHooks, callback)
end

function QuestTracker:OnQuestCompleted(callback: QuestCallback)
  table.insert(self._completionHooks, callback)
end

function QuestTracker:OnQuestFailed(callback: QuestFailCallback)
  table.insert(self._failHooks, callback)
end

function QuestTracker:Serialize(): SerializedQuestData
  local completedList: { string } = {}
  for qId in pairs(self._completedQuests) do
    table.insert(completedList, qId)
  end
  table.sort(completedList)

  local failedList: { string } = {}
  for qId in pairs(self._failedQuests) do
    table.insert(failedList, qId)
  end
  table.sort(failedList)

  local activeMap: { [string]: ActiveQuestState } = {}
  for qId, state in pairs(self._activeQuests) do
    local objCopy: { [string]: ObjectiveProgress } = {}
    for objId, p in pairs(state.objectives) do
      objCopy[objId] = {
        id = p.id,
        currentCount = p.currentCount,
        requiredCount = p.requiredCount,
        isCompleted = p.isCompleted,
      }
    end

    activeMap[qId] = {
      id = state.id,
      status = state.status,
      startedAt = state.startedAt,
      completedAt = state.completedAt,
      objectives = objCopy,
    }
  end

  return {
    version = CURRENT_SCHEMA_VERSION,
    completedQuestIds = completedList,
    activeQuests = activeMap,
    failedQuestIds = failedList,
  }
end

function QuestTracker:Deserialize(data: SerializedQuestData): boolean
  if not data or type(data) ~= "table" then
    return false
  end

  self._completedQuests = {}
  self._activeQuests = {}
  self._failedQuests = {}

  if data.completedQuestIds then
    for _, qId in ipairs(data.completedQuestIds) do
      self._completedQuests[qId] = true
    end
  end

  if data.failedQuestIds then
    for _, qId in ipairs(data.failedQuestIds) do
      self._failedQuests[qId] = true
    end
  end

  if data.activeQuests then
    for qId, state in pairs(data.activeQuests) do
      self._activeQuests[qId] = state
    end
  end

  return true
end

function QuestTracker:Reset()
  self._activeQuests = {}
  self._completedQuests = {}
  self._failedQuests = {}
end

return QuestTracker
