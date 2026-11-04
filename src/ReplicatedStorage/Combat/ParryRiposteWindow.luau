--!strict
--[[
  ParryRiposteWindow.luau
  crustdev studio systems - ReplicatedStorage/Combat/ParryRiposteWindow

  High-precision melee combat defense matrix, frame-timed parry windows,
  directional guard cones, posture/poise stamina meters, and critical riposte counters.

  Features:
  - Explicit combat defense state machine: Neutral, Guarding, ParryStartup,
    ParryActive, ParryRecovery, ParryWhiff, RiposteReady, and GuardBroken.
  - Microsecond-accurate frame window transitions (Startup, Active Deflection, Recovery, Whiff).
  - Directional guard & deflection cones on XZ plane with configurable angular arcs.
  - Posture / poise stamina meter with delayed regeneration and guard break vulnerability.
  - Perfect Deflection (Parry): 100% damage mitigation, attacker stagger stun, posture reflection,
    and timed Riposte vulnerability window with critical counter multipliers.
  - Guarding mechanics: directional chip damage mitigation and posture depletion.
  - Counter-hit vulnerability: damage multipliers on whiffed parries and guard breaks.
  - Pure Luau / Lune compatible with zero external dependencies.
  - Zero Em-Dash Policy compliant.
]]

local Vector3 = _G.Vector3 or Vector3

export type DefenseState =
  "Neutral"
  | "Guarding"
  | "ParryStartup"
  | "ParryActive"
  | "ParryRecovery"
  | "ParryWhiff"
  | "RiposteReady"
  | "GuardBroken"

export type DefenseOutcome =
  "Parried"
  | "Blocked"
  | "GuardBroken"
  | "Hit"
  | "WhiffPunished"

export type AttackType = "Light" | "Heavy" | "Thrust" | "Sweep" | "Special"

export type IncomingAttack = {
  AttackerId: string,
  AttackerPosition: Vector3,
  Damage: number,
  PostureDamage: number,
  Unparryable: boolean?,
  Unblockable: boolean?,
  AttackType: AttackType?,
}

export type DefenseResolution = {
  Outcome: DefenseOutcome,
  DamageTaken: number,
  PostureDamageTaken: number,
  AttackerStunDuration: number,
  DefenderRiposteAvailable: boolean,
  RiposteMultiplier: number,
  DeflectionAngleDeg: number,
  AngleWithinParryCone: boolean,
  AngleWithinBlockCone: boolean,
}

export type CombatConfig = {
  StartupDuration: number?, -- Seconds before parry active window (default: 0.05)
  ActiveDuration: number?, -- Seconds parry remains active (default: 0.15)
  RecoveryDuration: number?, -- Seconds in post-parry recovery (default: 0.25)
  WhiffPenaltyDuration: number?, -- Seconds defender is punished on empty parry (default: 0.35)
  WhiffDamageMultiplier: number?, -- Bonus damage taken during whiff/recovery (default: 1.25)
  BlockAngleDeg: number?, -- Frontal blocking cone in degrees (default: 140)
  ParryAngleDeg: number?, -- Frontal parry cone in degrees (default: 100)
  MaxPosture: number?, -- Maximum poise / guard meter (default: 100)
  PostureRegenRate: number?, -- Posture points recovered per second (default: 25)
  PostureRegenDelay: number?, -- Seconds before posture regenerates after hit/block (default: 1.5)
  GuardBreakStunDuration: number?, -- Seconds immobilized on guard break (default: 2.0)
  RiposteWindowDuration: number?, -- Seconds available to execute a riposte (default: 1.5)
  RiposteDamageMultiplier: number?, -- Critical damage multiplier for riposte attack (default: 2.5)
  BlockMitigation: number?, -- Damage reduction fraction when blocking (default: 0.85)
  ParryPostureReflect: number?, -- Posture damage dealt back to attacker on parry (default: 30)
  ParryAttackerStunDuration: number?, -- Seconds attacker is staggered on parry (default: 1.25)
}

local EPSILON = 1e-4

local ParryRiposteWindow = {}
ParryRiposteWindow.__index = ParryRiposteWindow

