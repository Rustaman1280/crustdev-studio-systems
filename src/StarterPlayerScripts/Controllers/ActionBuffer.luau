--!strict
--[[
  ActionBuffer.luau
  Client-side frame-perfect input queuing, chord buffering, and combo sequence detection.
  Part of crustdev studio game systems (Aetheria: Fractured Realms).
]]

export type ActionEntry = {
  Action: string,
  Timestamp: number,
  ExpiresAt: number,
  Priority: number,
  Payload: any?,
}

export type ActionBufferConfig = {
  DefaultBufferWindow: number?, -- e.g. 0.25 seconds
  HistoryLimit: number?,        -- max entries in historical record (e.g. 16)
  ActionCooldowns: { [string]: number }?,
}

local ActionBuffer = {}
ActionBuffer.__index = ActionBuffer

function ActionBuffer.new(config: ActionBufferConfig?): ActionBufferInstance
  local cfg = config or {}

  local self = setmetatable({}, ActionBuffer)
  self.Config = {
    DefaultBufferWindow = if cfg.DefaultBufferWindow ~= nil then cfg.DefaultBufferWindow else 0.25,
    HistoryLimit = if cfg.HistoryLimit ~= nil then cfg.HistoryLimit else 16,
    ActionCooldowns = if cfg.ActionCooldowns ~= nil then cfg.ActionCooldowns else {},
  }
  self.Queue = {} :: { ActionEntry }
  self.History = {} :: { ActionEntry }
  self.CooldownTimers = {} :: { [string]: number }
  return self
end

export type ActionBufferInstance = typeof(setmetatable({} :: {
  Config: {
    DefaultBufferWindow: number,
    HistoryLimit: number,
    ActionCooldowns: { [string]: number },
  },
  Queue: { ActionEntry },
  History: { ActionEntry },
  CooldownTimers: { [string]: number },
}, ActionBuffer))

-- Check if an action is currently on cooldown
function ActionBuffer:IsOnCooldown(actionName: string, now: number?): boolean
  local clockNow = now or os.clock()
  local readyAt = self.CooldownTimers[actionName]
  if not readyAt then
    return false
  end
  return clockNow < readyAt
end

-- Get remaining cooldown in seconds (0 if ready)
function ActionBuffer:GetRemainingCooldown(actionName: string, now: number?): number
  local clockNow = now or os.clock()
  local readyAt = self.CooldownTimers[actionName]
  if not readyAt or clockNow >= readyAt then
    return 0
  end
  return readyAt - clockNow
end

-- Push an action into the buffer
function ActionBuffer:BufferAction(
  actionName: string,
  payload: any?,
  priority: number?,
  customWindow: number?,
  now: number?
): boolean
  local clockNow = now or os.clock()
  local window = customWindow or self.Config.DefaultBufferWindow
  local prio = priority or 1

  -- Prune expired entries first
  self:Prune(clockNow)

  local entry: ActionEntry = {
    Action = actionName,
    Timestamp = clockNow,
    ExpiresAt = clockNow + window,
    Priority = prio,
    Payload = payload,
  }

  -- Insert sorted by Priority descending, then Timestamp ascending
  local inserted = false
  for i, queued in ipairs(self.Queue) do
    if entry.Priority > queued.Priority then
      table.insert(self.Queue, i, entry)
      inserted = true
      break
    end
  end

  if not inserted then
    table.insert(self.Queue, entry)
  end

  return true
end

-- Peek at the highest-priority active action (optionally filtered by acceptable actions)
function ActionBuffer:PeekAction(allowedActions: { string }?, now: number?): ActionEntry?
  local clockNow = now or os.clock()
  self:Prune(clockNow)

  if #self.Queue == 0 then
    return nil
  end

  if not allowedActions then
    return self.Queue[1]
  end

  local allowedSet: { [string]: boolean } = {}
  for _, act in ipairs(allowedActions) do
    allowedSet[act] = true
  end

  for _, entry in ipairs(self.Queue) do
    if allowedSet[entry.Action] then
      return entry
    end
  end

  return nil
end

-- Consume an action if buffered and not on cooldown
function ActionBuffer:ConsumeAction(actionName: string, now: number?): (boolean, any?)
  local clockNow = now or os.clock()
  self:Prune(clockNow)

  -- Check cooldown
  if self:IsOnCooldown(actionName, clockNow) then
    return false, nil
  end

  for i, entry in ipairs(self.Queue) do
    if entry.Action == actionName then
      table.remove(self.Queue, i)

      -- Apply cooldown
      local cdDuration = self.Config.ActionCooldowns[actionName]
      if cdDuration and cdDuration > 0 then
        self.CooldownTimers[actionName] = clockNow + cdDuration
      end

      -- Record into history
      table.insert(self.History, entry)
      while #self.History > self.Config.HistoryLimit do
        table.remove(self.History, 1)
      end

      return true, entry.Payload
    end
  end

  return false, nil
end

-- Detect if a combo sequence (e.g. {"Light", "Light", "Heavy"}) was executed within maxInterval
function ActionBuffer:DetectCombo(sequence: { string }, maxIntervalSeconds: number?): boolean
  local maxInterval = maxIntervalSeconds or 1.0
  local seqLen = #sequence
  if seqLen == 0 or #self.History < seqLen then
    return false
  end

  local histLen = #self.History
  -- Check from most recent backwards
  local lastTime: number? = nil

  for i = 1, seqLen do
    local expectedAction = sequence[seqLen - i + 1]
    local historyEntry = self.History[histLen - i + 1]

    if historyEntry.Action ~= expectedAction then
      return false
    end

    if lastTime ~= nil then
      if (lastTime - historyEntry.Timestamp) > maxInterval then
        return false
      end
    end
    lastTime = historyEntry.Timestamp
  end

  return true
end

-- Prune expired actions
function ActionBuffer:Prune(now: number?): number
  local clockNow = now or os.clock()
  local removed = 0
  local i = 1
  while i <= #self.Queue do
    if clockNow > self.Queue[i].ExpiresAt then
      table.remove(self.Queue, i)
      removed += 1
    else
      i += 1
    end
  end
  return removed
end

-- Clear buffer queue (e.g. on player death, stun, or cutscene)
function ActionBuffer:Clear(): ()
  table.clear(self.Queue)
end

-- Clear history and cooldowns (full reset)
function ActionBuffer:Reset(): ()
  table.clear(self.Queue)
  table.clear(self.History)
  table.clear(self.CooldownTimers)
end

return ActionBuffer
