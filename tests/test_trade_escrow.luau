local TradeEscrow = require("../src/ReplicatedStorage/Economy/TradeEscrow")

-- Test 1: Initialization
local escrow = TradeEscrow.new("sess_1001", "player_alice", "player_bob", {
  countdownDuration = 2.0,
  maxItemsPerParty = 4,
  maxCurrency = 50000,
})

assert(escrow.State == "Negotiating", "Initial state must be Negotiating")
assert(escrow.SessionId == "sess_1001", "Session ID mismatch")
assert(escrow.Party1Offer.currency == 0, "Initial currency must be 0")

-- Test 2: Adding & Removing Items and Currency
local okAdd1, errAdd1 = escrow:AddItem("player_alice", {
  id = "sword_mithril",
  name = "Mithril Longsword",
  quantity = 1,
})
assert(okAdd1 == true and errAdd1 == nil, "Failed to add item for alice")

-- Stack item
local okAdd2 = escrow:AddItem("player_alice", {
  id = "sword_mithril",
  name = "Mithril Longsword",
  quantity = 2,
})
assert(okAdd2 == true, "Stacking item should succeed")
assert(#escrow.Party1Offer.items == 1, "Item count should remain 1 due to stacking")
assert(escrow.Party1Offer.items[1].quantity == 3, "Stacked quantity should be 3")

-- Add item for bob
escrow:AddItem("player_bob", {
  id = "shield_aegis",
  name = "Aegis Shield",
  quantity = 1,
})
escrow:SetCurrency("player_bob", 1500)

assert(#escrow.Party2Offer.items == 1, "Bob should have 1 item")
assert(escrow.Party2Offer.currency == 1500, "Bob currency should be 1500")

-- Remove partial item
local okRem = escrow:RemoveItem("player_alice", "sword_mithril", 1)
assert(okRem == true, "Partial removal should succeed")
assert(escrow.Party1Offer.items[1].quantity == 2, "Alice item quantity should now be 2")

-- Test 3: Lock Progression
assert(escrow.State == "Negotiating", "State must be Negotiating before locking")
escrow:LockOffer("player_alice")
assert(escrow.Party1Offer.isLocked == true, "Alice offer must be locked")
assert(escrow.State == "Negotiating", "State must remain Negotiating until both lock")

escrow:LockOffer("player_bob")
assert(escrow.Party2Offer.isLocked == true, "Bob offer must be locked")
assert(escrow.State == "Locked", "State must transition to Locked once both parties lock")

-- Test 4: Anti-Scam Lock Revocation
-- If Alice adds an item while Locked, locks must be instantly revoked!
escrow:AddItem("player_alice", {
  id = "potion_healing",
  name = "Greater Healing Potion",
  quantity = 5,
})
assert(escrow.State == "Negotiating", "Adding item must revoke locks and reset state to Negotiating")
assert(escrow.Party1Offer.isLocked == false, "Alice lock must be revoked")
assert(escrow.Party2Offer.isLocked == false, "Bob lock must be revoked")

-- Re-lock both
escrow:LockOffer("player_alice")
escrow:LockOffer("player_bob")
assert(escrow.State == "Locked", "Must return to Locked state")

-- Test 5: Confirmation & Countdown
escrow:ConfirmTrade("player_alice")
assert(escrow.Party1Offer.isConfirmed == true, "Alice should be confirmed")
assert(escrow.State == "Locked", "Must remain Locked until both confirm")

escrow:ConfirmTrade("player_bob")
assert(escrow.Party2Offer.isConfirmed == true, "Bob should be confirmed")
assert(escrow.State == "CountingDown", "Must transition to CountingDown once both confirm")

-- Test 6: Countdown Step & Commit
escrow:StepCountdown(1.0)
assert(escrow.State == "CountingDown", "Should still be counting down after 1s")
assert(math.abs(escrow.CountdownRemaining - 1.0) < 1e-3, "Countdown remaining should be 1s")

-- Step past completion
local okFinal = escrow:StepCountdown(1.5)
assert(okFinal == true, "Final countdown step should commit trade")
assert(escrow.State == "Committed", "Trade state must be Committed")

-- Test 7: Audit Receipt Verification
local receipt = escrow:GetReceipt()
assert(receipt.sessionId == "sess_1001", "Receipt sessionId mismatch")
assert(receipt.status == "Committed", "Receipt status should be Committed")
assert(#receipt.party1Manifest.items == 2, "Alice should have 2 items in manifest")
assert(#receipt.party2Manifest.items == 1, "Bob should have 1 item in manifest")
assert(receipt.party2Manifest.currency == 1500, "Bob currency should be recorded in manifest")

-- Test 8: onCommit Rollback Protection
local rollbackEscrow = TradeEscrow.new("sess_1002", "alice", "bob", {
  countdownDuration = 1.0,
  onCommit = function(p1, o1, p2, o2)
    -- Simulate inventory verification failure
    return false, "Insufficient inventory balance on database check"
  end,
})

rollbackEscrow:LockOffer("alice")
rollbackEscrow:LockOffer("bob")
rollbackEscrow:ConfirmTrade("alice")
rollbackEscrow:ConfirmTrade("bob")
rollbackEscrow:StepCountdown(1.5)

assert(rollbackEscrow.State == "Cancelled", "Failed onCommit must cancel trade")
assert(rollbackEscrow.CancelReason == "Insufficient inventory balance on database check", "Cancel reason mismatch")

-- Test 9: Explicit Manual Cancellation
local cancelEscrow = TradeEscrow.new("sess_1003", "alice", "bob")
cancelEscrow:Cancel("alice", "User declined proposal terms")
assert(cancelEscrow.State == "Cancelled", "State must be Cancelled")
assert(cancelEscrow.CancelReason == "User declined proposal terms", "Cancel reason mismatch")

print("PASS: TradeEscrow tests (Init, Add/Remove, AntiScam, Locks, Confirm, Countdown, Commit, Rollback, Receipts) passed cleanly!")