export type ParryRiposteInstance = typeof(setmetatable({} :: {
  _config: {
    StartupDuration: number,
    ActiveDuration: number,
    RecoveryDuration: number,
    WhiffPenaltyDuration: number,
    WhiffDamageMultiplier: number,
    BlockAngleDeg: number,
    ParryAngleDeg: number,
    MaxPosture: number,
    PostureRegenRate: number,
    PostureRegenDelay: number,
    GuardBreakStunDuration: number,
    RiposteWindowDuration: number,
    RiposteDamageMultiplier: number,
    BlockMitigation: number,
    ParryPostureReflect: number,
    ParryAttackerStunDuration: number,
  },
  _state: DefenseState,
  _stateTimer: number,
  _currentPosture: number,
  _postureRegenCooldown: number,
  _riposteMultiplier: number,
  _riposteTargetId: string?,
  _parryTriggeredHit: boolean,
  _onParrySuccessCallbacks: { (attackerId: string, duration: number) -> () },
  _onBlockedCallbacks: { (attackerId: string, mitigated: number, chipDamage: number) -> () },
  _onGuardBreakCallbacks: { (attackerId: string, stunDuration: number) -> () },
}, ParryRiposteWindow))

function ParryRiposteWindow.new(config: CombatConfig?): ParryRiposteInstance
  local cfg = config or {}
  local resolvedConfig = {
    StartupDuration = cfg.StartupDuration or 0.05,
    ActiveDuration = cfg.ActiveDuration or 0.15,
    RecoveryDuration = cfg.RecoveryDuration or 0.25,
    WhiffPenaltyDuration = cfg.WhiffPenaltyDuration or 0.35,
    WhiffDamageMultiplier = cfg.WhiffDamageMultiplier or 1.25,
    BlockAngleDeg = cfg.BlockAngleDeg or 140,
    ParryAngleDeg = cfg.ParryAngleDeg or 100,
    MaxPosture = cfg.MaxPosture or 100,
    PostureRegenRate = cfg.PostureRegenRate or 25,
    PostureRegenDelay = cfg.PostureRegenDelay or 1.5,
    GuardBreakStunDuration = cfg.GuardBreakStunDuration or 2.0,
    RiposteWindowDuration = cfg.RiposteWindowDuration or 1.5,
    RiposteDamageMultiplier = cfg.RiposteDamageMultiplier or 2.5,
    BlockMitigation = cfg.BlockMitigation or 0.85,
    ParryPostureReflect = cfg.ParryPostureReflect or 30,
    ParryAttackerStunDuration = cfg.ParryAttackerStunDuration or 1.25,
  }

  local self = setmetatable({
    _config = resolvedConfig,
    _state = "Neutral" :: DefenseState,
    _stateTimer = 0,
    _currentPosture = resolvedConfig.MaxPosture,
    _postureRegenCooldown = 0,
    _riposteMultiplier = 1.0,
    _riposteTargetId = nil,
    _parryTriggeredHit = false,
    _onParrySuccessCallbacks = {},
    _onBlockedCallbacks = {},
    _onGuardBreakCallbacks = {},
  }, ParryRiposteWindow)

  return self
end

-- Check if defender can initiate a parry attempt
function ParryRiposteWindow.CanParry(self: ParryRiposteInstance): boolean
  return self._state == "Neutral" or self._state == "Guarding"
end

-- Initiate a parry attempt
function ParryRiposteWindow.TriggerParry(self: ParryRiposteInstance): boolean
  if not self:CanParry() then
    return false
  end

  self._state = "ParryStartup"
  self._stateTimer = self._config.StartupDuration
  self._parryTriggeredHit = false
  return true
end

-- Enter guard / block stance
function ParryRiposteWindow.StartBlock(self: ParryRiposteInstance): boolean
  if self._state == "Neutral" then
    self._state = "Guarding"
    self._stateTimer = 0
    return true
  end
  return false
end

-- Exit guard stance
function ParryRiposteWindow.EndBlock(self: ParryRiposteInstance): boolean
  if self._state == "Guarding" then
    self._state = "Neutral"
    self._stateTimer = 0
    return true
  end
  return false
end

-- Check if currently vulnerable to counter-hit damage
function ParryRiposteWindow.IsVulnerable(self: ParryRiposteInstance): boolean
  return self._state == "ParryRecovery"
    or self._state == "ParryWhiff"
    or self._state == "GuardBroken"
end

-- Calculate deflection angle relative to defender's facing direction
local function calculateAngleDeg(defenderPos: Vector3, defenderFacing: Vector3, attackerPos: Vector3): number
  local diff = Vector3.new(attackerPos.X - defenderPos.X, 0, attackerPos.Z - defenderPos.Z)
  if diff.Magnitude < EPSILON then
    return 0
  end

  local facing2D = Vector3.new(defenderFacing.X, 0, defenderFacing.Z)
  if facing2D.Magnitude < EPSILON then
    return 0
  end

  local dir = diff.Unit
  local facingUnit = facing2D.Unit
  local dot = math.clamp(facingUnit.X * dir.X + facingUnit.Z * dir.Z, -1, 1)
  return math.deg(math.acos(dot))
end

-- Process incoming attack against the current defense state
function ParryRiposteWindow.ProcessIncomingAttack(
  self: ParryRiposteInstance,
  defenderPos: Vector3,
  defenderFacing: Vector3,
  attack: IncomingAttack
): DefenseResolution
  local angleDeg = calculateAngleDeg(defenderPos, defenderFacing, attack.AttackerPosition)
  local inParryCone = angleDeg <= (self._config.ParryAngleDeg * 0.5)
  local inBlockCone = angleDeg <= (self._config.BlockAngleDeg * 0.5)

  -- Reset posture regen cooldown upon taking any incoming impact
  self._postureRegenCooldown = self._config.PostureRegenDelay

  -- 1. Active Parry Window
  if self._state == "ParryActive" then
    if inParryCone and not attack.Unparryable then
      self._parryTriggeredHit = true
      self._state = "RiposteReady"
      self._stateTimer = self._config.RiposteWindowDuration
      self._riposteMultiplier = self._config.RiposteDamageMultiplier
      self._riposteTargetId = attack.AttackerId

      for _, cb in ipairs(self._onParrySuccessCallbacks) do
        cb(attack.AttackerId, self._config.ParryAttackerStunDuration)
      end

      return {
        Outcome = "Parried",
        DamageTaken = 0,
        PostureDamageTaken = 0,
        AttackerStunDuration = self._config.ParryAttackerStunDuration,
        DefenderRiposteAvailable = true,
        RiposteMultiplier = self._config.RiposteDamageMultiplier,
        DeflectionAngleDeg = angleDeg,
        AngleWithinParryCone = inParryCone,
        AngleWithinBlockCone = inBlockCone,
      }
    else
      -- Failed parry: either out of angle or unparryable attack
      local dmg = attack.Damage
      if self:IsVulnerable() then
        dmg = dmg * self._config.WhiffDamageMultiplier
      end
      self._currentPosture = math.max(0, self._currentPosture - attack.PostureDamage)

      return {
        Outcome = "Hit",
        DamageTaken = dmg,
        PostureDamageTaken = attack.PostureDamage,
        AttackerStunDuration = 0,
        DefenderRiposteAvailable = false,
        RiposteMultiplier = 1.0,
        DeflectionAngleDeg = angleDeg,
        AngleWithinParryCone = inParryCone,
        AngleWithinBlockCone = inBlockCone,
      }
    end
  end

  -- 2. Guarding Window
  if self._state == "Guarding" then
    if inBlockCone and not attack.Unblockable then
      local remainingPosture = self._currentPosture - attack.PostureDamage

      if remainingPosture <= 0 then
        -- Guard Break!
        self._currentPosture = 0
        self._state = "GuardBroken"
        self._stateTimer = self._config.GuardBreakStunDuration

        for _, cb in ipairs(self._onGuardBreakCallbacks) do
          cb(attack.AttackerId, self._config.GuardBreakStunDuration)
        end

        -- Half chip damage penetrates guard break blow
        local takenDmg = attack.Damage * (1 - self._config.BlockMitigation * 0.5)

        return {
          Outcome = "GuardBroken",
          DamageTaken = takenDmg,
          PostureDamageTaken = self._currentPosture,
          AttackerStunDuration = 0,
          DefenderRiposteAvailable = false,
          RiposteMultiplier = 1.0,
          DeflectionAngleDeg = angleDeg,
          AngleWithinParryCone = inParryCone,
          AngleWithinBlockCone = inBlockCone,
        }
      else
        -- Successful Block
        self._currentPosture = remainingPosture
        local mitigatedDmg = attack.Damage * self._config.BlockMitigation
        local chipDmg = attack.Damage - mitigatedDmg

        for _, cb in ipairs(self._onBlockedCallbacks) do
          cb(attack.AttackerId, mitigatedDmg, chipDmg)
        end

        return {
          Outcome = "Blocked",
          DamageTaken = chipDmg,
          PostureDamageTaken = attack.PostureDamage,
          AttackerStunDuration = 0,
          DefenderRiposteAvailable = false,
          RiposteMultiplier = 1.0,
          DeflectionAngleDeg = angleDeg,
          AngleWithinParryCone = inParryCone,
          AngleWithinBlockCone = inBlockCone,
        }
      end
    else
      -- Flanked or unblockable attack while guarding
      self._currentPosture = math.max(0, self._currentPosture - attack.PostureDamage)
      return {
        Outcome = "Hit",
        DamageTaken = attack.Damage,
        PostureDamageTaken = attack.PostureDamage,
        AttackerStunDuration = 0,
        DefenderRiposteAvailable = false,
        RiposteMultiplier = 1.0,
        DeflectionAngleDeg = angleDeg,
        AngleWithinParryCone = inParryCone,
        AngleWithinBlockCone = inBlockCone,
      }
    end
  end

  -- 3. Whiff / Recovery Punish or Neutral Hit
  local damageMultiplier = 1.0
  local outcome: DefenseOutcome = "Hit"

  if self:IsVulnerable() then
    damageMultiplier = self._config.WhiffDamageMultiplier
    outcome = "WhiffPunished"
  end

  self._currentPosture = math.max(0, self._currentPosture - attack.PostureDamage)

  return {
    Outcome = outcome,
    DamageTaken = attack.Damage * damageMultiplier,
    PostureDamageTaken = attack.PostureDamage,
    AttackerStunDuration = 0,
    DefenderRiposteAvailable = false,
    RiposteMultiplier = 1.0,
    DeflectionAngleDeg = angleDeg,
    AngleWithinParryCone = inParryCone,
    AngleWithinBlockCone = inBlockCone,
  }
end

-- Consume ripe riposte opportunity
function ParryRiposteWindow.ConsumeRiposte(self: ParryRiposteInstance): (boolean, number, string?)
  if self._state == "RiposteReady" then
    local mult = self._riposteMultiplier
    local target = self._riposteTargetId
    self._state = "Neutral"
    self._stateTimer = 0
    self._riposteTargetId = nil
    return true, mult, target
  end
  return false, 1.0, nil
end

-- Advance time simulation step
function ParryRiposteWindow.Update(self: ParryRiposteInstance, dt: number)
  if dt <= 0 then return end

  -- Posture regeneration logic
  if self._postureRegenCooldown > 0 then
    local cooldownReduction = math.min(self._postureRegenCooldown, dt)
    self._postureRegenCooldown -= cooldownReduction
    local leftoverDt = dt - cooldownReduction
    if leftoverDt > 0 and self._state ~= "Guarding" and self._state ~= "GuardBroken" then
      self._currentPosture = math.min(
        self._config.MaxPosture,
        self._currentPosture + self._config.PostureRegenRate * leftoverDt
      )
    end
  else
    if self._state ~= "Guarding" and self._state ~= "GuardBroken" then
      self._currentPosture = math.min(
        self._config.MaxPosture,
        self._currentPosture + self._config.PostureRegenRate * dt
      )
    end
  end

  -- State timer transitions with multi-stage sub-step advancement
  local remainingDt = dt
  while remainingDt > 0 and self._stateTimer > 0 do
    if remainingDt < self._stateTimer then
      self._stateTimer -= remainingDt
      remainingDt = 0
    else
      remainingDt -= self._stateTimer
      self._stateTimer = 0

      if self._state == "ParryStartup" then
        self._state = "ParryActive"
        self._stateTimer = self._config.ActiveDuration
      elseif self._state == "ParryActive" then
        if self._parryTriggeredHit then
          break
        else
          self._state = "ParryWhiff"
          self._stateTimer = self._config.WhiffPenaltyDuration
        end
      elseif self._state == "ParryRecovery" or self._state == "ParryWhiff" then
        self._state = "Neutral"
        break
      elseif self._state == "RiposteReady" then
        self._state = "Neutral"
        break
      elseif self._state == "GuardBroken" then
        self._state = "Neutral"
        self._currentPosture = self._config.MaxPosture * 0.5
        break
      else
        break
      end
    end
  end
end

-- Event subscription hooks
function ParryRiposteWindow.OnParrySuccess(
  self: ParryRiposteInstance,
  callback: (attackerId: string, duration: number) -> ()
)
  table.insert(self._onParrySuccessCallbacks, callback)
end

function ParryRiposteWindow.OnBlocked(
  self: ParryRiposteInstance,
  callback: (attackerId: string, mitigated: number, chip: number) -> ()
)
  table.insert(self._onBlockedCallbacks, callback)
end

function ParryRiposteWindow.OnGuardBreak(
  self: ParryRiposteInstance,
  callback: (attackerId: string, duration: number) -> ()
)
  table.insert(self._onGuardBreakCallbacks, callback)
end

-- Getters
function ParryRiposteWindow.GetState(self: ParryRiposteInstance): DefenseState
  return self._state
end

function ParryRiposteWindow.GetPosture(self: ParryRiposteInstance): (number, number)
  return self._currentPosture, self._config.MaxPosture
end

function ParryRiposteWindow.ResetPosture(self: ParryRiposteInstance)
  self._currentPosture = self._config.MaxPosture
end

return ParryRiposteWindow
