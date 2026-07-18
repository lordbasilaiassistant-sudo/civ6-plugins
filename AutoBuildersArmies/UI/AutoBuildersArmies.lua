-- ===========================================================================
--  Auto Builders & Armies
--  Single-player QoL automation for the LOCAL human player's units.
--
--  Runs entirely in the InGame UI Lua context and issues orders the same way
--  the game's own UI does (UnitManager.RequestOperation), which only works for
--  the local human player -- so this cannot and does not touch AI civs, and it
--  hard-disables itself in multiplayer.
--
--  Design notes (why it is shaped this way):
--   * RequestOperation is ASYNC. Orders queue and resolve over frames/turns, so
--     a naive re-scan re-issues the same order dozens of times a second. We
--     debounce with a per-turn "tasked" set (cleared on LocalPlayerTurnBegin)
--     and coalesce all completion events into one pass via
--     GameCoreEventPublishComplete.
--   * One order per unit per turn. Simple, safe, matches proven prior art
--     (Automated Builders). A builder relocates one turn and builds the next.
--   * Every order is gated by CanStartOperation first; nothing is issued unless
--     it is genuinely the local player's turn and the game is not mid-playback.
-- ===========================================================================

-- ------------------------------------------------------------------ state ---
-- Defaults are ON across the board: the point of this mod is that the game plays
-- itself unless you say otherwise. Advance included -- you are always at war with
-- barbarians, so units that only ever fortify would leave camps standing forever.
-- Advance still only steps onto tiles it judges safe, and wounded units heal
-- first, so "aggressive" is not the same as "suicidal".
local g_master   = true    -- master switch
local g_builders = true    -- automate builders
local g_armies   = true    -- automate military
local g_advance  = true    -- march on the nearest known enemy (incl. barbarians)
local g_research = true    -- auto-pick research + civics from the game's own AI
local g_produce  = true    -- auto-pick city production from the game's own AI

local g_tasked      = {}    -- [unitID]=true, units already handled this turn
local g_cityOrdered = {}    -- [cityID]=true, cities given production this turn.
                            -- Needed for the same reason as g_tasked: BUILD
                            -- requests are async, so without this one idle city
                            -- got the same order re-issued every pass (observed
                            -- live: Hanging Gardens x3 in one turn).
local g_promoted    = {}    -- [unitID]=true, promoted this turn. RequestCommand is
                            -- async like everything else, so without this the same
                            -- unit gets promoted repeatedly against a stale
                            -- "promotion available" read.
local g_retasks     = {}    -- [unitID]=count of re-tasks this turn. A unit whose
                            -- operation completes with moves left gets its g_tasked
                            -- cleared so it can act again (see
                            -- OnUnitOperationSegmentComplete) -- capped, because an
                            -- order the engine accepts-then-drops would otherwise
                            -- re-issue forever within one turn.
local g_pantheonDone  = false -- pantheon requested this turn (async; see g_envoyDone)
local g_religionDone  = false -- religion founding requested this turn (async)
local g_gpDone        = false -- great-person recruit requested this turn (async)
local g_inflight    = {}    -- [unitID]=true, an order is ISSUED but not yet resolved.
                            -- The keystone debounce (issue #3): every Request* is
                            -- async, and a queued SKIP/FORTIFY/FOUND_CITY has no
                            -- destination, so without this flag a mid-flight unit
                            -- still reads "idle" to the next pass -- which then
                            -- re-enters it, finds every CanStart refused (an op IS
                            -- queued), and reports a spurious STUCK. Set by
                            -- IssueOp/IssueCmd, cleared on resolution + turn begin.
local g_claims      = {}    -- [plotIndex]=unitID, movement destinations claimed this
                            -- turn -- two units electing one tile = second refused.
local g_woken       = {}    -- [unitID]=true, woken by the fortified-wake branch this
                            -- turn. That branch bypasses the idle filter by design,
                            -- so it needs its own once-per-turn debounce (a warrior
                            -- was re-woken 21 times in one session without it).
local g_builderShortTurns = 0        -- consecutive turns of builder shortage (#5:
                                     -- hire only when it persists, not on the turn
                                     -- a builder just died).
local g_builderIdleLastTurn = false  -- a builder with charges found no work last turn.
local g_builderIdleThisTurn = false  -- Composition must not queue ANOTHER builder while
                                     -- one is already unemployed (issue #5: builders
                                     -- stacked up at cities). Last/this pair because
                                     -- production decides BEFORE builders sweep.
local g_plotSkip    = {}    -- [plotIndex]=expiry turn. A plot where a builder stood
                            -- and found NOTHING legal to build (tech not in yet --
                            -- issue #9) is excluded from the scan for a few turns so
                            -- the builder moves on instead of re-picking it forever.
local g_defcity     = nil   -- {x,y,name,dist} set each pass: the own city with an
                            -- enemy within CITY_DEFENSE_RADIUS (nil = all safe).
                            -- Read by the combat brain (defense mode) and by
                            -- CompositionVetoes (no settlers while under attack).
local g_defLogName, g_defLogDist = nil, nil  -- last logged threat (log on change only)
local g_declines    = {}    -- [unitID]=count of no-order outcomes this turn. The
                            -- units-blocker clears g_tasked to force re-sweeps, so a
                            -- unit the engine refuses everything for was re-brained
                            -- and re-logged every pass all turn (524289/786438 live).
                            -- Two strikes -> hand it straight to the catch-all.
local g_rallyStuck  = {}    -- [unitID]={x,y,n,holdUntil}: rally attempts issued from
                            -- an unchanged position. 3 strikes -> the rally target is
                            -- unreachable from here (#24: warrior skipped 23 turns);
                            -- hold in place ~10 turns before trying again. Survives
                            -- across turns on purpose.
local g_refused     = {}    -- [unitID]=count of consecutive all-ops-refused passes.
                            -- Newly trained units refuse everything for one event
                            -- beat then accept (issue #10) -- only the SECOND
                            -- consecutive refusal is a real stuck worth shouting.
local g_districtNoPlot = {}   -- ["cityID:hash"]=true, district had no legal plot this
                              -- turn; excluded from recs so the city falls through to
                              -- its next-best option instead of retrying every pass.
local g_envoyDone   = false -- envoys dumped this turn. GetTokensToGive does not
                            -- update until the async op lands, so a second pass in
                            -- the same turn would spend tokens we no longer have.
local g_gpNeedSlot = nil    -- GreatWorkObjectType a claimed GP is waiting on
                            -- (#27, live: Machiavelli with no writing slot
                            -- anywhere). Production queues the cheapest
                            -- slot-providing building; cleared when ordered.
local g_upgraded  = {}      -- [unitID]=true, upgrade requested this turn (async, #30)
local g_upgradeCount = 0    -- upgrades issued this turn (budget cap)
local g_cityBought = {}     -- [cityID]=true, emergency gold-buy issued this turn.
                            -- PURCHASE is async and CanStartCommand stays true
                            -- until it lands -- a re-pass double-fired = double
                            -- gold spend (audit #12). Reset ONLY at TurnBegin.
local g_researchDone = false -- research/civic requested this turn (async, like
local g_civicDone    = false -- g_envoyDone); re-armed by their blockers.
local g_envoyLastTokens = -1 -- token count at our last envoy volley: the getter
                             -- is stale until the async ops land, so the same
                             -- count re-appearing means "still processing",
                             -- not "new tokens" (audit #29).
local g_blkLogged = {}      -- [blockerName]=fires this turn (log dedupe #33)
local g_struck    = {}      -- ["c<id>"/"d<id>"]=true, city/district strike fired this
                            -- turn (#29). CanStartCommand goes false only when the
                            -- async request RESOLVES, so a same-pass re-ask would
                            -- double-fire without this.
local g_logOnce   = {}      -- [key]=true, log lines already emitted this turn (#33:
                            -- the pass runs on every PublishComplete, so any per-pass
                            -- Log with no debounce prints hundreds of copies -- live:
                            -- "builder SKIPPED" x375 in one session).
local g_gpStrikes = {}      -- [unitID]=consecutive on-plot activation refusals (#27).
                            -- Persists across turns on purpose; cleared on activation
                            -- and when any city finishes a build (new great-work
                            -- slots arrive with buildings).
local g_builderShortStampTurn = -1  -- last turn CompositionWant counted the builder
                                    -- shortage. The "2 consecutive turns" hiring guard
                                    -- incremented per CALL, and the function runs per
                                    -- city per pass -- so it fired the same turn (#28).
local g_dirty     = false   -- a pass is requested
local g_collapsed = false

-- Attack target ("all armies go there").
--   g_candidate : the enemy city you most recently clicked on the map.
--   g_target    : the committed objective; set by pressing ATTACK.
-- Kept separate so clicking a city never *itself* starts a war march -- you
-- always confirm with the button.
local g_candidate = nil    -- {x,y,name,owner}
local g_target    = nil    -- {x,y,name,owner}

-- Committed settling site per settler ([unitID] = {x,y}). Persists across turns
-- on purpose: site recommendations shift every turn as scouts reveal the map,
-- and re-choosing each turn made settlers chase moving targets instead of
-- founding (observed: 58,41 -> 59,40 re-paths, then captured by barbarians).
local g_settlerPlan = {}

-- Diagnostics. print() lands in Lua.log prefixed with this context's name, and
-- costs nothing when nothing is happening. Left ON deliberately: this mod issues
-- orders on your behalf, so when it does something surprising the log should say
-- why without needing a rebuild.
local function Log(fmt, ...)
	local ok, s = pcall(string.format, fmt, ...);
	print("[ABA] " .. (ok and s or tostring(fmt)));
end

-- Once-per-turn logging (#33). Same line, same turn -> printed once. The key is
-- the caller's choice: include the unit id and the REASON, so a changed reason
-- still prints. g_logOnce clears at TurnBegin.
local function LogOnce(key, fmt, ...)
	if g_logOnce[key] then return end
	g_logOnce[key] = true;
	Log(fmt, ...);
end

-- Every event handler goes through Safe(). Rationale learned the hard way: an
-- unguarded handler throws a bare "Runtime Error: <file>:<line>" with no
-- traceback, and those line numbers are useless the moment the file is edited.
-- Wrapping each handler by NAME means the log says which handler broke and why,
-- and one bad handler can never take down the rest of the mod.
local g_errCount = {};   -- [name] = times reported, so a hot handler can't flood the log

-- HavokScript is Lua 5.1, so the global is `unpack`, not `table.unpack`. Resolve
-- it ONCE here: writing `table.unpack and table.unpack(a) or unpack(a)` inline
-- looks equivalent but silently re-unpacks whenever the first arg is nil/false.
local g_unpack = table.unpack or unpack;

local function Safe(name, fn)
	return function(...)
		local args  = {...};
		local nargs = select("#", ...);
		local ok, err = xpcall(
			function() return fn(g_unpack(args, 1, nargs)) end,
			function(e)
				local tb = "";
				if debug ~= nil and debug.traceback ~= nil then
					local okT, t = pcall(debug.traceback, tostring(e), 2);
					if okT then tb = t end
				end
				return (tb ~= "" and tb) or tostring(e);
			end);
		if not ok then
			local n = (g_errCount[name] or 0) + 1;
			g_errCount[name] = n;
			if n <= 3 then
				Log("HANDLER FAILED [%s]: %s", name, tostring(err));
				if n == 3 then Log("[%s] further errors suppressed", name) end
			end
		end
		return nil;
	end;
end

-- ------------------------------------------------ hot-reload lifecycle ------
--
-- This build hot-reloads mod Lua on file change (DebugHotloadCache). That is
-- the LIVE-PATCH channel (#34): a validated file atomically renamed over the
-- installed copy applies mid-game, no restart. Two rules make it safe, both
-- learned from the base game's own files:
--   * The engine does NOT detach Events handlers when a context reloads --
--     old closures dangle and keep firing (Firaxis's own comment,
--     PlotToolTip.lua:962). So every subscription goes through Sub() below,
--     and OnShutdown removes them all before the new instance wires in.
--   * State survives via the always-on DebugHotloadCache context
--     (LuaEvents.GameDebug_AddValue / GetValues / Return -- CityPanel.lua:
--     737-793 is the canonical save/restore pair). Data only, no functions.
local RELOAD_CACHE_ID = "AutoBuildersArmies";
local g_eventSubs = {};   -- { {ev=<event>, fn=<wrapped handler>}, ... }

local function Sub(ev, name, fn)
	local wrapped = Safe(name, fn);
	g_eventSubs[#g_eventSubs + 1] = { ev = ev, fn = wrapped };
	ev.Add(wrapped);
end

local KEY_MASTER   = "ABA_MASTER"
local KEY_BUILDERS = "ABA_BUILDERS"
local KEY_ARMIES   = "ABA_ARMIES"
local KEY_ADVANCE  = "ABA_ADVANCE"
local KEY_RESEARCH = "ABA_RESEARCH"
local KEY_PRODUCE  = "ABA_PRODUCE"

-- ABGR colors
local COL_ON   = 0xFF6BFF6B
local COL_OFF  = 0xFF8A8A8A
local COL_WARN = 0xFF3BA9FF

local HEAL_HP_THRESHOLD = 60   -- heal when below this HP%
local MELEE_STR_MARGIN  = 3    -- attack if our strength >= enemy strength - this

-- City-defense doctrine (Anthony, 2026-07-17: "gotta defend cities first and
-- foremost"). An enemy near an own city flips every nearby soldier into
-- defense mode: cohesion rallies and settler escorts are suspended, near-even
-- fights are accepted (the city's ranged strike + our fortify bonus tip them),
-- and everyone not in contact converges on the city instead of the muster.
local CITY_DEFENSE_RADIUS = 3  -- enemy this close to an own city = city threatened
local CITY_DEFENDER_PULL  = 8  -- soldiers this close to the threatened city defend it
local DEFENSE_STR_MARGIN  = 10 -- extra melee margin while defending (accept near-even)
local BUILDER_FLEE_DIST   = 2  -- builders run home at this threat range (they die in place otherwise)
local MELEE_WOUNDED_HP  = 40   -- ...or if the enemy is at/below this HP%

-- ---------------------------------------------------------------- helpers ---

-- Guarded CanStartOperation wrapper. The nil-op guard is not paranoia: an
-- operation constant that the database never defined reads as nil, and passing
-- nil through to CanStartOperation throws -- which used to kill the whole sweep
-- (and every unit after it) on one missing op.
local function CanStart(pUnit, op, tParams)
	if pUnit == nil or op == nil then return false end
	local ok, res;
	if tParams ~= nil then
		ok, res = pcall(function() return UnitManager.CanStartOperation(pUnit, op, nil, tParams); end);
	else
		ok, res = pcall(function() return UnitManager.CanStartOperation(pUnit, op, nil, false, false); end);
	end
	-- Truthiness, not `== true`: the game's own callers do `if (CanStartOperation(...))`,
	-- so mirror that rather than betting the whole mod on the return being a strict boolean.
	return ok and not not res;
end

-- UnitOperationTypes is filled from the database, so resolve defensively rather
-- than trusting a constant to exist. Verified present in
-- Gameplay/Data/UnitOperations.xml: SLEEP:44, SKIP_TURN:43, FORTIFY:19.
local function ResolveOp(constant, typeName)
	if constant ~= nil then return constant end
	local row = GameInfo.UnitOperations[typeName];
	return (row ~= nil) and row.Hash or nil;
end

-- The ONLY way this mod issues unit orders. Marks the unit in-flight so no pass
-- touches it again until the engine reports the order resolved -- issuing
-- through UnitManager directly reintroduces the async race that produced every
-- spurious STUCK line of the first live session (issue #3).
local function IssueOp(pUnit, op, tParams)
	g_inflight[pUnit:GetID()] = true;
	g_refused[pUnit:GetID()]  = nil;   -- an accepted order resets the refusal streak
	if tParams ~= nil then
		UnitManager.RequestOperation(pUnit, op, tParams);
	else
		UnitManager.RequestOperation(pUnit, op);
	end
end

local function IssueCmd(pUnit, cmd, tParams)
	g_inflight[pUnit:GetID()] = true;
	UnitManager.RequestCommand(pUnit, cmd, tParams);
end

-- Why is this unit NOT idle? Returns nil when it IS idle and awaiting orders.
-- Returning the reason (rather than a bare boolean) is what makes "my builder
-- just sits there" diagnosable from the log instead of guessable.
local function IdleReason(pUnit)
	if pUnit == nil then return "nil-unit" end
	if pUnit:IsDead() then return "dead" end
	if g_inflight[pUnit:GetID()] then return "order-in-flight" end
	if not pUnit:IsReadyToMove() then return "not-ready-to-move" end
	if pUnit:GetMovesRemaining() <= 0 then return "no-moves-left" end
	local ok, act = pcall(function() return UnitManager.GetActivityType(pUnit) end);
	if not ok then return "activity-call-failed" end
	if act ~= ActivityTypes.ACTIVITY_AWAKE then return "activity=" .. tostring(act) .. " (not AWAKE)" end
	if UnitManager.GetQueuedDestination(pUnit) ~= nil then return "already-has-queued-destination" end
	return nil;
end

local function IsIdle(pUnit)
	return IdleReason(pUnit) == nil;
end

local function IsBuilder(pUnit)
	local info = GameInfo.Units[pUnit:GetUnitType()];
	if info == nil then return false end
	if (info.BuildCharges or 0) <= 0 then return false end
	return pUnit:GetBuildCharges() > 0;
end

-- --------------------------------------------------------- threat picture ---
--
-- One scan per pass: every VISIBLE unit of every player we are at war with,
-- barbarians included (player 63 -- pid loop must reach 63, the barb slot).
-- Everything defensive keys off this: settlers flee it, fortified units wake
-- for it, threatened cities build against it. Declared ABOVE ScoutRetreat and
-- friends on purpose -- Lua resolves locals by declaration order, and a
-- later-declared local silently compiles to a nil global instead.

local function BuildThreatCache(eLocalPlayer, pDiplo, pVis)
	local t = {};
	for pid = 0, 63 do
		local p = Players[pid];
		if p ~= nil and pid ~= eLocalPlayer and p:IsAlive() and pDiplo:IsAtWarWith(pid) then
			local ok, units = pcall(function() return p:GetUnits(); end);
			if ok and units ~= nil then
				for _, u in units:Members() do
					if not u:IsDead() and pVis:IsUnitVisible(u) then
						-- Domain tag (Anthony: "warriors can't fire on boats"):
						-- sea threats are unactionable for melee and must not
						-- drive their wake/defense loops.
						local ui = GameInfo.Units[u:GetUnitType()];
						t[#t + 1] = { x = u:GetX(), y = u:GetY(),
							sea = (ui ~= nil and ui.Domain == "DOMAIN_SEA") };
					end
				end
			end
		end
	end
	return t;
end

-- Distance from (x,y) to the nearest visible threat; nil if none visible.
-- landOnly=true ignores sea threats -- melee units can't touch boats, so a
-- barb galley offshore must not drive their wake/stand/flee behavior.
local function NearestThreatDist(threats, x, y, landOnly)
	local best = nil;
	for _, th in ipairs(threats) do
		if not (landOnly and th.sea) then
			local d = Map.GetPlotDistance(x, y, th.x, th.y);
			if best == nil or d < best then best = d end
		end
	end
	return best;
end

local function MoveTo(pUnit, x, y)
	local tParams = {
		[UnitOperationTypes.PARAM_X] = x,
		[UnitOperationTypes.PARAM_Y] = y,
		[UnitOperationTypes.PARAM_MODIFIERS] = UnitOperationMoveModifiers.NONE,
	};
	-- Destination claims (issue #13 root, verified on land map): two units
	-- electing the same tile means the second MOVE_TO is refused (occupied or
	-- about to be). One claim per destination per turn; reset at TurnBegin.
	local claimKey = Map.GetPlotIndex(x, y);
	if g_claims[claimKey] ~= nil and g_claims[claimKey] ~= pUnit:GetID() then
		return false;
	end
	if CanStart(pUnit, UnitOperationTypes.MOVE_TO, tParams) then
		g_claims[claimKey] = pUnit:GetID();
		IssueOp(pUnit,UnitOperationTypes.MOVE_TO, tParams);
		return true;
	end
	-- Retry WITHOUT the modifiers key (issue #13): every civilian MOVE_TO was
	-- refused on the fjord-heavy Norway map while warriors moved fine -- the
	-- MODIFIERS=NONE param is the prime suspect for refusing embark legs.
	-- Dropping a param cannot invent API; the engine defaults it.
	local tBare = {
		[UnitOperationTypes.PARAM_X] = x,
		[UnitOperationTypes.PARAM_Y] = y,
	};
	if CanStart(pUnit, UnitOperationTypes.MOVE_TO, tBare) then
		g_claims[claimKey] = pUnit:GetID();   -- audit #3: this accept path claimed nothing
		IssueOp(pUnit,UnitOperationTypes.MOVE_TO, tBare);
		Log("unit %d: MOVE_TO %d,%d accepted only without modifiers", pUnit:GetID(), x, y);
		return true;
	end
	-- PATH-LEG FALLBACK (issue #13, the fix): five sessions of evidence say
	-- this engine refuses MOVE_TO for far destinations even with a valid
	-- GetMoveToPathEx path (land maps, no occupancy, no modifiers -- all ruled
	-- out; warriors' one-tile step-outs always worked). So walk the path one
	-- reachable leg per turn: intersect the path with GetReachableMovement and
	-- move to the furthest path plot reachable NOW.
	-- GREEDY-LEG FALLBACK (issue #13 v2): the path-based leg walk never engaged
	-- -- pathInfo.plots' element format was an unverified assumption. This
	-- version assumes NOTHING about paths: step to whichever reachable-now
	-- plot is closest to the target. GetReachableMovement's index format is
	-- proven (ScoutRetreat and step-out both use it live).
	local okR, reach = pcall(function() return UnitManager.GetReachableMovement(pUnit); end);
	if okR and reach ~= nil then
		local ux, uy = pUnit:GetX(), pUnit:GetY();
		local best, bestD = nil, Map.GetPlotDistance(ux, uy, x, y);
		for _, idx in ipairs(reach) do
			local p = Map.GetPlotByIndex(idx);
			if p ~= nil and g_claims[idx] == nil and not (p:GetX() == ux and p:GetY() == uy) then
				local d = Map.GetPlotDistance(p:GetX(), p:GetY(), x, y);
				if d < bestD then bestD, best = d, p end
			end
		end
		if best ~= nil then
			local tLeg = {
				[UnitOperationTypes.PARAM_X] = best:GetX(),
				[UnitOperationTypes.PARAM_Y] = best:GetY(),
			};
			if CanStart(pUnit, UnitOperationTypes.MOVE_TO, tLeg) then
				g_claims[best:GetIndex()] = pUnit:GetID();
				IssueOp(pUnit,UnitOperationTypes.MOVE_TO, tLeg);
				Log("unit %d: far move refused; greedy leg to %d,%d (toward %d,%d)",
					pUnit:GetID(), best:GetX(), best:GetY(), x, y);
				return true;
			end
		end
	end
	return false;
end

local function NearestOwnCityPlot(pPlayer, x, y)
	local best, bestD = nil, 9999;
	local ok, cities = pcall(function() return pPlayer:GetCities(); end);
	if not ok or cities == nil then return nil end
	for _, c in cities:Members() do
		local d = Map.GetPlotDistance(x, y, c:GetX(), c:GetY());
		if d < bestD then bestD = d; best = Map.GetPlot(c:GetX(), c:GetY()) end
	end
	return best;
end

-- ------------------------------------------------------------ the catch-all --
--
-- THE "things get stuck" FIX, and the single most important function in here.
--
-- Every branch below can decline. The engine refuses an operation (re-automating
-- a scout that is in contact with an enemy is the classic, and was the live
-- repro); a class no branch claims turns up (support, religious, great people,
-- traders); a committed path evaporates. Before this existed, those units were
-- still marked handled and then simply left AWAKE -- and AWAKE-with-moves is
-- precisely what the game means by UNIT NEEDS ORDERS. The turn then will not end
-- until a human clicks the unit. That is the whole "things get stuck often" bug:
-- not a crash, not a bad order, just an order that was never issued at all.
--
-- The invariant from here on: NOTHING leaves the sweep without either a real
-- order or this fallback. No silent declines.
--
-- SKIP vs SLEEP is a real distinction, not a coin flip:
--   * retryNextTurn=true -> SKIP_TURN. Clears the block for this turn only, so a
--     unit we still want to automate (a scout waiting for a barbarian to wander
--     off) is reconsidered next turn.
--   * retryNextTurn=false -> SLEEP. For a class we have NO automation for: it
--     stops blocking every turn forever instead of re-asking us each time.
-- Either way it logs LOUDLY -- those log lines are the to-do list for whatever
-- should be automated next, which is exactly how the last three root causes
-- were found in minutes each.
local function EnsureOrdered(pUnit, why, retryNextTurn)
	if pUnit == nil then return false end
	local id    = pUnit:GetID();
	local info  = GameInfo.Units[pUnit:GetUnitType()];
	local uType = (info ~= nil) and info.UnitType or "?";

	local opSkip    = ResolveOp(UnitOperationTypes.SKIP_TURN, "UNITOPERATION_SKIP_TURN");
	local opSleep   = ResolveOp(UnitOperationTypes.SLEEP,     "UNITOPERATION_SLEEP");
	local opFortify = ResolveOp(UnitOperationTypes.FORTIFY,   "UNITOPERATION_FORTIFY");

	if retryNextTurn and CanStart(pUnit, opSkip) then
		IssueOp(pUnit,opSkip);
		LogOnce("unstuck:" .. id, "UNSTUCK %s %d: %s -> skip (retry next turn)", uType, id, why);
		return true;
	end
	if CanStart(pUnit, opFortify) then
		IssueOp(pUnit,opFortify);
		LogOnce("unstuck:" .. id, "UNSTUCK %s %d: %s -> fortify", uType, id, why);
		return true;
	end
	if CanStart(pUnit, opSleep) then
		IssueOp(pUnit,opSleep);
		LogOnce("unstuck:" .. id, "UNSTUCK %s %d: %s -> sleep (NO AUTOMATION FOR THIS CLASS -- automate it next)", uType, id, why);
		return true;
	end
	if CanStart(pUnit, opSkip) then
		IssueOp(pUnit,opSkip);
		LogOnce("unstuck:" .. id, "UNSTUCK %s %d: %s -> skip", uType, id, why);
		return true;
	end
	-- Deep-wedge levers (issue #14, warrior 131073 live): a unit the engine
	-- wakes next to an adjacent enemy can refuse skip/fortify/sleep ALL AT
	-- ONCE. Two things stay legal in that state: ALERT, and simply WALKING --
	-- movement in zone-of-control is always allowed. Step toward home.
	local opAlert = ResolveOp(UnitOperationTypes.ALERT, "UNITOPERATION_ALERT");
	if CanStart(pUnit, opAlert) then
		IssueOp(pUnit,opAlert);
		Log("UNSTUCK %s %d: %s -> alert", uType, id, why);
		return true;
	end
	-- Step-out stays available for great people (reversed 2026-07-18 evening,
	-- live: Machiavelli refused skip AND fortify AND sleep AND alert -- with
	-- the GP exemption in place there was NO lever left and the turn blocked
	-- until Anthony clicked skip by hand). Walking one tile off an activation
	-- plot costs a turn of walking back; blocking END TURN costs the whole
	-- game. The slot-census sleep upstream makes this genuinely last-resort.
	local pPlayer = Players[Game.GetLocalPlayer()];
	if pPlayer ~= nil then
		local ux, uy = pUnit:GetX(), pUnit:GetY();
		local okR, reach = pcall(function() return UnitManager.GetReachableMovement(pUnit); end);
		if okR and reach ~= nil then
			local home = NearestOwnCityPlot(pPlayer, ux, uy);
			local best, bestD = nil, 9999;
			for _, idx in ipairs(reach) do
				local plot = Map.GetPlotByIndex(idx);
				if plot ~= nil and not (plot:GetX() == ux and plot:GetY() == uy) then
					local d = (home ~= nil)
						and Map.GetPlotDistance(plot:GetX(), plot:GetY(), home:GetX(), home:GetY()) or 0;
					if d < bestD then bestD, best = d, plot end
				end
			end
			if best ~= nil and MoveTo(pUnit, best:GetX(), best:GetY()) then
				Log("UNSTUCK %s %d: %s -> stepping out to %d,%d", uType, id, why, best:GetX(), best:GetY());
				return true;
			end
		end
	end
	-- All ops refused. First time is usually the newly-trained-unit beat -- the
	-- engine refuses everything for one event cycle then accepts (observed
	-- live, issue #10) -- so shout only on the SECOND consecutive refusal.
	local n = (g_refused[id] or 0) + 1;
	g_refused[id] = n;
	if n == 1 then
		Log("unit %s %d: %s -- ops refused once (likely spawn-beat; retrying)", uType, id, why);
	elseif n == 2 then
		Log("STUCK %s %d: %s -- every fallback op refused twice; this unit WILL block the turn", uType, id, why);
	end
	return false;
end

-- ------------------------------------------------------------- promotions ---
--
-- A pending promotion blocks END TURN all by itself, and it is the most frequent
-- turn-blocker there is. Critically, this must NOT be gated behind the idle
-- test: a unit that earned a promotion is usually one that just fought and then
-- FORTIFIED, and a fortified unit does not read as AWAKE -- so checking
-- promotions only for idle units would miss exactly the units that block turns.
--
-- Verified API (UI/Popups/UnitPromotionPopup.lua):
--   :81     local bCanStart, tResults = UnitManager.CanStartCommand(pUnit, UnitCommandTypes.PROMOTE, true, true)
--   :82     tResults[UnitCommandResults.PROMOTIONS] -> 1-based array of promotion ids
--   :70-72  tParameters[UnitCommandTypes.PARAM_PROMOTION_TYPE] = ePromotion
--           UnitManager.RequestCommand(pUnit, UnitCommandTypes.PROMOTE, tParameters)
-- The array element is used AS-IS both for GameInfo.UnitPromotions[item] and for
-- PARAM_PROMOTION_TYPE -- same value throughout (UnitPanel.lua:2660-2683).
local function TryPromote(pUnit)
	if pUnit == nil then return false end
	local id = pUnit:GetID();
	if g_promoted[id] then return false end

	local ok, bCanStart, tResults = pcall(function()
		return UnitManager.CanStartCommand(pUnit, UnitCommandTypes.PROMOTE, true, true);
	end);
	if not ok or not bCanStart or tResults == nil then return false end

	local list = tResults[UnitCommandResults.PROMOTIONS];
	if list == nil or #list == 0 then return false end

	-- Ranked choice (issue #6). Names verified in UnitPromotions.xml:186-221.
	-- Survivability first for the front line, damage first for ranged; anything
	-- unlisted falls back to first-offered -- promoting NOW also heals 50 HP
	-- (EXPERIENCE_PROMOTE_HEALED, GlobalParameters.xml:304), so never defer.
	local PROMO_PREF = {
		PROMOTION_BATTLECRY = 1, PROMOTION_TORTOISE  = 2,   -- melee L1
		PROMOTION_COMMANDO  = 3, PROMOTION_AMPHIBIOUS = 4,  -- melee L2
		PROMOTION_VOLLEY    = 1, PROMOTION_GARRISON  = 2,   -- ranged L1
		PROMOTION_ARROW_STORM = 3, PROMOTION_INCENDIARIES = 4,
		PROMOTION_RANGER    = 1, PROMOTION_ALPINE    = 2,   -- recon L1
		PROMOTION_SENTRY    = 3, PROMOTION_GUERRILLA = 4,
		PROMOTION_ECHELON   = 1, PROMOTION_THRUST    = 2,   -- anti-cav L1
		PROMOTION_SQUARE    = 3, PROMOTION_SCHILTRON = 4,
	};
	local ePromotion, bestRank = list[1], nil;
	for _, item in ipairs(list) do
		local info = GameInfo.UnitPromotions[item];
		local rank = (info ~= nil) and PROMO_PREF[info.UnitPromotionType] or nil;
		if rank ~= nil and (bestRank == nil or rank < bestRank) then
			bestRank, ePromotion = rank, item;
		end
	end
	local tParameters = {};
	tParameters[UnitCommandTypes.PARAM_PROMOTION_TYPE] = ePromotion;
	IssueCmd(pUnit, UnitCommandTypes.PROMOTE, tParameters);
	g_promoted[id] = true;

	local info = GameInfo.UnitPromotions[ePromotion];
	Log("promote unit %d -> %s (%d offered)", id,
		(info ~= nil and info.UnitPromotionType) or tostring(ePromotion), #list);
	return true;
end

-- -------------------------------------------------------------- upgrades ----
--
-- Warrior -> Swordsman and every other UnitUpgrades row (#30, Anthony:
-- "upgrading units to their next tier"). The engine gates EVERYTHING inside
-- the strict CanStartCommand (gold, friendly territory, target tech, XP2
-- strategic resources) -- we only add a treasury reserve so upgrades never
-- starve the emergency defense gold-buy, and a per-turn cap so one rich turn
-- does not blow the whole bank.
-- API verified (UnitPanel.lua:466-484 two-stage check + GetUpgradeCost;
-- :2511-2513 RequestCommand with NO params; UnitUpgrades table
-- 01_GameplaySchema.sql:3076, e.g. Units.xml:856 WARRIOR->SWORDSMAN).
local UPGRADE_GOLD_RESERVE  = 200;
local MAX_UPGRADES_PER_TURN = 3;

local function TryUpgrade(pUnit, pPlayer)
	local id = pUnit:GetID();
	if g_upgraded[id] or g_promoted[id] then return false end
	if g_upgradeCount >= MAX_UPGRADES_PER_TURN then return false end
	if g_inflight[id] then return false end
	local ok, can = pcall(function()
		return UnitManager.CanStartCommand(pUnit, UnitCommandTypes.UPGRADE, false);
	end);
	if not ok or not can then return false end
	local okC, cost = pcall(function() return pUnit:GetUpgradeCost(); end);
	if not okC or cost == nil then return false end
	local okT, bal = pcall(function() return pPlayer:GetTreasury():GetGoldBalance(); end);
	if not okT or bal == nil or (bal - cost) < UPGRADE_GOLD_RESERVE then return false end
	local newType = "?";
	local okR, res = pcall(function()
		local _, t = UnitManager.CanStartCommand(pUnit, UnitCommandTypes.UPGRADE, false, true);
		return t;
	end);
	if okR and res ~= nil and res[UnitCommandResults.UNIT_TYPE] ~= nil then
		local r = GameInfo.Units[res[UnitCommandResults.UNIT_TYPE]];
		if r ~= nil then newType = r.UnitType end
	end
	g_upgraded[id]  = true;
	g_upgradeCount  = g_upgradeCount + 1;
	IssueCmd(pUnit, UnitCommandTypes.UPGRADE, nil);
	Log("UPGRADING unit %d -> %s (cost %d, bank %d)", id, newType, cost, math.floor(bal));
	return true;
end

-- Recon units (scouts, rangers) get handed to the game's own explorer:
-- UNITOPERATION_AUTOMATE_EXPLORE (Gameplay/Data/UnitOperations.xml:67 -- the
-- same operation as the base game's "Automate Exploration" button). One order,
-- then the engine drives the unit every turn; an automated unit stops reading
-- as AWAKE so we never touch it again.
local function IsRecon(pUnit)
	local info = GameInfo.Units[pUnit:GetUnitType()];
	if info == nil then return false end
	return info.PromotionClass == "PROMOTION_CLASS_RECON";
end

-- Returns true only if the engine actually took the order. The two `return false`
-- paths used to be SILENT, and that silence was the bug: the game refuses to
-- (re-)automate a unit that is in contact with an enemy, so the moment a scout
-- saw a fight it declined here, the caller marked it handled anyway, and the
-- scout sat there as UNIT NEEDS ORDERS with a completely empty log. Every
-- decline now says why -- the mod's own rule #5, which this function was
-- breaking.
local function TryAutoExplore(pUnit)
	local op = ResolveOp(UnitOperationTypes.AUTOMATE_EXPLORE, "UNITOPERATION_AUTOMATE_EXPLORE");
	if op == nil then
		Log("scout %d: AUTOMATE_EXPLORE operation does not exist in this build", pUnit:GetID());
		return false;
	end
	if not CanStart(pUnit, op) then
		-- Overwhelmingly: an enemy is visible/adjacent, so the engine will not
		-- hand the unit to the explorer. Caller falls through to fight-or-withdraw.
		Log("scout %d: engine refused auto-explore (enemy contact?) -- falling through", pUnit:GetID());
		return false;
	end
	IssueOp(pUnit,op);
	Log("scout %d -> auto-explore", pUnit:GetID());
	return true;
end

-- A wounded scout stops exploring and saves itself: step to the reachable plot
-- farthest from danger (tie-broken toward home), or heal if already clear.
-- Without this we re-issued auto-explore to wounded scouts every turn, marching
-- them straight back into the fights that were killing them (observed live).
local SCOUT_RETREAT_HP = 70;

local function ScoutRetreat(pUnit, pPlayer, threats)
	local ux, uy = pUnit:GetX(), pUnit:GetY();
	local dNow = NearestThreatDist(threats, ux, uy);

	if dNow == nil or dNow > 3 then
		if CanStart(pUnit, UnitOperationTypes.HEAL) then
			IssueOp(pUnit,UnitOperationTypes.HEAL);
			Log("scout %d: clear of threats, healing", pUnit:GetID());
			return true;
		end
		if CanStart(pUnit, UnitOperationTypes.SKIP_TURN) then
			IssueOp(pUnit,UnitOperationTypes.SKIP_TURN);
			return true;
		end
		return false;
	end

	local home = NearestOwnCityPlot(pPlayer, ux, uy);
	local ok, reach = pcall(function() return UnitManager.GetReachableMovement(pUnit); end);
	if not ok or reach == nil then return false end

	local best, bestGain, bestHome = nil, dNow, 9999;
	for _, idx in ipairs(reach) do
		local plot = Map.GetPlotByIndex(idx);
		if plot ~= nil and not (plot:GetX() == ux and plot:GetY() == uy) then
			local d = NearestThreatDist(threats, plot:GetX(), plot:GetY()) or 999;
			local dHome = (home ~= nil)
				and Map.GetPlotDistance(plot:GetX(), plot:GetY(), home:GetX(), home:GetY()) or 0;
			if d > bestGain or (d == bestGain and dHome < bestHome) then
				bestGain, bestHome, best = d, dHome, plot;
			end
		end
	end

	if best ~= nil and MoveTo(pUnit, best:GetX(), best:GetY()) then
		Log("scout %d: hurt, retreating (threat %d -> %d tiles)", pUnit:GetID(), dNow, bestGain);
		return true;
	end
	return false;
end

-- Units.FoundCity is a real BOOLEAN column on the Units table
-- (Gameplay/Data/Schema/01_GameplaySchema.sql:2846).
local function IsSettler(pUnit)
	local info = GameInfo.Units[pUnit:GetUnitType()];
	if info == nil then return false end
	return info.FoundCity == true or info.FoundCity == 1;
end

local function IsCombatUnit(pUnit)
	local info = GameInfo.Units[pUnit:GetUnitType()];
	if info == nil then return false end
	if info.Domain == "DOMAIN_AIR" then return false end          -- skip aircraft in v1
	if info.FormationClass == "FORMATION_CLASS_CIVILIAN" then return false end
	if info.FormationClass == "FORMATION_CLASS_SUPPORT" then return false end
	return pUnit:GetCombat() > 0;
end

-- Rams, siege towers, medics, drones. They used to fall through to the
-- catch-all and SLEEP forever (#31) -- but a support unit's whole job is to be
-- WITH the army.
local function IsSupportUnit(pUnit)
	local info = GameInfo.Units[pUnit:GetUnitType()];
	return info ~= nil and info.FormationClass == "FORMATION_CLASS_SUPPORT";
end

local function IsRanged(pUnit)
	return pUnit:GetRangedCombat() > pUnit:GetCombat()
		or pUnit:GetBombardCombat() > pUnit:GetCombat();
end

local function HPPercent(pUnit)
	local maxd = pUnit:GetMaxDamage();
	if maxd == nil or maxd <= 0 then return 100 end
	return math.floor(100 * (maxd - pUnit:GetDamage()) / maxd);
end

-- Return the first visible, at-war enemy UNIT on a plot (nil if none / city / fogged).
local function GetEnemyOnPlot(plot, eLocalPlayer, pDiplo, pVis)
	if plot == nil then return nil end
	local x, y = plot:GetX(), plot:GetY();
	if pVis == nil or not pVis:IsVisible(x, y) then return nil end
	local ok, list = pcall(function() return Units.GetUnitsInPlotLayerID(x, y, MapLayers.ANY); end);
	if not ok or list == nil then return nil end
	for _, u in ipairs(list) do
		local owner = u:GetOwner();
		if owner ~= eLocalPlayer and owner >= 0 and pDiplo:IsAtWarWith(owner) and pVis:IsUnitVisible(u) then
			return u;
		end
	end
	return nil;
end

-- Is this plot an at-war enemy CITY CENTER we know about?
-- (GetEnemyOnPlot deliberately ignores cities; this is the counterpart, and is
-- what lets melee units actually assault a city instead of milling around it.)
local function IsEnemyCityPlot(plot, eLocalPlayer, pDiplo, pVis)
	if plot == nil or not plot:IsCity() then return false end
	local owner = plot:GetOwner();
	if owner == nil or owner < 0 or owner == eLocalPlayer then return false end
	if not pDiplo:IsAtWarWith(owner) then return false end
	local x, y = plot:GetX(), plot:GetY();
	if pVis == nil or not pVis:IsRevealed(x, y) then return false end
	local ok, pCity = pcall(function() return Cities.GetCityInPlot(x, y); end);
	return ok and pCity ~= nil;
end

-- Strongest visible at-war enemy adjacent to (x,y). 0 if none.
local function StrongestAdjacentEnemy(x, y, eLocalPlayer, pDiplo, pVis)
	local maxStr = 0;
	for dir = 0, 5 do
		local adj = Map.GetAdjacentPlot(x, y, dir);
		local e = GetEnemyOnPlot(adj, eLocalPlayer, pDiplo, pVis);
		if e ~= nil then
			local s = math.max(e:GetCombat(), e:GetRangedCombat());
			if s > maxStr then maxStr = s end
		end
	end
	return maxStr;
end

-- ---------------------------------------------------------- city strikes ----
--
-- Walled cities and encampments get a FREE ranged shot every turn, and the mod
-- never fired one (#29 -- Anthony watched the CITY RANGED ATTACK button sit
-- unused mid-invasion). API verified in the install:
--   gate     CityManager.CanStartCommand(cityOrDistrict, RANGE_ATTACK) with no
--            params = "can strike at all this turn" (CityBannerManager.lua:1555)
--   targets  CityManager.GetCommandTargets -> PLOTS + MODIFIERS, real target
--            iff MODIFIER_IS_TARGET (WorldInput.lua:2579-2587)
--   fire     PARAM_X/PARAM_Y (UnitOperationTypes' params, deliberately --
--            WorldInput.lua:2549-2556); districts identical (:2626-2650).
local function StrikeFrom(obj, what, eLocalPlayer, pDiplo, pVis)
	local okG, canAny = pcall(function()
		return CityManager.CanStartCommand(obj, CityCommandTypes.RANGE_ATTACK);
	end);
	if not okG or not canAny then return false end
	local okT, tResults = pcall(function()
		return CityManager.GetCommandTargets(obj, CityCommandTypes.RANGE_ATTACK, {});
	end);
	if not okT or tResults == nil then return false end
	local plots = tResults[CityCommandResults.PLOTS];
	local mods  = tResults[CityCommandResults.MODIFIERS];
	if plots == nil or mods == nil then return false end
	local best, bestScore = nil, -1;
	for i, m in ipairs(mods) do
		if m == CityCommandResults.MODIFIER_IS_TARGET then
			local plot = Map.GetPlotByIndex(plots[i]);
			if plot ~= nil then
				-- Same focus-fire doctrine as the units (#6): kill-shots first.
				local score = 1;
				local e = GetEnemyOnPlot(plot, eLocalPlayer, pDiplo, pVis);
				if e ~= nil then
					score = 200 - HPPercent(e);
					if HPPercent(e) <= 35 then score = score + 200 end
				end
				if score > bestScore then bestScore, best = score, plot end
			end
		end
	end
	if best == nil then return false end
	local tParams = {
		[UnitOperationTypes.PARAM_X] = best:GetX(),
		[UnitOperationTypes.PARAM_Y] = best:GetY(),
	};
	local okC, can = pcall(function()
		return CityManager.CanStartCommand(obj, CityCommandTypes.RANGE_ATTACK, tParams);
	end);
	if not (okC and can) then return false end
	CityManager.RequestCommand(obj, CityCommandTypes.RANGE_ATTACK, tParams);
	Log("CITY-STRIKE from [%s] -> %d,%d", tostring(what), best:GetX(), best:GetY());
	return true;
end

local function AutomateCityStrikes(pPlayer, eLocalPlayer, pDiplo, pVis)
	local okC, cities = pcall(function() return pPlayer:GetCities(); end);
	if okC and cities ~= nil then
		for _, c in cities:Members() do
			local key = "c" .. c:GetID();
			if not g_struck[key] and StrikeFrom(c, c:GetName(), eLocalPlayer, pDiplo, pVis) then
				g_struck[key] = true;
			end
		end
	end
	-- Encampments etc. -- pcall-fenced as a unit: if this build's district
	-- collection has no Members(), cities above still fired.
	pcall(function()
		local dists = pPlayer:GetDistricts();
		if dists == nil then return end
		for _, d in dists:Members() do
			local key = "d" .. d:GetID();
			if not g_struck[key] and StrikeFrom(d, "district " .. d:GetID(), eLocalPlayer, pDiplo, pVis) then
				g_struck[key] = true;
			end
		end
	end);
end

-- ------------------------------------------------------------- builders -----

-- Is this plot improved WRONG for the resource under it? (Anthony 2026-07-18:
-- "redo things if a diff strat resource is there" -- iron revealed under an
-- old farm needs that farm replaced with a mine.) Validity map built once from
-- Improvement_ValidResources, the same table the plot tooltip walks.
local g_resImpValid = nil;   -- [ResourceType string][improvement Index] = true
local function WrongImprovementForResource(plot)
	local resIdx = plot:GetResourceType();
	local impIdx = plot:GetImprovementType();
	if resIdx == -1 or impIdx == -1 then return false end
	if g_resImpValid == nil then
		g_resImpValid = {};
		for row in GameInfo.Improvement_ValidResources() do
			local imp = GameInfo.Improvements[row.ImprovementType];
			if imp ~= nil then
				g_resImpValid[row.ResourceType] = g_resImpValid[row.ResourceType] or {};
				g_resImpValid[row.ResourceType][imp.Index] = true;
			end
		end
	end
	local resRow = GameInfo.Resources[resIdx];
	if resRow == nil then return false end
	local valid = g_resImpValid[resRow.ResourceType];
	if valid == nil then return false end   -- resource takes no improvement: leave it
	return valid[impIdx] ~= true;
end

-- Nearest reachable, unimproved tile the game recommends improving.
-- `linked` widens the safety envelope: an escorted (formation-linked) builder
-- may work the full ring-3; an unlinked one stays within 2 tiles of a city --
-- under the garrison/city-strike umbrella (Anthony: "make sure they are
-- always protected").
local function BestBuildTargetPlot(pPlayer, pUnit, linked)
	local unitCompID = pUnit:GetComponentID();
	local best, bestTurns = nil, 9999;
	local seen = {};
	local nRecs, nRejected = 0, 0;   -- diagnostics: why did we find nowhere to go?
	local ok, pCities = pcall(function() return pPlayer:GetCities(); end);
	if not ok or pCities == nil then Log("builder: GetCities failed"); return nil end
	for _, pCity in pCities:Members() do
		local pCityAI = pCity:GetCityAI();
		if pCityAI ~= nil then
			local okR, recs = pcall(function()
				return pCityAI:GetImprovementRecommendationsForBuilder(unitCompID);
			end);
			if okR and recs ~= nil then
				for _, v in pairs(recs) do
					local loc = v.ImprovementLocation;
					if loc ~= nil and loc >= 0 and not seen[loc] then
						seen[loc] = true;
						local plot = Map.GetPlotByIndex(loc);
						-- The advisor branch must respect the same blacklist and
						-- destination claims as the fallback scan (audit 2026-07-18):
						-- without this, a refused MOVE_TO blacklisted the plot and
						-- the advisor re-elected it anyway, every pass, forever.
						-- OWNERSHIP (Anthony live t88: "builders venture away from
						-- actual owned land"): the advisor recommends plots we do
						-- not own yet -- builders can only ever work OUR tiles.
						-- PROTECTION: unlinked builders stay <=2 from a city.
						local okOwn = plot ~= nil and plot:GetOwner() == pPlayer:GetID();
						local okSafe = false;
						if okOwn then
							local home = NearestOwnCityPlot(pPlayer, plot:GetX(), plot:GetY());
							local dHome = (home ~= nil)
								and Map.GetPlotDistance(plot:GetX(), plot:GetY(), home:GetX(), home:GetY()) or 99;
							okSafe = dHome <= (linked and 3 or 2);
						end
						if okOwn and okSafe
						   and plot:GetImprovementType() == -1 and not plot:IsWater() and not plot:IsImpassable()
						   and (g_plotSkip[loc] == nil or g_plotSkip[loc] <= Game.GetCurrentGameTurn())
						   and g_claims[loc] == nil then
							local okP, pathInfo = pcall(function()
								return UnitManager.GetMoveToPathEx(pUnit, loc);
							end);
							-- GetMoveToPathEx can return a path with plots but NO turns
							-- table (e.g. an unreachable/blocked target). table.count
							-- indexes its argument, so passing that nil threw
							-- "attempt to index a nil value" on every builder, every
							-- pass -- which is what stopped builders automating at all.
							if okP and pathInfo ~= nil and pathInfo.plots ~= nil and table.count(pathInfo.plots) > 1 then
								local turns = 999;
								if pathInfo.turns ~= nil then
									local nT = table.count(pathInfo.turns);
									if nT > 0 then turns = pathInfo.turns[nT] or 999 end
								end
								if turns < bestTurns then bestTurns = turns; best = plot end
							end
						end
					end
				end
			end
		end
	end
	if best ~= nil then return best end

	-- FALLBACK (issue #1): the advisor said nothing -- the same advisor
	-- blindness seen everywhere else -- and without this, a builder with
	-- charges idled forever while its city sat on unimproved tiles (observed
	-- live twice; only 3 builds happened in a whole session). Walk every plot
	-- in each city's workable ring (radius 3) ourselves: owned, land,
	-- passable, unimproved, no district. Resource plots first (they unlock
	-- luxuries/strategics), then highest raw yield; nearest breaks ties.
	local ux, uy = pUnit:GetX(), pUnit:GetY();
	local eOwner = pPlayer:GetID();
	local nowTurn = Game.GetCurrentGameTurn();

	-- Tech-awareness (issue #9, Anthony's diagnosis: "sometimes research needs
	-- to come first"). A resource tile can ONLY take its matching improvement,
	-- so a resource whose improvement tech is not researched makes the whole
	-- plot untouchable -- exclude it or the builder parks there forever.
	-- Mapping via GameInfo.Improvement_ValidResources (the exact table
	-- PlotToolTip.lua:257 walks), prereq via Improvements.PrereqTech + HasTech
	-- (WorldRankings.lua:1332).
	local resourceOK = {};
	local okT, pTechs = pcall(function() return pPlayer:GetTechs(); end);
	if okT and pTechs ~= nil then
		for row in GameInfo.Improvement_ValidResources() do
			local imp = GameInfo.Improvements[row.ImprovementType];
			if imp ~= nil then
				local usable = (imp.PrereqTech == nil);
				if not usable then
					local t = GameInfo.Technologies[imp.PrereqTech];
					local okH, has = pcall(function() return pTechs:HasTech(t.Index); end);
					usable = (t ~= nil) and okH and has == true;
				end
				if usable then resourceOK[row.ResourceType] = true end
			end
		end
	end

	local candidates = {};
	for _, pCity in pCities:Members() do
		local cx, cy = pCity:GetX(), pCity:GetY();
		for dx = -3, 3 do
			for dy = -3, 3 do
				local plot = Map.GetPlot(cx + dx, cy + dy);
				if plot ~= nil and Map.GetPlotDistance(cx, cy, plot:GetX(), plot:GetY()) <= (linked and 3 or 2)
				   and plot:GetOwner() == eOwner
				   and not plot:IsWater() and not plot:IsImpassable()
				   -- Pillaged improvements count as work too (Anthony: "they
				   -- always have things to do"): at war the map fills with
				   -- pillaged farms, repair is charge-FREE, and the old
				   -- unimproved-only filter made them invisible to the scan.
				   and (plot:GetImprovementType() == -1 or plot:IsImprovementPillaged()
				        or WrongImprovementForResource(plot))
				   and plot:GetDistrictType() == -1
				   and not plot:IsCity()
				   and (g_plotSkip[plot:GetIndex()] == nil or g_plotSkip[plot:GetIndex()] <= nowTurn)
				   and g_claims[plot:GetIndex()] == nil then
					local resIdx  = plot:GetResourceType();
					local resRow  = (resIdx ~= -1) and GameInfo.Resources[resIdx] or nil;
					local resName = (resRow ~= nil) and resRow.ResourceType or nil;
					-- Unimprovable-resource plots are skipped outright.
					if resName == nil or resourceOK[resName] or plot:IsImprovementPillaged() then
						local score = 0;
						if resName ~= nil then score = score + 100 end
						-- Repairs outrank new builds: instant yield back, no charge.
						if plot:IsImprovementPillaged() then score = score + 150 end
						-- Mis-improved resource plots (farm on iron) rank just below.
						if WrongImprovementForResource(plot) then score = score + 120 end
						for yRow in GameInfo.Yields() do
							local okY, y = pcall(function() return plot:GetYield(yRow.Index); end);
							if okY and y ~= nil then score = score + y end
						end
						local d = Map.GetPlotDistance(ux, uy, plot:GetX(), plot:GetY());
						candidates[#candidates + 1] = { plot = plot, score = score, dist = d };
					end
				end
			end
		end
	end

	-- Best-first, but only a plot the builder can actually PATH to wins --
	-- issue #13: the scan kept electing an unreachable plot and MoveTo refused
	-- every pass, skipping the builder turn after turn. Same GetMoveToPathEx
	-- test the advisor path uses; unreachable plots get blacklisted so the
	-- next scan starts from the runner-up.
	table.sort(candidates, function(a, b)
		if a.score ~= b.score then return a.score > b.score end
		return a.dist < b.dist;
	end);
	if #candidates == 0 then
		-- Rule #5 (Anthony: "better listening"): a whole session ran with zero
		-- scan lines because an empty candidate list returned nil silently.
		Log("builder %d: fallback scan 0 candidates -- all filtered (owned/water/improved/district/blacklist/claims/resource-tech)", pUnit:GetID());
	end
	for _, c in ipairs(candidates) do
		if c.plot:GetX() == ux and c.plot:GetY() == uy then
			return c.plot;   -- already standing on it; no path needed
		end
		local okP, pathInfo = pcall(function()
			return UnitManager.GetMoveToPathEx(pUnit, c.plot:GetIndex());
		end);
		if okP and pathInfo ~= nil and pathInfo.plots ~= nil and table.count(pathInfo.plots) > 1 then
			Log("builder %d: advisor empty, own scan -> %d,%d (score %d)",
				pUnit:GetID(), c.plot:GetX(), c.plot:GetY(), c.score);
			return c.plot;
		end
		g_plotSkip[c.plot:GetIndex()] = nowTurn + 5;
	end
	return nil;
end

-- Returns "repair" | "build" | "move" | "skip", or nil if NOTHING was issued
-- (nil is the caller's signal to run the catch-all).
local function AutomateBuilder(pUnit, pPlayer, threats)
	local x, y = pUnit:GetX(), pUnit:GetY();
	local plot = Map.GetPlot(x, y);

	-- 0) Survival first (#25, live: builder 851972 sat 9 turns with an enemy
	--    one tile away and died in place). Best protection: LINK with a soldier
	--    sharing the tile (Anthony's tip -- the pair is one stack, the civilian
	--    is uncapturable while linked; API UnitPanel.lua:416-434 + :2597-2607).
	--    Already linked -> work normally, the soldier holds with us. Not linked
	--    and danger close -> link if possible, flee home otherwise.
	local dT = NearestThreatDist(threats, x, y, true);
	local okFm, fmN = pcall(function() return pUnit:GetFormationUnitCount(); end);
	local linked = (okFm and fmN ~= nil and fmN > 1);
	-- LINK EARLY, not at the last second (Anthony live: "units being captured
	-- again regularly... creating linked formation is a thing in game for this
	-- reason"). Any land threat within 8 -> take the link the moment a soldier
	-- shares the tile. Unlink hysteresis lives in the soldier branch (>10).
	if not linked and dT ~= nil and dT <= 8 then
		local okF, fRes = pcall(function()
			local b, t = UnitManager.CanStartCommand(pUnit, UnitCommandTypes.ENTER_FORMATION, nil, true);
			return { can = b, res = t };
		end);
		if okF and fRes ~= nil and fRes.can and fRes.res ~= nil
		   and fRes.res[UnitCommandResults.UNITS] ~= nil and #fRes.res[UnitCommandResults.UNITS] > 0 then
			local mate = fRes.res[UnitCommandResults.UNITS][1];
			local tLink = {};
			tLink[UnitCommandTypes.PARAM_UNIT_PLAYER] = mate.player;
			tLink[UnitCommandTypes.PARAM_UNIT_ID]     = mate.id;
			IssueCmd(pUnit, UnitCommandTypes.ENTER_FORMATION, tLink);
			Log("builder %d: LINKED formation with unit %d (threat %d out)", pUnit:GetID(), mate.id, dT);
			return "link";
		end
	end
	if not linked and dT ~= nil and dT <= BUILDER_FLEE_DIST then
		local home = NearestOwnCityPlot(pPlayer, x, y);
		if home ~= nil and not (home:GetX() == x and home:GetY() == y) then
			if MoveTo(pUnit, home:GetX(), home:GetY()) then
				Log("builder %d: enemy %d tiles away, fleeing home", pUnit:GetID(), dT);
				return "flee";
			end
		end
	end

	-- 0d) DEFENSE SHELTER (live, Delhi: builders oscillated flee-home -> walk
	--     back out -> flee again, burning every turn). While a city is under
	--     threat, unlinked builders near it stay put -- in the city if
	--     reachable -- until the area clears. Linked builders work on.
	if not linked and g_defcity ~= nil
	   and Map.GetPlotDistance(x, y, g_defcity.x, g_defcity.y) <= CITY_DEFENDER_PULL then
		local herePlot = Map.GetPlot(x, y);
		if herePlot ~= nil and not herePlot:IsCity() then
			local home = NearestOwnCityPlot(pPlayer, x, y);
			if home ~= nil and not (home:GetX() == x and home:GetY() == y) then
				if MoveTo(pUnit, home:GetX(), home:GetY()) then
					Log("builder %d: city under threat -> sheltering", pUnit:GetID());
					return "shelter";
				end
			end
		end
		if CanStart(pUnit, UnitOperationTypes.SKIP_TURN) then
			IssueOp(pUnit, UnitOperationTypes.SKIP_TURN);
			Log("builder %d: city under threat -> holding in city", pUnit:GetID());
			return "shelter";
		end
	end

	-- 1) Repair a pillaged improvement/road under the builder first.
	if plot ~= nil and (plot:IsImprovementPillaged() or plot:IsRoutePillaged()) then
		if CanStart(pUnit, UnitOperationTypes.REPAIR) then
			IssueOp(pUnit,UnitOperationTypes.REPAIR);
			return "repair";
		end
		-- Standing on a pillaged plot the engine will not let us repair (ZOC,
		-- mid-combat): blacklist briefly so the scan (which now elects pillaged
		-- plots) does not shuttle us back here every turn.
		g_plotSkip[plot:GetIndex()] = Game.GetCurrentGameTurn() + 5;
	end

	-- 2) Build the engine's recommended improvement on the current tile --
	--    unimproved, OR mis-improved over a resource (farm on revealed iron).
	if plot ~= nil and (plot:GetImprovementType() == -1 or WrongImprovementForResource(plot)) then
		local tParams = { [UnitOperationTypes.PARAM_X] = x, [UnitOperationTypes.PARAM_Y] = y };
		local ok, res = UnitManager.CanStartOperation(pUnit, UnitOperationTypes.BUILD_IMPROVEMENT, nil, tParams, true);
		if not (ok and res ~= nil and res[UnitOperationResults.IMPROVEMENTS] ~= nil and #res[UnitOperationResults.IMPROVEMENTS] > 0) then
			-- Nothing buildable here. CHOP/HARVEST before giving up (Anthony:
			-- "builders can remove rainforests and marsh too"): REMOVE_FEATURE
			-- clears jungle/marsh/woods for future builds and pays instant
			-- yields to the city; HARVEST_RESOURCE cashes a bonus resource.
			-- Both engine-gated by tech, both verified UnitOperations.xml:82/94.
			local opChop = ResolveOp(UnitOperationTypes.REMOVE_FEATURE, "UNITOPERATION_REMOVE_FEATURE");
			if CanStart(pUnit, opChop) then
				IssueOp(pUnit, opChop);
				Log("builder %d: REMOVING FEATURE at %d,%d", pUnit:GetID(), x, y);
				return "chop";
			end
			local opHarv = ResolveOp(UnitOperationTypes.HARVEST_RESOURCE, "UNITOPERATION_HARVEST_RESOURCE");
			if CanStart(pUnit, opHarv) then
				IssueOp(pUnit, opHarv);
				Log("builder %d: HARVESTING resource at %d,%d", pUnit:GetID(), x, y);
				return "harvest";
			end
			-- Truly nothing: the scan liked this plot but the game disagrees
			-- (usually a missing tech the resource filter could not see --
			-- features, appeal rules). Blacklist it briefly so the next pick is
			-- a DIFFERENT plot instead of shuttling back here (issue #9).
			g_plotSkip[plot:GetIndex()] = Game.GetCurrentGameTurn() + 5;
		end
		if ok and res ~= nil and res[UnitOperationResults.IMPROVEMENTS] ~= nil and #res[UnitOperationResults.IMPROVEMENTS] > 0 then
			local eBest = res[UnitOperationResults.BEST_IMPROVEMENT];
			if eBest == nil or eBest == -1 then eBest = res[UnitOperationResults.IMPROVEMENTS][1] end
			tParams[UnitOperationTypes.PARAM_IMPROVEMENT_TYPE] = eBest;
			local ok2 = UnitManager.CanStartOperation(pUnit, UnitOperationTypes.BUILD_IMPROVEMENT, nil, tParams, false);
			if ok2 then
				local info = GameInfo.Improvements[eBest];
				tParams[UnitOperationTypes.PARAM_IMPROVEMENT_TYPE] = (info ~= nil and info.Hash) or eBest;
				IssueOp(pUnit,UnitOperationTypes.BUILD_IMPROVEMENT, tParams);
				return "build";
			end
		end
	end

	-- 3) Otherwise relocate toward the nearest recommended tile. A refused
	--    MOVE_TO blacklists the plot and tries the runner-up IN THE SAME PASS
	--    (live, Delhi: 3 refused candidates = 3 wasted turns under the old
	--    one-try-per-turn shape; issue #13).
	for try = 1, 3 do
		local target = BestBuildTargetPlot(pPlayer, pUnit, linked);
		if target == nil then break end
		local tParams = {
			[UnitOperationTypes.PARAM_X] = target:GetX(),
			[UnitOperationTypes.PARAM_Y] = target:GetY(),
			[UnitOperationTypes.PARAM_MODIFIERS] = UnitOperationMoveModifiers.NONE,
		};
		if CanStart(pUnit, UnitOperationTypes.MOVE_TO, tParams) then
			-- Claim the destination (audit #3): this path bypassed MoveTo's
			-- claim ledger, so two builders kept electing the same plot.
			g_claims[target:GetIndex()] = pUnit:GetID();
			IssueOp(pUnit,UnitOperationTypes.MOVE_TO, tParams);
			return "move";
		end
		-- Direct MOVE_TO refused: give the full MoveTo wrapper a shot BEFORE
		-- blacklisting -- its bare-params retry and greedy-leg fallback are
		-- exactly what the engine's far-move refusals need (live 2026-07-18
		-- evening: 3/3 candidates refused per builder per turn, builders idled).
		if MoveTo(pUnit, target:GetX(), target:GetY()) then
			return "move";
		end
		-- Dead end RIGHT NOW (occupied destination etc.) -- blacklist so the
		-- next BestBuildTargetPlot call elects the runner-up immediately.
		g_plotSkip[target:GetIndex()] = Game.GetCurrentGameTurn() + 3;
		Log("builder %d: MOVE_TO %d,%d refused -- blacklisting plot (try %d/3)",
			pUnit:GetID(), target:GetX(), target:GetY(), try);
	end

	-- 4) Nothing worth doing: skip so it stops nagging, re-evaluated next turn.
	--    "rest", not "idle" (audit #19): a skip WAS issued, so the caller must
	--    not ALSO run the catch-all -- that was a double skip plus false
	--    decline strikes every workless turn.
	if CanStart(pUnit, UnitOperationTypes.SKIP_TURN) then
		IssueOp(pUnit,UnitOperationTypes.SKIP_TURN);
		return "rest";
	end
	return nil;
end

-- -------------------------------------------------------------- settlers ----
--
-- Same trick again: GetSettlementRecommendations is the engine's own city-siting
-- advisor (it draws the "found city here" icons -- WorldViewIconsManager.lua:710).
-- Found on the spot when the engine allows it and we're on a recommended tile;
-- otherwise walk to the best recommendation.

local SETTLER_FLEE_DIST = 3;   -- any visible enemy this close -> run home

local function AutomateSettler(pUnit, pPlayer, threats)
	local id = pUnit:GetID();
	local ux, uy = pUnit:GetX(), pUnit:GetY();

	-- 0) Safety beats everything. A settler can never win a fight and losing
	--    one loses the whole expansion (observed live: captured by barbarians
	--    mid-walk). Any visible enemy nearby -> drop the plan and run home.
	local dThreat = NearestThreatDist(threats, ux, uy);
	if dThreat ~= nil and dThreat <= SETTLER_FLEE_DIST then
		g_settlerPlan[id] = nil;
		local home = NearestOwnCityPlot(pPlayer, ux, uy);
		if home ~= nil and not (home:GetX() == ux and home:GetY() == uy) then
			if MoveTo(pUnit, home:GetX(), home:GetY()) then
				Log("settler %d: enemy %d tiles away, fleeing home", id, dThreat);
				return "flee";
			end
		end
		if CanStart(pUnit, UnitOperationTypes.SKIP_TURN) then
			IssueOp(pUnit,UnitOperationTypes.SKIP_TURN);
			return "hold";
		end
		-- Rule #5: this nil churned the catch-all 6x live with no reason logged.
		LogOnce("setnil:" .. id, "settler %d: flee wanted, MOVE_TO home AND skip both refused (threat %d out)", id, dThreat);
		return nil;   -- nothing issued -> caller's catch-all takes it
	end

	-- 0b) FORMATION LINK (Anthony's tip, 2026-07-17): a soldier sharing this
	--     tile can be linked into a formation -- the pair then moves as ONE
	--     stack and the settler is never alone again. API verified in the
	--     install: UnitPanel.lua:416-434 (CanStartCommand ENTER_FORMATION
	--     nil,true -> UnitCommandResults.UNITS = linkable units on this tile),
	--     :2597-2607 (PARAM_UNIT_PLAYER + PARAM_UNIT_ID -> RequestCommand).
	local okF, fRes = pcall(function()
		local b, t = UnitManager.CanStartCommand(pUnit, UnitCommandTypes.ENTER_FORMATION, nil, true);
		return { can = b, res = t };
	end);
	if okF and fRes ~= nil and fRes.can and fRes.res ~= nil
	   and fRes.res[UnitCommandResults.UNITS] ~= nil and #fRes.res[UnitCommandResults.UNITS] > 0 then
		local mate = fRes.res[UnitCommandResults.UNITS][1];
		local tLink = {};
		tLink[UnitCommandTypes.PARAM_UNIT_PLAYER] = mate.player;
		tLink[UnitCommandTypes.PARAM_UNIT_ID]     = mate.id;
		IssueCmd(pUnit, UnitCommandTypes.ENTER_FORMATION, tLink);
		Log("settler %d: LINKED formation with unit %d", id, mate.id);
		return "link";
	end

	-- 0c) TRAVEL CONTRACT (settler 393218 captured live: it marched a 7-turn
	--     route alone while every escort was pulled into defending Paris --
	--     the defense doctrine created the gap, this closes it). Founding on
	--     the spot is always allowed; TRAVEL requires all-cities-safe AND a
	--     soldier within 1 tile. Waiting happens inside a city, not in the open.
	local plan0 = g_settlerPlan[id];
	if plan0 ~= nil and ux == plan0.x and uy == plan0.y
	   and CanStart(pUnit, UnitOperationTypes.FOUND_CITY) then
		IssueOp(pUnit, UnitOperationTypes.FOUND_CITY);
		g_settlerPlan[id] = nil;
		Log("settler %d: founding city at %d,%d", id, ux, uy);
		return "found";
	end
	-- LINKED, not merely nearby (Anthony live t88: "settlers venture alone
	-- still"): soldier-within-1 at departure let the pair drift apart on a
	-- multi-turn march. A formation link is ONE stack -- the escort cannot
	-- fall behind. The escort branch (B2) delivers a soldier onto this tile;
	-- step 0b links it; only then does travel unlock.
	local okEsc, escN = pcall(function() return pUnit:GetFormationUnitCount(); end);
	local escorted = (okEsc and escN ~= nil and escN > 1);
	-- Scope the defense hold to the ACTUAL danger zone (audit #6): the old
	-- blanket g_defcity test froze every settler empire-wide whenever any city
	-- anywhere saw a barbarian -- a war on another continent must not stall
	-- expansion here. CITY_DEFENDER_PULL keeps this congruent with the zone
	-- whose escorts get recalled.
	local nearDef = (g_defcity ~= nil
		and Map.GetPlotDistance(ux, uy, g_defcity.x, g_defcity.y) <= CITY_DEFENDER_PULL);
	if nearDef or not escorted then
		local herePlot = Map.GetPlot(ux, uy);
		if herePlot ~= nil and not herePlot:IsCity() then
			local home = NearestOwnCityPlot(pPlayer, ux, uy);
			if home ~= nil and not (home:GetX() == ux and home:GetY() == uy) then
				if MoveTo(pUnit, home:GetX(), home:GetY()) then
					Log("settler %d: %s -> waiting in city", id,
						nearDef and "city under threat" or "no escort");
					return "wait";
				end
			end
		end
		if CanStart(pUnit, UnitOperationTypes.SKIP_TURN) then
			IssueOp(pUnit, UnitOperationTypes.SKIP_TURN);
			Log("settler %d: %s -> holding", id,
				nearDef and "city under threat" or "no escort");
			return "wait";
		end
		LogOnce("setwait:" .. id, "settler %d: wait wanted, MOVE_TO home AND skip both refused", id);
		return nil;
	end

	-- 1) A committed site is only re-examined for danger, never for "a slightly
	--    better tile appeared" -- recommendations shift every turn as the map
	--    reveals, and chasing them is how settlers wander forever.
	local plan = g_settlerPlan[id];
	if plan ~= nil then
		if NearestThreatDist(threats, plan.x, plan.y) ~= nil
		   and NearestThreatDist(threats, plan.x, plan.y) <= 2 then
			Log("settler %d: committed site %d,%d compromised, replanning", id, plan.x, plan.y);
			g_settlerPlan[id] = nil;
			plan = nil;
		elseif ux == plan.x and uy == plan.y then
			if CanStart(pUnit, UnitOperationTypes.FOUND_CITY) then
				IssueOp(pUnit,UnitOperationTypes.FOUND_CITY);
				g_settlerPlan[id] = nil;
				Log("settler %d: founding city at %d,%d", id, ux, uy);
				return "found";
			end
			-- Arrived but founding is illegal here (site got claimed etc.).
			g_settlerPlan[id] = nil;
			plan = nil;
		else
			if MoveTo(pUnit, plan.x, plan.y) then return "move" end
			g_settlerPlan[id] = nil;   -- path gone; replan below
			plan = nil;
		end
	end

	local pGrandAI = pPlayer:GetGrandStrategicAI();
	if pGrandAI == nil then return "idle" end

	local okR, recs = pcall(function() return pGrandAI:GetSettlementRecommendations(5); end);
	if not okR or recs == nil then recs = {} end

	local here = Map.GetPlotIndex(ux, uy);
	local onRecommended = false;
	for _, kRec in pairs(recs) do
		if kRec.SettlingLocation == here then onRecommended = true; break end
	end

	-- 2) Found here if the engine permits it AND either this is a recommended
	--    spot or we have nowhere better to go. Never refuse to settle forever.
	if CanStart(pUnit, UnitOperationTypes.FOUND_CITY) then
		if onRecommended or next(recs) == nil then
			IssueOp(pUnit,UnitOperationTypes.FOUND_CITY);
			Log("settler %d: founding city at %d,%d", id, ux, uy);
			return "found";
		end
	end

	-- 3) Pick the nearest recommended site that is reachable AND not itself
	--    sitting in a threat zone, then COMMIT to it (see g_settlerPlan).
	local best, bestTurns = nil, 9999;
	for _, kRec in pairs(recs) do
		local loc = kRec.SettlingLocation;
		if loc ~= nil and loc >= 0 and loc ~= here then
			local plot = Map.GetPlotByIndex(loc);
			local safe = plot ~= nil;
			if safe then
				local dSite = NearestThreatDist(threats, plot:GetX(), plot:GetY());
				safe = (dSite == nil or dSite > 2);
			end
			if safe then
				local okP, pathInfo = pcall(function() return UnitManager.GetMoveToPathEx(pUnit, loc); end);
				if okP and pathInfo ~= nil and pathInfo.plots ~= nil and table.count(pathInfo.plots) > 1 then
					local turns = 999;
					if pathInfo.turns ~= nil then
						local nT = table.count(pathInfo.turns);
						if nT > 0 then turns = pathInfo.turns[nT] or 999 end
					end
					if turns < bestTurns then bestTurns = turns; best = plot end
				end
			end
		end
	end

	if best ~= nil then
		if MoveTo(pUnit, best:GetX(), best:GetY()) then
			g_settlerPlan[id] = { x = best:GetX(), y = best:GetY() };
			Log("settler %d: committed to site %d,%d (%d turns)", id, best:GetX(), best:GetY(), bestTurns);
			return "move";
		end
	end

	-- Cannot found, cannot path anywhere better: settle right here if legal
	-- rather than stand still forever.
	if CanStart(pUnit, UnitOperationTypes.FOUND_CITY) then
		IssueOp(pUnit,UnitOperationTypes.FOUND_CITY);
		Log("settler: no better site reachable, founding at %d,%d", pUnit:GetX(), pUnit:GetY());
		return "found";
	end
	return "idle";
end

-- ------------------------------------------------------------------ trade ----
--
-- An idle trader is one of the most expensive things in the game to leave
-- standing around: a running route pays gold/food/production EVERY turn, and a
-- trader parked in a city pays exactly nothing. They also never stop asking for
-- orders, so they block turns too.
--
-- Verified API (grepped, not guessed):
--   Trader test   GameInfo.Units[u:GetUnitType()].MakeTradeRoute   (UI/TradeSupport.lua:10-11,
--                 Units.xml:753). NOT FormationClass -- settlers/builders are CIVILIAN too.
--   Idle test     scan owned cities' GetTrade():GetOutgoingRoutes() for route.TraderUnitID
--                 (UI/TradeSupport.lua:1-33, the game's own GetIdleTradeUnits). There is no
--                 HasPendingTrade / IsTradeRouteActive in this build.
--   Origin city   Cities.GetCityInPlot(u:GetX(), u:GetY())         (TradeRouteChooser.lua:84)
--   Candidates    brute-force every player's cities, gated by CanStartOperation
--                 (TradeRouteChooser.lua:462-486). GetAvailableTradeRoutes does NOT exist.
--   Dispatch      PARAM_X0/Y0 = DESTINATION city plot, PARAM_X1/Y1 = TRADER's plot
--                 (TradeRouteChooser.lua:826-844). No city ids, no player ids.
--   Capacity      GetTrade():GetNumOutgoingRoutes() vs :GetOutgoingRouteCapacity()
--                 (UI/TradeOverview.lua:51-53).

local function IsTrader(pUnit)
	local info = GameInfo.Units[pUnit:GetUnitType()];
	if info == nil then return false end
	return info.MakeTradeRoute == true or info.MakeTradeRoute == 1;
end

local function TraderHasRoute(pPlayer, unitID)
	local ok, cities = pcall(function() return pPlayer:GetCities(); end);
	if not ok or cities == nil then return false end
	for _, city in cities:Members() do
		local okT, routes = pcall(function() return city:GetTrade():GetOutgoingRoutes(); end);
		if okT and routes ~= nil then
			for _, route in ipairs(routes) do
				if route.TraderUnitID == unitID then return true end
			end
		end
	end
	return false;
end

-- Rank candidate routes by what the ORIGIN city gets. Summing every yield is a
-- deliberate simplification: the panel's own GetYieldsForRoute lives in
-- TradeSupport.lua and pulling that include into this context is more risk than
-- a ranking refinement is worth. Gold-vs-food weighting can come later.
local function TradeRouteScore(tradeManager, oOwner, oID, dOwner, dID)
	local ok, y = pcall(function()
		return tradeManager:CalculateOriginYieldsFromPotentialRoute(oOwner, oID, dOwner, dID);
	end);
	if not ok or y == nil then return 0 end
	local total = 0;
	for i = 1, #y do total = total + (y[i] or 0) end
	return total;
end

local function AutomateTrader(pUnit, pPlayer)
	local id = pUnit:GetID();
	if TraderHasRoute(pPlayer, id) then return "routed" end   -- already earning; leave it be

	-- No free capacity -> nothing this unit can legally do. Return nil so the
	-- catch-all sleeps it instead of it asking for orders every turn.
	local pTrade = pPlayer:GetTrade();
	if pTrade ~= nil then
		local okN, nRoutes = pcall(function() return pTrade:GetNumOutgoingRoutes(); end);
		local okC, cap     = pcall(function() return pTrade:GetOutgoingRouteCapacity(); end);
		if okN and okC and nRoutes ~= nil and cap ~= nil and nRoutes >= cap then
			LogOnce("tradercap:" .. id, "trader %d: at route capacity (%d/%d)", id, nRoutes, cap);
			-- Skip in place (audit #23). NOT sleep: a slept trader never reads
			-- AWAKE again, so it would miss capacity growth forever. NOT nil:
			-- the catch-all churned an UNSTUCK line for it every single turn.
			if CanStart(pUnit, UnitOperationTypes.SKIP_TURN) then
				IssueOp(pUnit, UnitOperationTypes.SKIP_TURN);
				return "capacity";
			end
			return nil;
		end
	end

	-- A route must start FROM a city, so a trader in the field walks home first.
	local origin = Cities.GetCityInPlot(pUnit:GetX(), pUnit:GetY());
	if origin == nil then
		local home = NearestOwnCityPlot(pPlayer, pUnit:GetX(), pUnit:GetY());
		if home ~= nil and MoveTo(pUnit, home:GetX(), home:GetY()) then
			Log("trader %d: not in a city -> walking to %d,%d", id, home:GetX(), home:GetY());
			return "move";
		end
		return nil;
	end

	local tradeManager = Game.GetTradeManager();
	if tradeManager == nil then return nil end
	local oOwner, oID = origin:GetOwner(), origin:GetID();

	local best, bestScore, bestName = nil, -1, nil;
	for _, player in ipairs(Game.GetPlayers()) do
		local okCities, cities = pcall(function() return player:GetCities(); end);
		if okCities and cities ~= nil then
			for _, city in cities:Members() do
				local tParams = {
					[UnitOperationTypes.PARAM_X0] = city:GetX(),
					[UnitOperationTypes.PARAM_Y0] = city:GetY(),
					[UnitOperationTypes.PARAM_X1] = pUnit:GetX(),
					[UnitOperationTypes.PARAM_Y1] = pUnit:GetY(),
				};
				-- CanStartOperation is both the legality gate AND the reachability
				-- filter here, exactly as the game's own chooser uses it.
				if CanStart(pUnit, UnitOperationTypes.MAKE_TRADE_ROUTE, tParams) then
					local s = TradeRouteScore(tradeManager, oOwner, oID, city:GetOwner(), city:GetID());
					if s > bestScore then bestScore, best, bestName = s, city, city:GetName() end
				end
			end
		end
	end

	if best == nil then
		Log("trader %d: no legal route from [%s]", id, tostring(origin:GetName()));
		return nil;
	end

	local tParams = {
		[UnitOperationTypes.PARAM_X0] = best:GetX(),
		[UnitOperationTypes.PARAM_Y0] = best:GetY(),
		[UnitOperationTypes.PARAM_X1] = pUnit:GetX(),
		[UnitOperationTypes.PARAM_Y1] = pUnit:GetY(),
	};
	IssueOp(pUnit,UnitOperationTypes.MAKE_TRADE_ROUTE, tParams);
	Log("trader %d: [%s] -> [%s] (yield score %d)",
		id, tostring(origin:GetName()), tostring(bestName), bestScore);
	return "trade";
end

-- ---------------------------------------------------------- great people -----
--
-- A slept Great Prophet is a lost religion (observed live: catch-all slept one
-- the turn after our first Holy Site finished). Generic activation logic works
-- for every class, all verified:
--   pUnit:GetGreatPerson() / :IsGreatPerson() / :GetClass()   (UnitPanel.lua:2273-2282)
--   gp:GetActivationHighlightPlots() -> plot indices           (SelectedUnit.lua:127-133)
--   UNITCOMMAND_ACTIVATE_GREAT_PERSON has no InterfaceMode, so the UI fires it
--   in place with NO params (UnitPanel.lua:2497-2513) -- stand on a valid plot
--   first, then RequestCommand.
-- Religion/belief picks after a prophet activates stay MANUAL for now (the
-- game's chooser opens; ~3 clicks once per game) -- programmatic FOUND_RELIGION
-- needs an available-religion enumeration we have not verified yet (issue #7).
local function GetGP(pUnit)
	local ok, gp = pcall(function() return pUnit:GetGreatPerson(); end);
	if not ok or gp == nil then return nil end
	local okIs, is = pcall(function() return gp:IsGreatPerson(); end);
	return (okIs and is == true) and gp or nil;
end

-- Writers/Artists/Musicians activate INTO an empty great-work slot; without
-- one there are no activation plots at all and the GP just churns (live:
-- Machiavelli). Census APIs are the game's own (GreatWorksOverview.lua:117-131
-- HasBuilding+GetNumGreatWorkSlots+GetGreatWorkSlotType, :208 empty == -1;
-- slot-accepts-object via GreatWork_ValidSubTypes; slot buildings enumerated
-- from Building_GreatWorks).
local GP_WORK_OBJECT = {
	GREAT_PERSON_CLASS_WRITER   = "GREATWORKOBJECT_WRITING",
	GREAT_PERSON_CLASS_ARTIST   = "GREATWORKOBJECT_SCULPTURE",
	GREAT_PERSON_CLASS_MUSICIAN = "GREATWORKOBJECT_MUSIC",
};

local g_slotAccepts = nil;   -- [GreatWorkSlotType][GreatWorkObjectType] = true
local function SlotAccepts(slotType, objectType)
	if g_slotAccepts == nil then
		g_slotAccepts = {};
		for row in GameInfo.GreatWork_ValidSubTypes() do
			g_slotAccepts[row.GreatWorkSlotType] = g_slotAccepts[row.GreatWorkSlotType] or {};
			g_slotAccepts[row.GreatWorkSlotType][row.GreatWorkObjectType] = true;
		end
	end
	local t = g_slotAccepts[slotType];
	return t ~= nil and t[objectType] == true;
end

local function CountEmptyCompatibleSlots(pPlayer, objectType)
	local n = 0;
	local okC, cities = pcall(function() return pPlayer:GetCities(); end);
	if not okC or cities == nil then return 0 end
	for _, pCity in cities:Members() do
		local okB, bldgs = pcall(function() return pCity:GetBuildings(); end);
		if okB and bldgs ~= nil then
			for row in GameInfo.Building_GreatWorks() do
				local b = GameInfo.Buildings[row.BuildingType];
				local okH, has = pcall(function() return b ~= nil and bldgs:HasBuilding(b.Index); end);
				if okH and has == true then
					local okN, nSlots = pcall(function() return bldgs:GetNumGreatWorkSlots(b.Index); end);
					for i = 0, (okN and nSlots or 0) - 1 do
						local okE, inSlot = pcall(function() return bldgs:GetGreatWorkInSlot(b.Index, i); end);
						local okT, sType  = pcall(function() return bldgs:GetGreatWorkSlotType(b.Index, i); end);
						local sRow = (okT and sType ~= nil) and GameInfo.GreatWorkSlotTypes[sType] or nil;
						if okE and inSlot == -1 and sRow ~= nil
						   and SlotAccepts(sRow.GreatWorkSlotType, objectType) then
							n = n + 1;
						end
					end
				end
			end
		end
	end
	return n;
end

-- Cheapest non-wonder building that provides a compatible slot (the
-- Amphitheater, for a writer). Production queues it while the GP waits.
local function FindSlotBuildingWish(objectType)
	local best = nil;
	for row in GameInfo.Building_GreatWorks() do
		if SlotAccepts(row.GreatWorkSlotType, objectType) then
			local b = GameInfo.Buildings[row.BuildingType];
			if b ~= nil and not (b.IsWonder == true or b.IsWonder == 1) then
				if best == nil or (b.Cost or 9999) < (best.Cost or 9999) then best = b end
			end
		end
	end
	return best;
end

local function AutomateGreatPerson(pUnit, pPlayer, gp)
	local id = pUnit:GetID();
	local cls = GameInfo.GreatPersonClasses[gp:GetClass()];
	local clsName = (cls ~= nil) and cls.GreatPersonClassType or "?";

	-- PROPHETS use a different verb entirely (audit 2026-07-18, the x23 churn):
	-- the unit OPERATION FOUND_RELIGION (UnitOperations.xml:81; GreatPeople.xml:24
	-- ActionIcon=ICON_UNITOPERATION_FOUND_RELIGION). ACTIVATE_GREAT_PERSON is
	-- never legal for them. CanStart is false until the prophet stands on a
	-- completed Holy Site/Stonehenge -- the plot walk below gets it there.
	if clsName == "GREAT_PERSON_CLASS_PROPHET" then
		local opFound = ResolveOp(UnitOperationTypes.FOUND_RELIGION, "UNITOPERATION_FOUND_RELIGION");
		if CanStart(pUnit, opFound) then
			IssueOp(pUnit, opFound);
			g_gpStrikes[id] = nil;
			Log("great person %d (PROPHET): FOUND_RELIGION at %d,%d", id, pUnit:GetX(), pUnit:GetY());
			return "activate";
		end
	end

	local ok, plots = pcall(function() return gp:GetActivationHighlightPlots(); end);
	if not ok or plots == nil or #plots == 0 then
		-- Nowhere to activate. For writers/artists/musicians the usual reason
		-- is NO empty compatible great-work slot anywhere (live: Machiavelli,
		-- 4/4 moves, needs-orders forever) -- flag production to build one,
		-- then sleep after 3 strikes; a completed build wakes us (#27).
		local objType = GP_WORK_OBJECT[clsName];
		if objType ~= nil and CountEmptyCompatibleSlots(pPlayer, objType) <= 0 then
			g_gpNeedSlot = objType;
			local n = (g_gpStrikes[id] or 0) + 1;
			g_gpStrikes[id] = n;
			LogOnce("gpslot:" .. id,
				"great person %d (%s): NO empty %s slot in the empire -- production queues one (strike %d)",
				id, clsName, objType, n);
			if n >= 3 then
				local opSleep = ResolveOp(UnitOperationTypes.SLEEP, "UNITOPERATION_SLEEP");
				if CanStart(pUnit, opSleep) then
					IssueOp(pUnit, opSleep);
					Log("great person %d (%s): SLEEPING until a slot building completes", id, clsName);
					return "gp-sleep";
				end
			end
			return nil;
		end
		-- Non-slot classes (e.g. prophet before any Holy Site): skip-retry,
		-- NOT sleep -- the valid plot may exist next turn.
		LogOnce("gpnoplot:" .. id, "great person %d (%s): no activation plots yet", id, clsName);
		return nil;
	end

	local here = Map.GetPlotIndex(pUnit:GetX(), pUnit:GetY());
	for _, idx in ipairs(plots) do
		if idx == here then
			-- STRICT gate, arg3=false = "can it RIGHT NOW" (UnitPanel.lua:471).
			-- The old loose-check (arg3=true) is why the command was requested
			-- into a wall 43x: standing on a highlight plot is necessary, NOT
			-- sufficient (the highlight is lens decoration, SelectedUnit.lua:129).
			local okC, can = pcall(function()
				return UnitManager.CanStartCommand(pUnit, UnitCommandTypes.ACTIVATE_GREAT_PERSON, false);
			end);
			if okC and can then
				IssueCmd(pUnit, UnitCommandTypes.ACTIVATE_GREAT_PERSON, nil);
				g_gpStrikes[id] = nil;
				Log("great person %d (%s): ACTIVATING at %d,%d", id, clsName, pUnit:GetX(), pUnit:GetY());
				return "activate";
			end
			-- Refused: name WHY (the engine ships the reason -- e.g. Writers with
			-- no empty great-work slot, InGameText.xml:3015). Command results are
			-- read via UnitOperationResults.FAILURE_REASONS, the game's own
			-- pattern (UnitPanel.lua:522-529).
			local reasons = "";
			local okR, tRes = pcall(function()
				local _, t = UnitManager.CanStartCommand(pUnit, UnitCommandTypes.ACTIVATE_GREAT_PERSON, false, true);
				return t;
			end);
			if okR and tRes ~= nil and tRes[UnitOperationResults.FAILURE_REASONS] ~= nil then
				for _, s in ipairs(tRes[UnitOperationResults.FAILURE_REASONS]) do
					local okL, txt = pcall(function() return Locale.Lookup(s); end);
					reasons = reasons .. " | " .. tostring(okL and txt or s);
				end
			end
			-- On-plot refusal for a slot class usually means the highlighted
			-- slot is FILLED (live: writer on the palace plot, refused, no
			-- reason string) -- run the same census and flag production for a
			-- new slot building, exactly like the no-plots path.
			local objType2 = GP_WORK_OBJECT[clsName];
			if objType2 ~= nil and CountEmptyCompatibleSlots(pPlayer, objType2) <= 0 then
				g_gpNeedSlot = objType2;
				LogOnce("gpslot:" .. id,
					"great person %d (%s): refused on plot AND no empty %s slot -- production queues one",
					id, clsName, objType2);
			end
			-- Structural refusals do not clear by retrying: 3 strikes -> SLEEP.
			-- Any finished city build resets strikes and WAKES sleeping GPs
			-- (slots arrive with buildings).
			local n = (g_gpStrikes[id] or 0) + 1;
			g_gpStrikes[id] = n;
			LogOnce("gprefuse:" .. id, "great person %d (%s): on plot, refused (strike %d)%s", id, clsName, n,
				reasons ~= "" and reasons or " | no reason given");
			if n >= 3 then
				local opSleep = ResolveOp(UnitOperationTypes.SLEEP, "UNITOPERATION_SLEEP");
				if CanStart(pUnit, opSleep) then
					IssueOp(pUnit, opSleep);
					Log("great person %d (%s): 3 activation refusals -> SLEEPING until a build completes (needs a slot?)", id, clsName);
					return "gp-sleep";
				end
			end
			return nil;
		end
	end

	-- Walk to the nearest activation plot -- skipping plots OCCUPIED by another
	-- of our civilians (live: Donatello marched at sleeping Machiavelli's tile
	-- to the re-task cap, every turn -- two civilians cannot stack, the engine
	-- accepts the move and then drops it).
	local best, bestD = nil, 9999;
	for _, idx in ipairs(plots) do
		local plot = Map.GetPlotByIndex(idx);
		if plot ~= nil then
			local blocked = false;
			if not (plot:GetX() == pUnit:GetX() and plot:GetY() == pUnit:GetY()) then
				local okL, lst = pcall(function()
					return Units.GetUnitsInPlotLayerID(plot:GetX(), plot:GetY(), MapLayers.ANY);
				end);
				if okL and lst ~= nil then
					for _, u2 in ipairs(lst) do
						if u2:GetOwner() == pPlayer:GetID() and u2:GetID() ~= id then
							local i2 = GameInfo.Units[u2:GetUnitType()];
							if i2 ~= nil and i2.FormationClass == "FORMATION_CLASS_CIVILIAN" then
								blocked = true; break;
							end
						end
					end
				end
			end
			if not blocked then
				local d = Map.GetPlotDistance(pUnit:GetX(), pUnit:GetY(), plot:GetX(), plot:GetY());
				if d < bestD then bestD, best = d, plot end
			end
		end
	end
	if best ~= nil and MoveTo(pUnit, best:GetX(), best:GetY()) then
		LogOnce("gphead:" .. id, "great person %d (%s): heading to activation plot %d,%d", id, clsName, best:GetX(), best:GetY());
		return "move";
	end
	-- Every activation plot is occupied/unreachable: same treatment as
	-- no-plots -- flag the slot need if applicable and let the strikes park us.
	local objType3 = GP_WORK_OBJECT[clsName];
	if objType3 ~= nil and CountEmptyCompatibleSlots(pPlayer, objType3) <= 0 then
		g_gpNeedSlot = objType3;
	end
	local n3 = (g_gpStrikes[id] or 0) + 1;
	g_gpStrikes[id] = n3;
	LogOnce("gpwalk:" .. id, "great person %d (%s): all activation plots occupied/unreachable (strike %d)", id, clsName, n3);
	if n3 >= 3 then
		local opSleep = ResolveOp(UnitOperationTypes.SLEEP, "UNITOPERATION_SLEEP");
		if CanStart(pUnit, opSleep) then
			IssueOp(pUnit, opSleep);
			Log("great person %d (%s): SLEEPING until a build completes", id, clsName);
			return "gp-sleep";
		end
	end
	return nil;
end

-- -------------------------------------------------------- army cohesion ------
--
-- "My combat units must stay near each other and work together."
--
-- Left alone, every unit fought its own private war: each one independently
-- walked at the nearest enemy, so they arrived one at a time and died one at a
-- time -- a trickle of single units into a defended tile, which is the worst way
-- to lose an army. Civ6 has no unit stacking, so an "army" here can only mean a
-- LOOSE GROUP: units within ARMY_RADIUS of the group's centre of mass, arriving
-- within a turn or two of each other.
--
-- The doctrine:
--   * You may ALWAYS defend yourself and always hit something already adjacent.
--     Cohesion never stops a unit from fighting what is on top of it.
--   * You may only ADVANCE on an objective as part of a group. Alone, you walk
--     to the rally point and wait for the others instead of feeding yourself in.
local ARMY_RADIUS    = 3   -- within this of the group's centre counts as "together"
local ARMY_MIN_GROUP = 3   -- fewer than this together -> muster, do not advance

-- Our land combat units (scouts excluded -- they explore, they are not the army).
local function BuildArmyCache(pPlayer)
	local t = {};
	local ok, units = pcall(function() return pPlayer:GetUnits(); end);
	if not ok or units == nil then return t end
	for _, u in units:Members() do
		if not u:IsDead() and IsCombatUnit(u) and not IsRecon(u) then
			local info = GameInfo.Units[u:GetUnitType()];
			if info ~= nil and info.Domain == "DOMAIN_LAND" then
				t[#t + 1] = { id = u:GetID(), x = u:GetX(), y = u:GetY() };
			end
		end
	end
	return t;
end

-- The rally point: the group's centre of mass, SNAPPED to the member standing
-- nearest it. The raw average of a set of hexes routinely lands in the ocean, on
-- a mountain, or somewhere nothing can path to; a tile one of our own units is
-- already standing on is always a real, reachable, land tile.
local function ArmyRally(army)
	if #army == 0 then return nil end
	local sx, sy = 0, 0;
	for _, a in ipairs(army) do sx = sx + a.x; sy = sy + a.y end
	local cx, cy = math.floor(sx / #army + 0.5), math.floor(sy / #army + 0.5);
	local best, bestD = nil, 9999;
	for _, a in ipairs(army) do
		local d = Map.GetPlotDistance(a.x, a.y, cx, cy);
		if d < bestD then bestD = d; best = a end
	end
	return best;
end

-- How many of ours are within ARMY_RADIUS of (x,y) -- counts the asking unit
-- itself, so "3" means it plus two friends.
local function GroupSizeNear(army, x, y)
	local n = 0;
	for _, a in ipairs(army) do
		if Map.GetPlotDistance(x, y, a.x, a.y) <= ARMY_RADIUS then n = n + 1 end
	end
	return n;
end

-- Is this unit cohesive enough to advance? Note the min() -- with only two units
-- on the whole map, demanding three together would freeze the army forever, so
-- a small army just has to travel as the pair it is.
local function IsCohesive(army, x, y)
	local need = math.min(ARMY_MIN_GROUP, #army);
	if need <= 1 then return true end
	return GroupSizeNear(army, x, y) >= need;
end

-- Support units walk to the army and stay with it; with no army they garrison
-- the nearest city. One skip per turn beats the old sleep-forever (#31): a
-- slept ram never showed up for the siege it exists for.
local function AutomateSupportUnit(pUnit, pPlayer, army)
	local x, y = pUnit:GetX(), pUnit:GetY();
	if army ~= nil and #army > 0 then
		for _, a in ipairs(army) do
			if Map.GetPlotDistance(x, y, a.x, a.y) <= 1 then
				if CanStart(pUnit, UnitOperationTypes.SKIP_TURN) then
					IssueOp(pUnit, UnitOperationTypes.SKIP_TURN);
					return "hold";
				end
				return nil;
			end
		end
		local rally = ArmyRally(army);
		if rally ~= nil and MoveTo(pUnit, rally.x, rally.y) then
			Log("support %d: joining the army at %d,%d", pUnit:GetID(), rally.x, rally.y);
			return "join";
		end
	end
	local home = NearestOwnCityPlot(pPlayer, x, y);
	if home ~= nil and not (home:GetX() == x and home:GetY() == y)
	   and MoveTo(pUnit, home:GetX(), home:GetY()) then
		Log("support %d: no army nearby -> garrisoning %d,%d", pUnit:GetID(), home:GetX(), home:GetY());
		return "garrison";
	end
	if CanStart(pUnit, UnitOperationTypes.SKIP_TURN) then
		IssueOp(pUnit, UnitOperationTypes.SKIP_TURN);
		return "hold";
	end
	return nil;
end

-- -------------------------------------------------------------- military ----

local function BestRangedTarget(pUnit, eLocalPlayer, pDiplo, pVis)
	local ok, pResults = pcall(function()
		return UnitManager.GetOperationTargets(pUnit, UnitOperationTypes.RANGE_ATTACK);
	end);
	if not ok or pResults == nil then return nil end
	local plots = pResults[UnitOperationResults.PLOTS];
	local mods  = pResults[UnitOperationResults.MODIFIERS];
	if plots == nil or mods == nil then return nil end
	local best, bestScore = nil, -1;
	for i, m in ipairs(mods) do
		if m == UnitOperationResults.MODIFIER_IS_TARGET then
			local plot = Map.GetPlotByIndex(plots[i]);
			if plot ~= nil then
				local score = 1;
				local e = GetEnemyOnPlot(plot, eLocalPlayer, pDiplo, pVis);
				if e ~= nil then
					score = 200 - HPPercent(e);   -- prefer finishing off wounded units
					-- Focus fire (issue #6): a likely KILL dominates every other
					-- consideration -- a dead unit deals no damage back, ever.
					if HPPercent(e) <= 35 then score = score + 200 end
				elseif plot:IsCity() then
					-- The city you told us to take outranks incidental cities, but
					-- still yields to a killable field unit (those shoot back).
					if g_target ~= nil and plot:GetX() == g_target.x and plot:GetY() == g_target.y then
						score = 150;
					else
						score = 60;               -- chip other enemy cities when nothing better
					end
				end
				if score > bestScore then bestScore = score; best = plot end
			end
		end
	end
	return best;
end

local function BestMeleeTarget(pUnit, eLocalPlayer, pDiplo, pVis, myStr, extraMargin)
	local ok, reach = pcall(function() return UnitManager.GetReachableTargets(pUnit); end);
	if not ok or reach == nil then return nil end
	local best, bestScore = nil, -1;
	for _, idx in ipairs(reach) do
		local plot = Map.GetPlotByIndex(idx);
		local e = GetEnemyOnPlot(plot, eLocalPlayer, pDiplo, pVis);
		if e ~= nil then
			local eStr = math.max(e:GetCombat(), e:GetRangedCombat());
			local eHp  = HPPercent(e);
			if (myStr >= eStr - MELEE_STR_MARGIN - (extraMargin or 0)) or (eHp <= MELEE_WOUNDED_HP) then
				local score = (myStr - eStr) + (100 - eHp);
				-- Focus fire (issue #6): kill-shots first, always.
				if eHp <= 35 then score = score + 200 end
				if score > bestScore then bestScore = score; best = plot end
			end
		end
	end

	-- Nothing worth hitting in the field? If we are on an assault and the target
	-- city itself is reachable, hit the city. Scored below any real unit kill:
	-- field units shoot back, cities do not chase you.
	if best == nil and g_target ~= nil then
		for _, idx in ipairs(reach) do
			local plot = Map.GetPlotByIndex(idx);
			if plot ~= nil and plot:GetX() == g_target.x and plot:GetY() == g_target.y
			   and IsEnemyCityPlot(plot, eLocalPlayer, pDiplo, pVis) then
				return plot;
			end
		end
	end
	return best;
end

-- Nearest revealed enemy city (advance objective).
local function NearestEnemyObjective(pUnit, eLocalPlayer, pDiplo, pVis)
	local ux, uy = pUnit:GetX(), pUnit:GetY();
	local best, bestDist = nil, 9999;
	for pid = 0, 62 do
		local p = Players[pid];
		if p ~= nil and pid ~= eLocalPlayer and p:IsAlive() and pDiplo:IsAtWarWith(pid) then
			local ok, cities = pcall(function() return p:GetCities(); end);
			if ok and cities ~= nil then
				for _, city in cities:Members() do
					local cx, cy = city:GetX(), city:GetY();
					if pVis ~= nil and pVis:IsRevealed(cx, cy) then
						local d = Map.GetPlotDistance(ux, uy, cx, cy);
						if d < bestDist then bestDist = d; best = { x = cx, y = cy } end
					end
				end
			end
		end
	end
	return best;
end

-- Move one safe step toward an objective. Pass obj to force a destination
-- (the ATTACK target); pass nil to fall back to the nearest known enemy city.
-- Returns true if it moved.
local function AdvanceToward(pUnit, eLocalPlayer, pDiplo, pVis, myStr, obj, threats)
	obj = obj or NearestEnemyObjective(pUnit, eLocalPlayer, pDiplo, pVis);
	-- Barbarians have no cities, so against them the objective list above is
	-- always empty and "advance" used to go nowhere -- camps festered and
	-- raiders were only hit once they walked into attack reach. Fall back to
	-- marching on the nearest visible threat.
	if obj == nil and threats ~= nil then
		local ux, uy = pUnit:GetX(), pUnit:GetY();
		local bestD = nil;
		for _, th in ipairs(threats) do
			local d = Map.GetPlotDistance(ux, uy, th.x, th.y);
			if bestD == nil or d < bestD then bestD = d; obj = { x = th.x, y = th.y } end
		end
	end
	if obj == nil then return false end
	local ux, uy = pUnit:GetX(), pUnit:GetY();
	local curDist = Map.GetPlotDistance(ux, uy, obj.x, obj.y);
	local ok, reach = pcall(function() return UnitManager.GetReachableMovement(pUnit); end);
	if not ok or reach == nil then return false end
	-- On an ordered assault we accept contact: a city is always ringed by its own
	-- defenders, so the plain "never step next to something stronger" rule would
	-- park the whole army one tile short forever. Closing to the objective is the
	-- order. Off-assault we keep the cautious rule.
	local isAssault = (g_target ~= nil and obj.x == g_target.x and obj.y == g_target.y);

	local best, bestDist = nil, curDist;
	for _, idx in ipairs(reach) do
		local plot = Map.GetPlotByIndex(idx);
		if plot ~= nil and not (plot:GetX() == ux and plot:GetY() == uy) then
			local px, py = plot:GetX(), plot:GetY();
			local d = Map.GetPlotDistance(px, py, obj.x, obj.y);
			if d < bestDist then
				local threat  = StrongestAdjacentEnemy(px, py, eLocalPlayer, pDiplo, pVis);
				local touching = (Map.GetPlotDistance(px, py, obj.x, obj.y) <= 1);
				if threat <= myStr or (isAssault and touching) then
					bestDist = d; best = plot;
				end
			end
		end
	end
	if best ~= nil then
		local tParams = {
			[UnitOperationTypes.PARAM_X] = best:GetX(),
			[UnitOperationTypes.PARAM_Y] = best:GetY(),
			[UnitOperationTypes.PARAM_MODIFIERS] = UnitOperationMoveModifiers.NONE,
		};
		if CanStart(pUnit, UnitOperationTypes.MOVE_TO, tParams) then
			IssueOp(pUnit,UnitOperationTypes.MOVE_TO, tParams);
			return true;
		end
	end
	return false;
end

local function AutomateCombatUnit(pUnit, eLocalPlayer, pDiplo, pVis, threats, army)
	local x, y   = pUnit:GetX(), pUnit:GetY();
	local hp     = HPPercent(pUnit);
	local myStr  = math.max(pUnit:GetCombat(), pUnit:GetRangedCombat());
	local ranged = IsRanged(pUnit);

	-- CITY DEFENSE MODE (#25, Anthony's doctrine): a soldier near a threatened
	-- own city is a defender before it is anything else -- no rallying away, no
	-- escort detours, and near-even fights are taken (fortify + city strike tip
	-- them our way). Scouts never get here (recon branch), so this is soldiers only.
	local defending = (g_defcity ~= nil
		and Map.GetPlotDistance(x, y, g_defcity.x, g_defcity.y) <= CITY_DEFENDER_PULL);

	-- A) Attack. Ranged fires from safety; melee only hits weaker/wounded foes.
	-- Only if the unit actually has an attack left: the base game gates its own
	-- target display on this (SelectedUnit.lua:62), and without it a spent unit
	-- burns its whole move walking onto a target it cannot hit.
	local okAtk, attacksLeft = pcall(function() return pUnit:GetAttacksRemaining() end);
	local canAttack = (not okAtk) or attacksLeft == nil or attacksLeft > 0;

	-- Linked state, computed ONCE (audit #7): a linked soldier's melee charge
	-- MOVES the stack -- it dragged the settler/builder into the fight the
	-- formation exists to shield it from.
	local okFm, fmN = pcall(function() return pUnit:GetFormationUnitCount(); end);
	local isLinked = (okFm and fmN ~= nil and fmN > 1);

	-- Branch on unit class INSIDE the attack gate: `ranged and canAttack ...
	-- else melee` would drop a ranged unit that had already fired into the
	-- melee branch and charge it into the enemy it just shot at.
	if canAttack then
		if ranged then
			local target = BestRangedTarget(pUnit, eLocalPlayer, pDiplo, pVis);
			if target ~= nil then
				local tParams = { [UnitOperationTypes.PARAM_X] = target:GetX(), [UnitOperationTypes.PARAM_Y] = target:GetY() };
				if CanStart(pUnit, UnitOperationTypes.RANGE_ATTACK, tParams) then
					IssueOp(pUnit,UnitOperationTypes.RANGE_ATTACK, tParams);
					return "range";
				end
			end
		elseif not isLinked then
			local target = BestMeleeTarget(pUnit, eLocalPlayer, pDiplo, pVis, myStr,
				defending and DEFENSE_STR_MARGIN or 0);
			if target ~= nil then
				local tParams = {
					[UnitOperationTypes.PARAM_X] = target:GetX(),
					[UnitOperationTypes.PARAM_Y] = target:GetY(),
					[UnitOperationTypes.PARAM_MODIFIERS] = UnitOperationMoveModifiers.ATTACK,
				};
				if CanStart(pUnit, UnitOperationTypes.MOVE_TO, tParams) then
					IssueOp(pUnit,UnitOperationTypes.MOVE_TO, tParams);
					return "attack";
				end
			end
		end
	end

	-- A2) LINKED ESCORT (Anthony's link tip): in a formation with a civilian
	--     the CIVILIAN drives the stack -- issuing this soldier a move would
	--     drag the settler/builder wherever the army brain points. Shoot from
	--     where we stand (branch A already ran), then hold. Membership test:
	--     GetFormationUnitCount() > 1 (UnitPanel.lua:2239). When the partner
	--     is a builder and danger has passed, UNLINK (UNITCOMMAND_EXIT_FORMATION,
	--     UnitCommands.xml:17) so the soldier rejoins the army; settler links
	--     persist until the founding dissolves them.
	if isLinked then
		local withSettler = false;
		local okU2, us2 = pcall(function() return Players[eLocalPlayer]:GetUnits(); end);
		if okU2 and us2 ~= nil then
			for _, u in us2:Members() do
				if not u:IsDead() and u:GetX() == x and u:GetY() == y and IsSettler(u) then
					withSettler = true; break;
				end
			end
		end
		-- Hysteresis (link at <=8, release only past 10): the old release-at->5
		-- fought the link gate and flapped the pair in the 5-8 band.
		local dHere = NearestThreatDist(threats, x, y);
		if not withSettler and (dHere == nil or dHere > 10) then
			local okX, canX = pcall(function()
				return UnitManager.CanStartCommand(pUnit, UnitCommandTypes.EXIT_FORMATION, nil, false);
			end);
			if okX and canX == true then
				IssueCmd(pUnit, UnitCommandTypes.EXIT_FORMATION, {});
				Log("unit %d: threat clear -> UNLINKED from civilian", pUnit:GetID());
				return "unlink";
			end
		end
		if CanStart(pUnit, UnitOperationTypes.FORTIFY) then
			IssueOp(pUnit, UnitOperationTypes.FORTIFY);
			return "linked";
		end
		if CanStart(pUnit, UnitOperationTypes.SKIP_TURN) then
			IssueOp(pUnit, UnitOperationTypes.SKIP_TURN);
			return "linked";
		end
		return nil;
	end

	-- B0) PILLAGE-HEAL: standing on enemy tile-works while wounded, pillaging
	-- pays gold/faith AND heals 25 HP -- strictly better than walking away to
	-- heal. CanStart carries all the legality (ownership, at-war, moves left).
	if hp < 100 and not defending and CanStart(pUnit, UnitOperationTypes.PILLAGE) then
		IssueOp(pUnit, UnitOperationTypes.PILLAGE);
		Log("unit %d: PILLAGING at %d,%d (hp %d)", pUnit:GetID(), x, y, hp);
		return "pillage";
	end

	-- B) Wounded and safe -> heal (fortify until healed). Under fire -> RUN:
	-- an hp=1 warrior sat adjacent to an enemy with no escape branch (live,
	-- India session) because heal required a clear tile. ScoutRetreat's
	-- step-away logic works for any land unit.
	if hp < HEAL_HP_THRESHOLD then
		if StrongestAdjacentEnemy(x, y, eLocalPlayer, pDiplo, pVis) == 0 then
			if CanStart(pUnit, UnitOperationTypes.HEAL) then
				IssueOp(pUnit,UnitOperationTypes.HEAL);
				return "heal";
			end
		elseif ScoutRetreat(pUnit, Players[eLocalPlayer], threats) then
			return "retreat";
		end
	end

	-- B2) ESCORT (issue #19, Anthony's direction): a settler without a shadow
	-- is a barbarian gift. If an own settler is nearby and no other army
	-- member is closer, shadow it -- this outranks advancing on enemies.
	-- Suspended in defense mode: cities first and foremost (#25).
	local pP = Players[eLocalPlayer];
	local okS, units = pcall(function() return pP:GetUnits(); end);
	if okS and units ~= nil and not defending then
		for _, u in units:Members() do
			-- Escort UNLINKED civilians: settlers always; builders when danger
			-- is near them (Anthony: captures keep happening -- the shield must
			-- be DELIVERED, not hoped for). A linked civilian needs nothing.
			local isWard = false;
			if not u:IsDead() then
				local okFmW, fmW = pcall(function() return u:GetFormationUnitCount(); end);
				local uLinked = (okFmW and fmW ~= nil and fmW > 1);
				if not uLinked then
					if IsSettler(u) then
						isWard = true;
					elseif IsBuilder(u) then
						local dW = NearestThreatDist(threats, u:GetX(), u:GetY(), true);
						isWard = (dW ~= nil and dW <= 8);
					end
				end
			end
			if isWard then
				local dMe = Map.GetPlotDistance(x, y, u:GetX(), u:GetY());
				if dMe <= 6 then
					local closest = true;
					if army ~= nil then
						for _, a in ipairs(army) do
							if a.id ~= pUnit:GetID()
							   and Map.GetPlotDistance(a.x, a.y, u:GetX(), u:GetY()) < dMe then
								closest = false; break;
							end
						end
					end
					if closest and dMe >= 1 then
						-- Move ONTO the civilian's tile: formation linking
						-- (ENTER_FORMATION) requires sharing it. The civilian
						-- links next pass and the pair moves as one stack.
						if MoveTo(pUnit, u:GetX(), u:GetY()) then
							Log("unit %d: escorting civilian %d", pUnit:GetID(), u:GetID());
							return "escort";
						end
					elseif closest then
						break;   -- same tile; the civilian links the formation
					end
				end
			end
		end
	end

	-- C) COHESION GATE. Everything above this line is self-defence and is never
	--     gated: if something is adjacent you shoot it, if you are hurt you heal.
	--     Everything BELOW is marching on an objective, and marching is a group
	--     action. A lone unit walks to the rally point and waits for the others
	--     rather than arriving by itself and dying by itself.
	if army ~= nil and #army > 0 and not defending and not IsCohesive(army, x, y) then
		-- Never rally AWAY from an enemy that is already on top of us. The wake
		-- branch exists precisely to make lone garrisons defend; sending them
		-- marching to the army's centre of mass would un-fix that bug. Contact
		-- range -> hold here, fight with the attack logic above next pass.
		local dHere = NearestThreatDist(threats, x, y);
		if dHere ~= nil and dHere <= 2 then
			-- SKIP, not FORTIFY: the engine re-wakes fortified units in enemy
			-- contact instantly, so fortify here is a revolving door -- accepted,
			-- dropped, reissued, four times to the cap, every single turn
			-- (warrior 458757 live). Skip is turn-scoped and sticks.
			if CanStart(pUnit, UnitOperationTypes.SKIP_TURN) then
				IssueOp(pUnit,UnitOperationTypes.SKIP_TURN);
				return "stand";
			end
			if CanStart(pUnit, UnitOperationTypes.FORTIFY) then
				IssueOp(pUnit,UnitOperationTypes.FORTIFY);
				return "stand";
			end
			Log("combat %d declined AT COHESION GATE: threat<=2, skip+fortify both refused", pUnit:GetID());
			return nil;
		end
		local rally = ArmyRally(army);
		if rally ~= nil and rally.id ~= pUnit:GetID() then
			-- #24: the engine can ACCEPT a rally MOVE_TO and then refuse the path
			-- (warrior 393220 re-issued the same rally 23 turns straight). Rally
			-- attempts from an UNCHANGED position get 3 tries, then this unit
			-- holds ~10 turns before asking again.
			local id, turn = pUnit:GetID(), Game.GetCurrentGameTurn();
			local st = g_rallyStuck[id];
			if st ~= nil and (st.x ~= x or st.y ~= y) then st = nil; g_rallyStuck[id] = nil end
			if st ~= nil and st.n >= 3 and turn < st.holdUntil then
				LogOnce("rallyhold:" .. id,
					"unit %d: rally unreachable from %d,%d (3 strikes) -> holding until t%d",
					id, x, y, st.holdUntil);
				-- SKIP, not the fortify below (audit #26): a fortified unit stops
				-- reading AWAKE, so the "10-turn hold" never actually ended --
				-- the unit vanished from the sweep permanently.
				if CanStart(pUnit, UnitOperationTypes.SKIP_TURN) then
					IssueOp(pUnit, UnitOperationTypes.SKIP_TURN);
					return "hold";
				end
				-- fall through to fortify/muster below
			elseif MoveTo(pUnit, rally.x, rally.y) then
				if st == nil then st = { x = x, y = y, n = 0, holdUntil = 0 }; g_rallyStuck[id] = st end
				st.n = st.n + 1;
				if st.n >= 3 then st.holdUntil = turn + 10 end
				Log("unit %d: alone (%d near) -> rallying to %d,%d",
					id, GroupSizeNear(army, x, y), rally.x, rally.y);
				return "rally";
			end
		end
		-- We ARE the rally point, or cannot path to it: hold here and let the
		-- group form up around us. Fortifying while waiting is free defence.
		if CanStart(pUnit, UnitOperationTypes.FORTIFY) then
			IssueOp(pUnit,UnitOperationTypes.FORTIFY);
			return "muster";
		end
		return nil;
	end

	-- C2) DEFENSE CONVERGE (#25). In defense mode with nothing in attack reach:
	--     close on the threatened city and hold the ring there. This replaces
	--     the rally/advance behaviour entirely while a city is under threat.
	if defending then
		local dCity = Map.GetPlotDistance(x, y, g_defcity.x, g_defcity.y);
		-- HUNT FIRST (audit #25 oscillation fix): converge used to run before
		-- this, and MoveTo(city) always succeeded at dCity>1 -- so every hunt
		-- step got yanked straight back to the city next pass and a mobile
		-- raider was never pinned. Land threats only: melee cannot hunt boats.
		-- (Original hunt rationale -- Delhi, barb camped 2-3 out for ~15 turns
		-- while every defender fortified. DEFENSE_STR_MARGIN mirrors the melee
		-- gate: near-even is acceptable at home.)
		local dHunt = NearestThreatDist(threats, x, y, not IsRanged(pUnit));
		if dHunt ~= nil and dHunt <= 4 then
			if AdvanceToward(pUnit, eLocalPlayer, pDiplo, pVis, myStr + DEFENSE_STR_MARGIN, nil, threats) then
				Log("unit %d: DEFENDING %s -> hunting raider (%d out)",
					pUnit:GetID(), tostring(g_defcity.name), dHunt);
				return "hunt";
			end
		end
		if dCity > 1 then
			if MoveTo(pUnit, g_defcity.x, g_defcity.y) then
				Log("unit %d: DEFENDING %s -> converging (%d tiles out)",
					pUnit:GetID(), tostring(g_defcity.name), dCity);
				return "defend";
			end
		end
		-- At the city or pathless: hold. SKIP first when in contact (fortify is
		-- a revolving door next to enemies -- the cohesion-gate lesson), fortify
		-- otherwise for the defense bonus. Logged (rule #5): this hold was
		-- invisible and swallowed the "why no attack" question for a session.
		LogOnce("dhold:" .. pUnit:GetID(),
			"unit %d: defend-hold (dCity=%d threat=%s atkLeft=%s)",
			pUnit:GetID(), dCity, tostring(dHunt), tostring(okAtk and attacksLeft or "?"));
		local dHere = NearestThreatDist(threats, x, y);
		if dHere ~= nil and dHere <= 1 then
			if CanStart(pUnit, UnitOperationTypes.SKIP_TURN) then
				IssueOp(pUnit, UnitOperationTypes.SKIP_TURN);
				return "garrison";
			end
		end
		if CanStart(pUnit, UnitOperationTypes.FORTIFY) then
			IssueOp(pUnit, UnitOperationTypes.FORTIFY);
			return "garrison";
		end
		if CanStart(pUnit, UnitOperationTypes.SKIP_TURN) then
			IssueOp(pUnit, UnitOperationTypes.SKIP_TURN);
			return "garrison";
		end
	end

	-- D) An explicit ATTACK order overrides everything: march on THAT city.
	--     Still respects healing above, so a broken unit pulls back rather than
	--     feeding itself to the walls one at a time.
	if g_target ~= nil and hp >= HEAL_HP_THRESHOLD then
		if AdvanceToward(pUnit, eLocalPlayer, pDiplo, pVis, myStr, g_target, threats) then
			return "assault";
		end
	end

	-- E) Optional: march on the nearest enemy along safe tiles (higher risk).
	if g_advance and hp >= HEAL_HP_THRESHOLD then
		if AdvanceToward(pUnit, eLocalPlayer, pDiplo, pVis, myStr, nil, threats) then
			return "advance";
		end
	end

	-- E2) Nothing to advance on, but enemy tile-works underfoot: wreck them.
	--     Gold + a 25 HP heal beats a plain fortify every time we are at war
	--     and the treasury is bleeding (Anthony: units always have things to do).
	if not defending and CanStart(pUnit, UnitOperationTypes.PILLAGE) then
		IssueOp(pUnit, UnitOperationTypes.PILLAGE);
		Log("unit %d: PILLAGING at %d,%d", pUnit:GetID(), x, y);
		return "pillage";
	end

	-- F) Hold the line. Returning nil (not "hold") when BOTH ops are refused is
	--    load-bearing: nil is the caller's signal that nothing was issued and the
	--    catch-all must take over. Claiming "hold" here while issuing nothing is
	--    the exact shape of the bug this whole pass exists to kill.
	if CanStart(pUnit, UnitOperationTypes.FORTIFY) then
		IssueOp(pUnit,UnitOperationTypes.FORTIFY);
		return "fortify";
	end
	if CanStart(pUnit, UnitOperationTypes.SKIP_TURN) then
		IssueOp(pUnit,UnitOperationTypes.SKIP_TURN);
		return "hold";
	end
	-- Issue #6 diagnostics: name WHY the combat brain declined, so army
	-- passivity is diagnosable from the log instead of guessed at.
	local dT = NearestThreatDist(threats, x, y);
	LogOnce("cdecl:" .. pUnit:GetID(),
		"combat %d declined: hp=%d str=%d threat=%s cohesive=%s target=%s advance=%s",
		pUnit:GetID(), hp, myStr, tostring(dT),
		tostring(army == nil or IsCohesive(army, x, y)),
		tostring(g_target ~= nil), tostring(g_advance));
	return nil;
end

-- --------------------------------------------------- research & civics ------
--
-- We do NOT invent a tech priority. The game already ships a strategist --
-- GetGrandStrategicAI() -- which is what draws the little advisor star in the
-- tech tree, and it is tuned to the civ, the era and the victory type you are
-- actually chasing. We just take its top pick and commit it the moment a slot
-- goes idle. Same call the tech tree makes when you click a node.

-- Pick the highest-scored recommendation that is still legal, else any legal one.
-- getHash/getScore pull the differently-named fields out of the recommendation row.
local function ChooseFromRecommendations(recs, isLegalHash, getHash, getScore)
	local bestHash, bestScore = nil, nil;
	if recs ~= nil then
		for _, rec in pairs(recs) do
			local h = getHash(rec);
			if h ~= nil and isLegalHash(h) then
				local s = getScore(rec) or 0;
				if bestScore == nil or s > bestScore then bestScore = s; bestHash = h end
			end
		end
	end
	return bestHash;
end

local function AutomateResearch(pPlayer)
	if g_researchDone then return false end   -- request is async (audit #32:
	                                          -- re-logged/re-requested per pass)
	local pTechs = pPlayer:GetTechs();
	if pTechs == nil then return false end
	if pTechs:GetResearchingTech() ~= -1 then return false end   -- already busy

	local legal = {};   -- hash -> index, only techs we may actually start
	for kTech in GameInfo.Technologies() do
		if pTechs:CanResearch(kTech.Index) then legal[kTech.Hash] = kTech.Index end
	end
	if next(legal) == nil then return false end

	local hash = nil;
	local pGrandAI = pPlayer:GetGrandStrategicAI();
	if pGrandAI ~= nil then
		local ok, recs = pcall(function() return pGrandAI:GetTechRecommendations(); end);
		if ok then
			hash = ChooseFromRecommendations(recs,
				function(h) return legal[h] ~= nil end,
				function(r) return r.TechHash end,
				function(r) return r.TechScore end);
		end
	end
	if hash == nil then hash = next(legal) end   -- AI had no opinion: take any legal tech

	local kTech = GameInfo.Technologies[legal[hash]];
	Log("auto-research -> %s", (kTech ~= nil and kTech.TechnologyType) or tostring(hash));

	local tParameters = {};
	tParameters[PlayerOperations.PARAM_TECH_TYPE]   = hash;
	tParameters[PlayerOperations.PARAM_INSERT_MODE] = PlayerOperations.VALUE_EXCLUSIVE;
	UI.RequestPlayerOperation(Game.GetLocalPlayer(), PlayerOperations.RESEARCH, tParameters);
	g_researchDone = true;
	return true;
end

local function AutomateCivics(pPlayer)
	if g_civicDone then return false end   -- async, same as research
	local pCulture = pPlayer:GetCulture();
	if pCulture == nil then return false end
	if pCulture:GetProgressingCivic() ~= -1 then return false end   -- already busy

	local legal = {};
	for kCivic in GameInfo.Civics() do
		if pCulture:CanProgress(kCivic.Index) then legal[kCivic.Hash] = kCivic.Index end
	end
	if next(legal) == nil then return false end

	local hash = nil;
	local pGrandAI = pPlayer:GetGrandStrategicAI();
	if pGrandAI ~= nil then
		local ok, recs = pcall(function() return pGrandAI:GetCivicsRecommendations(); end);
		if ok then
			hash = ChooseFromRecommendations(recs,
				function(h) return legal[h] ~= nil end,
				function(r) return r.CivicHash end,
				function(r) return r.CivicScore end);
		end
	end
	if hash == nil then hash = next(legal) end

	local kCivic = GameInfo.Civics[legal[hash]];
	Log("auto-civic -> %s", (kCivic ~= nil and kCivic.CivicType) or tostring(hash));

	local tParameters = {};
	tParameters[PlayerOperations.PARAM_CIVIC_TYPE]  = hash;
	tParameters[PlayerOperations.PARAM_INSERT_MODE] = PlayerOperations.VALUE_EXCLUSIVE;
	UI.RequestPlayerOperation(Game.GetLocalPlayer(), PlayerOperations.PROGRESS_CIVIC, tParameters);
	g_civicDone = true;
	return true;
end

-- ------------------------------------------------------------------ envoys ---
--
-- Unspent envoys are free suzerainty left on the table, and the "you have envoys
-- to give" prompt is one more thing between Anthony and a turn that ends itself.
--
-- Strategy: CONCENTRATE. Reinforce a city-state we already lead (cheapest
-- suzerainty to hold, and suzerainty is where the real bonuses live), otherwise
-- back the one where we are closest to taking the lead. Spreading envoys evenly
-- is the classic beginner mistake -- one envoy at six city-states buys almost
-- nothing; three at one buys a suzerain bonus.
--
-- Verified API (UI/PartialScreens/CityStates.lua -- note: PartialScreens, there
-- is no UI/CityStates.lua):
--   :1425-1429  localInf:GetTokensToGive() / localInf:CanGiveInfluence()
--   :1499       localInf:CanGiveTokensToPlayer(cityStatePlayerID)
--   :1449-1458  csInf:GetTokensReceived(majorID) / :GetMostTokensReceived()
--               / :GetSuzerain() / :CanReceiveInfluence()
--   :757-759    parameters[PlayerOperations.PARAM_PLAYER_ONE] = cityStatePlayerID
--               UI.RequestPlayerOperation(playerID, PlayerOperations.GIVE_INFLUENCE_TOKEN, parameters)
--               -- ONE token per call; the game's own UI loops to send several.
local function AutomateEnvoys(pPlayer)
	if g_envoyDone then return false end

	local eLocal = pPlayer:GetID();
	local inf    = pPlayer:GetInfluence();
	if inf == nil then return false end

	local okC, canGive = pcall(function() return inf:CanGiveInfluence(); end);
	if not okC or canGive ~= true then return false end
	local okT, tokens = pcall(function() return inf:GetTokensToGive(); end);
	if not okT or tokens == nil or tokens <= 0 then return false end

	-- Re-entry with the SAME count we just volleyed = the getter is stale (our
	-- async gives have not landed) or the engine is silently refusing -- either
	-- way, NOT new tokens (audit #29). Bail withOUT setting g_envoyDone so a
	-- later pass acts once the count actually moves.
	if tokens == g_envoyLastTokens then return false end
	local tokensAtStart = tokens;

	-- Everything below is ASYNC: GetTokensReceived will NOT reflect a token we
	-- sent a moment ago, so the loop tracks its own sends in `pending`. Without
	-- it, every iteration re-reads the same stale counts and the scoring cannot
	-- see what it just did.
	local pending, sent = {}, 0;

	while tokens > 0 do
		local best, bestScore, bestName = nil, nil, nil;

		for _, pMinor in ipairs(PlayerManager.GetAliveMinors()) do
			local mid   = pMinor:GetID();
			local csInf = pMinor:GetInfluence();
			local okR, canRecv   = pcall(function() return csInf ~= nil and csInf:CanReceiveInfluence(); end);
			local okG, canGiveTo = pcall(function() return inf:CanGiveTokensToPlayer(mid); end);

			if okR and canRecv == true and okG and canGiveTo == true then
				local mine = (csInf:GetTokensReceived(eLocal) or 0) + (pending[mid] or 0);
				local most = csInf:GetMostTokensReceived() or 0;
				local suz  = csInf:GetSuzerain();

				-- Already ours -> defend the lead. Otherwise prefer the one we are
				-- closest to leading: a 1-envoy gap is worth closing, a 5-envoy gap
				-- is throwing envoys into someone else's suzerainty.
				local score;
				if suz == eLocal then
					score = 100 + mine;
				else
					score = 50 - math.max(0, most - mine);
				end

				if bestScore == nil or score > bestScore then
					-- Player objects have NO GetName() (grep-verified: zero hits in
					-- the UI tree). Names live on PlayerConfigurations
					-- (CityStates.lua:213).
					local cfg = PlayerConfigurations[mid];
					bestScore, best = score, mid;
					bestName = (cfg ~= nil) and cfg:GetCivilizationShortDescription() or tostring(mid);
				end
			end
		end

		if best == nil then break end

		local parameters = {};
		parameters[PlayerOperations.PARAM_PLAYER_ONE] = best;
		UI.RequestPlayerOperation(eLocal, PlayerOperations.GIVE_INFLUENCE_TOKEN, parameters);

		pending[best] = (pending[best] or 0) + 1;
		tokens = tokens - 1;
		sent   = sent + 1;
		Log("envoy -> [%s] (%d token(s) left)", tostring(bestName), tokens);
	end

	if sent > 0 then
		g_envoyDone = true;
		g_envoyLastTokens = tokensAtStart;
	end
	return sent > 0;
end

-- ---------------------------------------------------------------- pantheon ---
--
-- The pantheon choice blocks the turn exactly once per game, which makes it the
-- most annoying blocker of all: rare enough to forget, absolute when it lands.
--
-- Verified API:
--   LaunchBar.lua:138        pReligion:GetPantheon() < 0 and pReligion:CanCreatePantheon()
--   PantheonChooser.lua:69-77  selectable = BELIEF_CLASS_PANTHEON and not
--                              IsInSomePantheon(index) and not IsInSomeReligion(index)
--   PantheonChooser.lua:129-132  PARAM_BELIEF_TYPE = GameInfo.Beliefs[i].Hash,
--                              PARAM_INSERT_MODE = VALUE_EXCLUSIVE,
--                              UI.RequestPlayerOperation(local, PlayerOperations.FOUND_PANTHEON, t)
local function AutomatePantheon(pPlayer)
	if g_pantheonDone then return false end

	local okR, rel = pcall(function() return pPlayer:GetReligion(); end);
	if not okR or rel == nil then return false end
	local okP, pantheon = pcall(function() return rel:GetPantheon(); end);
	local okC, canMake  = pcall(function() return rel:CanCreatePantheon(); end);
	if not okP or not okC or pantheon == nil or pantheon >= 0 or canMake ~= true then return false end

	local gameRel = Game.GetReligion();
	if gameRel == nil then return false end

	-- Generically strong pantheons first (production, growth, great people --
	-- good in any game). Unlisted beliefs rank 99 and still get taken when the
	-- list is exhausted: ANY pantheon beats a blocked turn.
	local PREF = {
		BELIEF_GOD_OF_THE_FORGE       = 1,
		BELIEF_FERTILITY_RITES        = 2,
		BELIEF_DIVINE_SPARK           = 3,
		BELIEF_RELIGIOUS_SETTLEMENTS  = 4,
		BELIEF_GOD_OF_CRAFTSMEN       = 5,
		BELIEF_MONUMENT_TO_THE_GODS   = 6,
	};

	local best, bestRank = nil, nil;
	for kBelief in GameInfo.Beliefs() do
		if kBelief.BeliefClassType == "BELIEF_CLASS_PANTHEON" then
			local okT, taken = pcall(function()
				return gameRel:IsInSomePantheon(kBelief.Index) or gameRel:IsInSomeReligion(kBelief.Index);
			end);
			if okT and taken ~= true then
				local rank = PREF[kBelief.BeliefType] or 99;
				if bestRank == nil or rank < bestRank then bestRank, best = rank, kBelief end
			end
		end
	end
	if best == nil then return false end

	local tParameters = {};
	tParameters[PlayerOperations.PARAM_BELIEF_TYPE] = best.Hash;
	tParameters[PlayerOperations.PARAM_INSERT_MODE] = PlayerOperations.VALUE_EXCLUSIVE;
	UI.RequestPlayerOperation(Game.GetLocalPlayer(), PlayerOperations.FOUND_PANTHEON, tParameters);
	g_pantheonDone = true;
	Log("pantheon -> %s (rank %d)", tostring(best.BeliefType), bestRank);
	return true;
end

-- ---------------------------------------------------------------- religion ---
--
-- Phase 2 of great-prophet automation (issue #7): after the prophet activates,
-- the player is in "choose religion" state and END TURN blocks on it. The
-- exact state gate is the game's own (ReligionScreen.lua:311-329):
--   pantheon exists AND GetNumBeliefsEarned() > 0 AND GetReligionTypeCreated() < 0
-- Available religions: GameInfo.Religions() where Pantheon == false and not
-- Game.GetReligion():HasBeenFounded(index) (ReligionScreen.lua:643-644).
-- Ops verified at ReligionScreen.lua:903-919 (FOUND_RELIGION + ADD_BELIEF).
local function AutomateReligion(pPlayer)
	if g_religionDone then return false end

	local okR, rel = pcall(function() return pPlayer:GetReligion(); end);
	if not okR or rel == nil then return false end
	local okP, pantheon = pcall(function() return rel:GetPantheon(); end);
	local okT, created  = pcall(function() return rel:GetReligionTypeCreated(); end);
	local okE, earned   = pcall(function() return rel:GetNumBeliefsEarned(); end);
	if not (okP and okT and okE) then return false end
	if pantheon == nil or pantheon < 0 then return false end
	if earned == nil or earned <= 0 then return false end

	local gameRel = Game.GetReligion();
	if gameRel == nil then return false end

	-- BELIEF-FILL (audit #2): beliefs earned AFTER the religion exists
	-- (temples, wonders) used to hit a hard `created >= 0 -> return` bail --
	-- the BELIEF end-turn blocker then deadlocked the game forever. Mirror of
	-- ReligionScreen.lua:321-327's add-belief path.
	if created ~= nil and created >= 0 then
		local sent = 0;
		for kBelief in GameInfo.Beliefs() do
			if sent < earned and kBelief.BeliefClassType ~= "BELIEF_CLASS_PANTHEON" then
				local okU, used = pcall(function()
					return gameRel:IsInSomeReligion(kBelief.Index) or gameRel:IsInSomePantheon(kBelief.Index);
				end);
				local okM, tooMany = pcall(function()
					return gameRel:IsTooManyForReligion(kBelief.Index, created);
				end);
				if okU and used ~= true and (not okM or tooMany ~= true) then
					local tB = {};
					tB[PlayerOperations.PARAM_BELIEF_TYPE] = kBelief.Hash;
					tB[PlayerOperations.PARAM_INSERT_MODE] = PlayerOperations.VALUE_EXCLUSIVE;
					UI.RequestPlayerOperation(Game.GetLocalPlayer(), PlayerOperations.ADD_BELIEF, tB);
					Log("religion belief-fill -> %s (%s)", tostring(kBelief.BeliefType), tostring(kBelief.BeliefClassType));
					sent = sent + 1;
				end
			end
		end
		if sent > 0 then g_religionDone = true; return true end
		return false;
	end

	-- Any unfounded standard religion; skip custom-name ones (they need a text
	-- param a rules engine has no business inventing).
	local pick = nil;
	for row in GameInfo.Religions() do
		local okF, founded = pcall(function() return gameRel:HasBeenFounded(row.Index); end);
		if row.Pantheon == false and okF and founded ~= true
		   and not (row.RequiresCustomName == true or row.RequiresCustomName == 1) then
			pick = row;
			break;
		end
	end
	if pick == nil then return false end

	local tParameters = {};
	tParameters[PlayerOperations.PARAM_INSERT_MODE]  = PlayerOperations.VALUE_EXCLUSIVE;
	tParameters[PlayerOperations.PARAM_RELIGION_TYPE] = pick.Hash;
	UI.RequestPlayerOperation(Game.GetLocalPlayer(), PlayerOperations.FOUND_RELIGION, tParameters);
	Log("FOUNDING RELIGION -> %s", tostring(pick.ReligionType));

	-- Beliefs: one per earned slot. Follower first, then founder, then anything
	-- non-pantheon still free -- same order the chooser walks. A wrong-class
	-- request is dropped by the engine; the next turn's pass retries with the
	-- flag reset, so a partial fill self-completes.
	local CLASS_ORDER = { BELIEF_CLASS_FOLLOWER = 1, BELIEF_CLASS_FOUNDER = 2 };
	local sent, sentClass = 0, {};
	for pass = 1, 3 do
		for kBelief in GameInfo.Beliefs() do
			if sent >= earned then break end
			local rank = CLASS_ORDER[kBelief.BeliefClassType] or 3;
			if rank == pass and kBelief.BeliefClassType ~= "BELIEF_CLASS_PANTHEON"
			   and not sentClass[kBelief.BeliefClassType] then
				local okU, used = pcall(function()
					return gameRel:IsInSomeReligion(kBelief.Index) or gameRel:IsInSomePantheon(kBelief.Index);
				end);
				if okU and used ~= true then
					local tB = {};
					tB[PlayerOperations.PARAM_BELIEF_TYPE]  = kBelief.Hash;
					tB[PlayerOperations.PARAM_INSERT_MODE]  = PlayerOperations.VALUE_EXCLUSIVE;
					UI.RequestPlayerOperation(Game.GetLocalPlayer(), PlayerOperations.ADD_BELIEF, tB);
					Log("religion belief -> %s (%s)", tostring(kBelief.BeliefType), tostring(kBelief.BeliefClassType));
					sent = sent + 1;
					sentClass[kBelief.BeliefClassType] = true;
				end
			end
		end
	end

	g_religionDone = true;
	return true;
end

-- --------------------------------------------------------- great people -----
--
-- Claims earned great people (ENDTURN_BLOCKING_CLAIM_GREAT_PERSON). Verified
-- GreatPeoplePopup.lua: timeline :694-708 (Game.GetGreatPeople():GetTimeline(),
-- entry.Individual/.Claimant), recruit gate :728 CanRecruitPerson, op :886-891.
-- Keep enough faith/gold banked that patronage never starves the levers that
-- need them (faith: religion units later; gold: the emergency defense buy).
local FAITH_PATRON_RESERVE = 300;
local GOLD_PATRON_RESERVE  = 500;

local function AutomateGreatPeopleClaim(pPlayer)
	if g_gpDone then return false end
	local e = pPlayer:GetID();
	local okP, pGP = pcall(function() return Game.GetGreatPeople(); end);
	if not okP or pGP == nil then return false end
	local okT, timeline = pcall(function() return pGP:GetTimeline(); end);
	if not okT or timeline == nil then return false end

	-- Diagnostics first (#27): this ran a whole live session as a silent no-op
	-- (0 CLAIMING lines while the CLAIM_GREAT_PERSON blocker fired and Anthony
	-- claimed 3 by hand). Whatever fails next time, the log now says which rung.
	local nEntries, nUnclaimed, nRecruit = 0, 0, 0;

	local pick = nil;   -- {ind, how, cost} -- prefer free recruit, then faith, then gold
	local okTr, pTreasury = pcall(function() return pPlayer:GetTreasury(); end);
	local okRl, pRel      = pcall(function() return pPlayer:GetReligion(); end);
	local gold  = (okTr and pTreasury ~= nil) and (pcall(function() return pTreasury:GetGoldBalance() end)
	              and select(2, pcall(function() return pTreasury:GetGoldBalance() end)) or 0) or 0;
	local faith = (okRl and pRel ~= nil) and (pcall(function() return pRel:GetFaithBalance() end)
	              and select(2, pcall(function() return pRel:GetFaithBalance() end)) or 0) or 0;

	for _, entry in ipairs(timeline) do
		nEntries = nEntries + 1;
		if entry.Claimant == nil and entry.Individual ~= nil then
			nUnclaimed = nUnclaimed + 1;
			-- Truthiness, not == true (the CanStart lesson: never bet the branch
			-- on a strict boolean return).
			local okC, can = pcall(function() return pGP:CanRecruitPerson(e, entry.Individual); end);
			if okC and can then
				nRecruit = nRecruit + 1;
				if pick == nil then pick = { ind = entry.Individual, how = "recruit" } end
			elseif pick == nil then
				-- PATRONAGE (#32, Anthony live: 2,184 faith banked doing nothing).
				-- Faith first (gold is the scarcer resource right now), and only
				-- above a reserve. API: GreatPeoplePopup.lua:735-738 (gates+cost),
				-- :908-931 (PATRONIZE_GREAT_PERSON + PARAM_YIELD_TYPE).
				local okF, canF = pcall(function() return pGP:CanPatronizePerson(e, entry.Individual, YieldTypes.FAITH); end);
				local okFC, cF  = pcall(function() return pGP:GetPatronizeCost(e, entry.Individual, YieldTypes.FAITH); end);
				if okF and canF and okFC and cF ~= nil and cF < 1000000
				   and faith - cF >= FAITH_PATRON_RESERVE then
					pick = { ind = entry.Individual, how = "patronize-faith", cost = cF };
				else
					local okG, canG = pcall(function() return pGP:CanPatronizePerson(e, entry.Individual, YieldTypes.GOLD); end);
					local okGC, cG  = pcall(function() return pGP:GetPatronizeCost(e, entry.Individual, YieldTypes.GOLD); end);
					if okG and canG and okGC and cG ~= nil and cG < 1000000
					   and gold - cG >= GOLD_PATRON_RESERVE then
						pick = { ind = entry.Individual, how = "patronize-gold", cost = cG };
					end
				end
			end
		end
	end

	if pick == nil then
		if nUnclaimed > 0 then
			LogOnce("gpclaim", "gp-claim: %d timeline entries, %d unclaimed, %d recruitable, none affordable (faith=%d gold=%d)",
				nEntries, nUnclaimed, nRecruit, faith, gold);
		end
		return false;
	end

	local kParameters = {};
	kParameters[PlayerOperations.PARAM_GREAT_PERSON_INDIVIDUAL_TYPE] = pick.ind;
	if pick.how == "recruit" then
		UI.RequestPlayerOperation(e, PlayerOperations.RECRUIT_GREAT_PERSON, kParameters);
	else
		kParameters[PlayerOperations.PARAM_YIELD_TYPE] =
			(pick.how == "patronize-faith") and YieldTypes.FAITH or YieldTypes.GOLD;
		UI.RequestPlayerOperation(e, PlayerOperations.PATRONIZE_GREAT_PERSON, kParameters);
	end
	g_gpDone = true;
	local info = GameInfo.GreatPersonIndividuals[pick.ind];
	Log("CLAIMING great person %s via %s%s",
		tostring(info ~= nil and info.Name or pick.ind), pick.how,
		pick.cost ~= nil and (" (cost " .. tostring(pick.cost) .. ")") or "");
	return true;
end

-- ------------------------------------------------- city production ----------
--
-- Same philosophy as research: the city's own AI already knows what it wants
-- (GetBuildRecommendations is what draws the recommendation stars in the
-- production panel). We only step in when a city is IDLE, so a build you chose
-- yourself is never overridden.
--
-- Districts are deliberately skipped: a district BUILD needs a target plot, and
-- picking that badly permanently wastes a tile. Units/buildings/projects only.

-- Hash 0 = "producing nothing" -- that is exactly how the game's own helper
-- detects an empty queue (ProductionHelper.lua:31 checks == 0).
local function CurrentProductionHash(pCity)
	local ok, pQueue = pcall(function() return pCity:GetBuildQueue(); end);
	if not ok or pQueue == nil then return nil, false end
	local okH, h = pcall(function() return pQueue:GetCurrentProductionTypeHash(); end);
	if not okH then return nil, false end
	return h, true;
end

-- --------------------------------------------- empire composition -----------
--
-- The city advisor is good at "what is efficient in this city right now" and
-- blind to "what does this empire actually LACK". Left to itself it produced
-- settlers and warriors and never once a builder (observed live, 40+ turns) --
-- because a builder's payoff is a tile improvement the advisor does not score.
-- The result is an empire of unimproved tiles: no growth, no production, a hard
-- ceiling you cannot see until it is too late.
--
-- So a few guardrails get a vote BEFORE the advisor. These are deliberately
-- RATIOS, not a build order: the advisor still decides everything the ratios do
-- not care about, and the ratios only fire when something is genuinely missing.
local WANT_BUILDERS_TOTAL    = 2   -- Anthony (2026-07-18): "builders are needed
                                   -- when less than 2 builders exist and there
                                   -- are things to do" -- TOTAL, not per city
                                   -- (1/city hired a 3rd at 3 cities, live t88)
local WANT_MILITARY_PER_CITY = 2   -- garrison + a responder
local MAX_SETTLERS_IN_FLIGHT = 1   -- Anthony's standard (#21): found the current
                                   -- city before training the next settler
local SETTLER_CITY_CAP       = 6   -- stop expanding around here; deepen instead

-- Counts LIVE units AND what is already in the build queues. Counting the queues
-- is not optional: production is async and every city evaluates in the same
-- pass, so without it all four cities see the same "0 builders" deficit in the
-- same turn and all four queue a builder. (Same failure mode as the
-- g_cityOrdered debounce, one level up.)
local function CountEmpire(pPlayer)
	local c = { cities = 0, builders = 0, settlers = 0, military = 0, militaryAlive = 0, recon = 0,
	            gold = 0, gpt = 0 };

	-- Economy snapshot (#32, live: gold=21 gpt=-14.9 at t223 -- next stop is the
	-- engine auto-disbanding the army). gpt<0 flips the composition into
	-- austerity: no new maintenance-bearing units outside the defense override.
	local okT, pT = pcall(function() return pPlayer:GetTreasury(); end);
	if okT and pT ~= nil then
		local okG, bal = pcall(function() return math.floor(pT:GetGoldBalance()); end);
		if okG and bal ~= nil then c.gold = bal end
		local okY, y = pcall(function() return pT:GetGoldYield() - pT:GetTotalMaintenance(); end);
		if okY and y ~= nil then c.gpt = y end
	end

	local okC, cities = pcall(function() return pPlayer:GetCities(); end);
	if okC and cities ~= nil then
		for _, pCity in cities:Members() do
			c.cities = c.cities + 1;
			local h = CurrentProductionHash(pCity);
			local kType = (h ~= nil and h ~= 0 and h ~= -1) and GameInfo.Types[h] or nil;
			if kType ~= nil and kType.Kind == "KIND_UNIT" then
				local row = GameInfo.Units[kType.Type];
				if row ~= nil then
					if (row.BuildCharges or 0) > 0 then
						c.builders = c.builders + 1;
					elseif row.FoundCity == true or row.FoundCity == 1 then
						c.settlers = c.settlers + 1;
					elseif (row.Combat or 0) > 0 and row.PromotionClass ~= "PROMOTION_CLASS_RECON" then
						c.military = c.military + 1;
					end
				end
			end
		end
	end

	local okU, units = pcall(function() return pPlayer:GetUnits(); end);
	if okU and units ~= nil then
		for _, u in units:Members() do
			if not u:IsDead() then
				if IsBuilder(u) then c.builders = c.builders + 1;
				elseif IsSettler(u) then c.settlers = c.settlers + 1;
				elseif IsRecon(u) then c.recon = c.recon + 1;
				elseif IsCombatUnit(u) then
					c.military = c.military + 1;
					c.militaryAlive = c.militaryAlive + 1;
				end
			end
		end
	end
	return c;
end

-- What is this empire missing, in priority order? Returns a UnitType string to
-- force, or nil to let the advisor decide as usual.
local function CompositionWant(emp)
	if emp.cities < 1 then return nil end
	-- Do not hire while someone already on payroll has nothing to do (issue #5):
	-- an unemployed builder means the bottleneck is WORK, not headcount. And
	-- require the shortage to PERSIST two consecutive turns -- captured
	-- builders were triggering same-turn re-hires straight back into the same
	-- death trap (5 builder IDs in one Norway session).
	if emp.builders < WANT_BUILDERS_TOTAL
	   and not g_builderIdleLastTurn and not g_builderIdleThisTurn then
		-- Count the shortage once per TURN, not once per call: this runs per
		-- city per pass, so the old counter hit "2 consecutive turns" within a
		-- single pass and re-hired into the same death trap it was built to
		-- avoid (#28).
		local t = Game.GetCurrentGameTurn();
		if g_builderShortStampTurn ~= t then
			g_builderShortStampTurn = t;
			g_builderShortTurns = g_builderShortTurns + 1;
		end
		if g_builderShortTurns >= 2 then
			return "UNIT_BUILDER";
		end
	else
		g_builderShortTurns = 0;
		g_builderShortStampTurn = -1;
	end
	-- Military shortage (audit #28: both branches of the old code returned nil,
	-- making this guardrail a no-op since birth). Sentinel: the caller picks
	-- WHICH soldier (strongest producible). Austerity-gated -- this path skips
	-- CompositionVetoes, so the gpt guard must live here.
	if emp.military < emp.cities * WANT_MILITARY_PER_CITY and (emp.gpt or 0) >= 0 then
		return "ANY_MILITARY";
	end
	return nil;
end

-- Would this pick violate a guardrail? Used to veto the advisor rather than to
-- replace it -- vetoing is cheap and keeps the advisor's judgement everywhere
-- the guardrails are silent.
local function CompositionVetoes(h, emp)
	local kType = (h ~= nil) and GameInfo.Types[h] or nil;
	if kType == nil or kType.Kind ~= "KIND_UNIT" then return false end
	local row = GameInfo.Units[kType.Type];
	if row == nil then return false end
	-- AUSTERITY (#32): while gpt is negative every new soldier digs the hole
	-- deeper, and at 0 gold the ENGINE disbands units -- an army-losing spiral
	-- the advisor cannot see. No new maintenance-bearing units until the bleed
	-- stops. The defense override does not consult vetoes, so a city under
	-- direct attack still gets its emergency defender.
	if (emp.gpt or 0) < 0 and (row.Maintenance or 0) > 0 then
		return true, string.format("austerity: gpt=%d", emp.gpt);
	end
	-- Scouts are a luxury, not a priority (Anthony, 2026-07-17): one is plenty
	-- for goody huts; every further recon pick is production the army needed.
	if row.PromotionClass == "PROMOTION_CLASS_RECON" and emp.recon >= 1 then
		return true, "recon cap";
	end
	if row.FoundCity == true or row.FoundCity == 1 then
		-- Settler spam is the advisor's favourite failure. Two in flight is
		-- plenty, and past the city cap we should be deepening, not sprawling.
		if emp.settlers >= MAX_SETTLERS_IN_FLIGHT then return true, "settler cap" end
		if emp.cities   >= SETTLER_CITY_CAP       then return true, "city cap" end
		-- Anthony's doctrine (#25): "a settler is pointless without enough to
		-- defend current cities + enough to escort. Cities first and foremost."
		-- ALIVE soldiers only -- one queued warrior is not a garrison.
		if g_defcity ~= nil then return true, "city under threat -- defense first" end
		if (emp.militaryAlive or 0) < emp.cities + 1 then return true, "defend cities first" end
	end
	return false;
end

-- ------------------------------------------------- district placement -------
--
-- Districts are the single biggest empire-strength lever, and until now the mod
-- never built one -- a hard economic cap. What made them scary is the plot
-- choice: a badly placed district wastes that tile for the whole game. So the
-- placement is exactly the game's own: GetOperationTargets returns the plots
-- the placement UI would light up (AdjacencyBonusSupport.lua:290), and each is
-- scored with plot:GetAdjacencyYield -- the same call that draws the "+2" icons
-- during manual placement (DistrictPlotIconManager.lua:142, which also proves
-- the district arg is the INDEX, not the hash).
--
-- Returns the best plot for this district in this city, or nil if none is legal.
local function BestDistrictPlot(pCity, districtHash)
	local kType = GameInfo.Types[districtHash];
	local dRow  = (kType ~= nil) and GameInfo.Districts[kType.Type] or nil;
	if dRow == nil then return nil end

	local tParameters = { [CityOperationTypes.PARAM_DISTRICT_TYPE] = districtHash };
	local ok, tResults = pcall(function()
		return CityManager.GetOperationTargets(pCity, CityOperationTypes.BUILD, tParameters);
	end);
	if not ok or tResults == nil then return nil end
	local kPlots = tResults[CityOperationResults.PLOTS];
	if kPlots == nil or table.count(kPlots) == 0 then return nil end

	local eLocal, cityID = pCity:GetOwner(), pCity:GetID();
	local best, bestScore = nil, -1;
	for _, plotId in ipairs(kPlots) do
		local plot = Map.GetPlotByIndex(plotId);
		if plot ~= nil then
			local score = 0;
			for yRow in GameInfo.Yields() do
				local okY, y = pcall(function()
					return plot:GetAdjacencyYield(eLocal, cityID, dRow.Index, yRow.Index);
				end);
				if okY and y ~= nil then score = score + y end
			end
			if score > bestScore then bestScore, best = score, plot end
		end
	end
	if best ~= nil then
		Log("district plot for %s: %d,%d (adjacency %d, %d candidates)",
			tostring(kType.Type), best:GetX(), best:GetY(), bestScore, table.count(kPlots));
	end
	return best;
end

local function AutomateProduction(pPlayer, threats)
	local okC, pCities = pcall(function() return pPlayer:GetCities(); end);
	if not okC or pCities == nil then return end

	local emp = CountEmpire(pPlayer);

	for _, pCity in pCities:Members() do
		local cityID = pCity:GetID();
		local hCur, okRead = CurrentProductionHash(pCity);
		local isIdle = okRead and (hCur == nil or hCur == -1 or hCur == 0);
		if isIdle and not g_cityOrdered[cityID] then
			-- Every pick -- advisor OR fallback -- must pass the same legality
			-- test the production panel runs per row. Learned live: the advisor
			-- recommended GRANARY before Pottery was researched; the engine
			-- silently rejected the order and the debounce then blocked a retry,
			-- leaving the city stuck on "Nothing" for the rest of the turn.
			local function CanCityProduce(h)
				local okQ, pQueue = pcall(function() return pCity:GetBuildQueue(); end);
				if not okQ or pQueue == nil then return false end
				-- STRICT test -- can the city start this RIGHT NOW. The old
				-- CanProduce(h, true) is the panel's VISIBILITY check: it
				-- passed units whose strategic resources we lack, the engine
				-- silently dropped the order, and the defense override re-issued
				-- UNIT_MAN_AT_ARMS forever while Tlacopan's chooser sat open
				-- (live t177). The panel's own disable test is
				-- CanProduce(h, false, true) -- ProductionPanel.lua:1912/2038.
				local okCan, can = pcall(function() return pQueue:CanProduce(h, false, true); end);
				return okCan and can == true;
			end

			-- Defense first: with a visible enemy near the city, the advisor's
			-- settler/builder preferences are suicide (observed: Xi'an kept
			-- pumping settlers straight into barbarian hands). Build the
			-- strongest trainable land unit until the area is clear.
			local dCity = NearestThreatDist(threats, pCity:GetX(), pCity:GetY());
			-- CAP (live: 10 warriors ringing St. Petersburg, 1 building, still
			-- training warriors): a permanent barb camp keeps the threat visible
			-- forever, so the override must stop once the city HAS defenders --
			-- 2 nearby is a garrison, not a shortage.
			local nDefenders = 0;
			if dCity ~= nil and dCity <= 4 then
				local okDU, dUnits = pcall(function() return pPlayer:GetUnits(); end);
				if okDU and dUnits ~= nil then
					for _, du in dUnits:Members() do
						if not du:IsDead() and IsCombatUnit(du) and not IsRecon(du)
						   and Map.GetPlotDistance(du:GetX(), du:GetY(), pCity:GetX(), pCity:GetY()) <= 4 then
							nDefenders = nDefenders + 1;
						end
					end
				end
			end
			if dCity ~= nil and dCity <= 4 and nDefenders < 2 then
				-- Sea threat -> build RANGED (only thing that can shoot boats
				-- from land); land threat -> strongest as before. Scoped to
				-- THIS city's trigger radius (audit #27): the old global scan
				-- read "sea" as false whenever any land barb existed anywhere,
				-- so besieged-by-galleys cities built melee.
				local dLandHere = NearestThreatDist(threats, pCity:GetX(), pCity:GetY(), true);
				local seaThreat = (dLandHere == nil or dLandHere > 4);
				local best = nil;
				for row in GameInfo.Units() do
					if (row.Combat or 0) > 0 and row.Domain == "DOMAIN_LAND"
					   and (not seaThreat or (row.RangedCombat or 0) > 0)
					   and row.PromotionClass ~= "PROMOTION_CLASS_RECON"
					   and CanCityProduce(row.Hash) then
						if best == nil or (row.Combat or 0) > best.combat then
							best = { hash = row.Hash, combat = row.Combat };
						end
					end
				end
				if best ~= nil then
					local tParameters = {};
					tParameters[CityOperationTypes.PARAM_UNIT_TYPE]   = best.hash;
					tParameters[CityOperationTypes.PARAM_INSERT_MODE] = CityOperationTypes.VALUE_EXCLUSIVE;
					CityManager.RequestOperation(pCity, CityOperationTypes.BUILD, tParameters);
					g_cityOrdered[cityID] = true;
					local kType = GameInfo.Types[best.hash];
					Log("defense [%s]: enemy %d tiles out -> %s",
						tostring(pCity:GetName()), dCity,
						(kType ~= nil and kType.Type) or tostring(best.hash));

					-- GOLD IS A TOOL (Anthony, 2026-07-17): production takes turns
					-- a threatened city may not have. If the treasury covers the
					-- same defender, BUY it outright -- it spawns this turn.
					-- API verified in the install: ProductionPanel.lua:423-435
					-- (PARAM_UNIT_TYPE + PARAM_MILITARY_FORMATION_TYPE +
					-- PARAM_YIELD_TYPE=YIELD_GOLD index -> RequestCommand PURCHASE),
					-- gate form :1639-1640 (CanStartCommand 5-arg).
					local tBuy = {};
					tBuy[CityCommandTypes.PARAM_UNIT_TYPE] = best.hash;
					tBuy[CityCommandTypes.PARAM_MILITARY_FORMATION_TYPE] = MilitaryFormationTypes.STANDARD_MILITARY_FORMATION;
					tBuy[CityCommandTypes.PARAM_YIELD_TYPE] = GameInfo.Yields["YIELD_GOLD"].Index;
					local okB, canBuy = pcall(function()
						return CityManager.CanStartCommand(pCity, CityCommandTypes.PURCHASE, false, tBuy, false);
					end);
					if okB and canBuy == true and not g_cityBought[cityID] then
						-- Once per city per turn (audit #12): PURCHASE is async
						-- and CanStartCommand stays true until it lands, so a
						-- re-pass double-fired = double gold spent.
						g_cityBought[cityID] = true;
						CityManager.RequestCommand(pCity, CityCommandTypes.PURCHASE, tBuy);
						Log("defense [%s]: GOLD-BOUGHT %s (enemy %d out, %d defenders)",
							tostring(pCity:GetName()),
							(kType ~= nil and kType.Type) or tostring(best.hash),
							dCity, nDefenders);
					end
				end
			end

			-- WALLS while threatened (live t177: Ancient Walls 7t sat unpicked
			-- while Tlacopan was besieged -- the override only knew units).
			-- Walls = the free city ranged strike every turn (#29), the best
			-- defensive build there is. Implicit test: any building with outer
			-- defense HP, cheapest first, strict-producible -- no name list.
			if not g_cityOrdered[cityID] and dCity ~= nil and dCity <= 4 and nDefenders >= 2 then
				local wall = nil;
				for wRow in GameInfo.Buildings() do
					if (wRow.OuterDefenseHitPoints or 0) > 0 and CanCityProduce(wRow.Hash) then
						if wall == nil or (wRow.Cost or 9999) < (wall.Cost or 9999) then wall = wRow end
					end
				end
				if wall ~= nil then
					local tW = {};
					tW[CityOperationTypes.PARAM_BUILDING_TYPE] = wall.Hash;
					tW[CityOperationTypes.PARAM_INSERT_MODE]   = CityOperationTypes.VALUE_EXCLUSIVE;
					CityManager.RequestOperation(pCity, CityOperationTypes.BUILD, tW);
					g_cityOrdered[cityID] = true;
					Log("defense [%s]: WALLS -> %s (enemy %d out)",
						tostring(pCity:GetName()), tostring(wall.BuildingType), dCity);
				end
			end

			-- REPAIR pillaged districts/buildings before anything non-defensive
			-- (Anthony live t88: "Holy Site (Repair)" is a CITY-PRODUCTION item,
			-- builders cannot touch districts). A pillaged district also makes
			-- the engine silently DROP orders for its buildings -- we queued
			-- Shrine/Temple into a pillaged Holy Site and the city stuck on
			-- "Nothing" with the chooser popup up. Repair = plain BUILD with the
			-- hash, no plot (ProductionPanel.lua:400-403; pillage flags :1996
			-- districts-by-Index, :2075 buildings-by-Hash).
			if not g_cityOrdered[cityID] then
				local okD, cityDistricts = pcall(function() return pCity:GetDistricts(); end);
				if okD and cityDistricts ~= nil then
					for dRow in GameInfo.Districts() do
						local okP, pill = pcall(function() return cityDistricts:IsPillaged(dRow.Index); end);
						if okP and pill == true and CanCityProduce(dRow.Hash) then
							local tP = {};
							tP[CityOperationTypes.PARAM_DISTRICT_TYPE] = dRow.Hash;
							tP[CityOperationTypes.PARAM_INSERT_MODE]   = CityOperationTypes.VALUE_EXCLUSIVE;
							CityManager.RequestOperation(pCity, CityOperationTypes.BUILD, tP);
							g_cityOrdered[cityID] = true;
							Log("produce [%s]: REPAIRING pillaged %s", tostring(pCity:GetName()), tostring(dRow.DistrictType));
							break;
						end
					end
				end
				if not g_cityOrdered[cityID] then
					local okB, cityBuildings = pcall(function() return pCity:GetBuildings(); end);
					if okB and cityBuildings ~= nil then
						for bRow in GameInfo.Buildings() do
							local okP, pill = pcall(function() return cityBuildings:IsPillaged(bRow.Hash); end);
							if okP and pill == true and CanCityProduce(bRow.Hash) then
								local tP = {};
								tP[CityOperationTypes.PARAM_BUILDING_TYPE] = bRow.Hash;
								tP[CityOperationTypes.PARAM_INSERT_MODE]   = CityOperationTypes.VALUE_EXCLUSIVE;
								CityManager.RequestOperation(pCity, CityOperationTypes.BUILD, tP);
								g_cityOrdered[cityID] = true;
								Log("produce [%s]: REPAIRING pillaged %s", tostring(pCity:GetName()), tostring(bRow.BuildingType));
								break;
							end
						end
					end
				end
			end

			-- GREAT-WORK SLOT NUDGE (#27, live: Machiavelli claimed with nowhere
			-- to put his writing): a GP flagged as slot-starved queues the
			-- cheapest slot building here (Amphitheater for writers). The
			-- build's completion wakes the sleeping GP automatically.
			if not g_cityOrdered[cityID] and g_gpNeedSlot ~= nil then
				local wish = FindSlotBuildingWish(g_gpNeedSlot);
				if wish ~= nil and CanCityProduce(wish.Hash) then
					local tW = {};
					tW[CityOperationTypes.PARAM_BUILDING_TYPE] = wish.Hash;
					tW[CityOperationTypes.PARAM_INSERT_MODE]   = CityOperationTypes.VALUE_EXCLUSIVE;
					CityManager.RequestOperation(pCity, CityOperationTypes.BUILD, tW);
					g_cityOrdered[cityID] = true;
					Log("produce [%s]: great person waiting for a %s slot -> %s",
						tostring(pCity:GetName()), tostring(g_gpNeedSlot), tostring(wish.BuildingType));
					g_gpNeedSlot = nil;
				end
			end

			-- Composition guardrail, ahead of the advisor: fill a real empire-wide
			-- gap first. Fires only when something is genuinely missing, so in a
			-- balanced empire this is a no-op and the advisor runs as before.
			if not g_cityOrdered[cityID] then
				local want = CompositionWant(emp);
				if want == "ANY_MILITARY" then
					-- Strongest producible land soldier, same doctrine as the
					-- defense override (Anthony: later military units matter).
					local bestU = nil;
					for rowU in GameInfo.Units() do
						if (rowU.Combat or 0) > 0 and rowU.Domain == "DOMAIN_LAND"
						   and rowU.PromotionClass ~= "PROMOTION_CLASS_RECON"
						   and CanCityProduce(rowU.Hash) then
							if bestU == nil or (rowU.Combat or 0) > bestU.combat then
								bestU = { hash = rowU.Hash, combat = rowU.Combat, utype = rowU.UnitType };
							end
						end
					end
					if bestU ~= nil then
						local tParameters = {};
						tParameters[CityOperationTypes.PARAM_UNIT_TYPE]   = bestU.hash;
						tParameters[CityOperationTypes.PARAM_INSERT_MODE] = CityOperationTypes.VALUE_EXCLUSIVE;
						CityManager.RequestOperation(pCity, CityOperationTypes.BUILD, tParameters);
						g_cityOrdered[cityID] = true;
						Log("composition [%s]: military short (%d < %d) -> %s",
							tostring(pCity:GetName()), emp.military,
							emp.cities * WANT_MILITARY_PER_CITY, tostring(bestU.utype));
						emp.military = emp.military + 1;
					end
				elseif want ~= nil then
					local row = GameInfo.Units[want];
					if row ~= nil and CanCityProduce(row.Hash) then
						local tParameters = {};
						tParameters[CityOperationTypes.PARAM_UNIT_TYPE]   = row.Hash;
						tParameters[CityOperationTypes.PARAM_INSERT_MODE] = CityOperationTypes.VALUE_EXCLUSIVE;
						CityManager.RequestOperation(pCity, CityOperationTypes.BUILD, tParameters);
						g_cityOrdered[cityID] = true;
						Log("composition [%s]: %d builder(s) for %d cities -> %s",
							tostring(pCity:GetName()), emp.builders, emp.cities, want);
						-- Bank it against the snapshot IMMEDIATELY. emp was counted at
						-- the top of this pass, so without this every city in the same
						-- pass sees the same gap and they all fill it at once.
						if (row.BuildCharges or 0) > 0 then emp.builders = emp.builders + 1 end
					end
				end
			end

			local pCityAI = (not g_cityOrdered[cityID]) and pCity:GetCityAI() or nil;
			if pCityAI ~= nil then
				local okR, recs = pcall(function() return pCityAI:GetBuildRecommendations(); end);
				if not okR then
					Log("produce [%s]: GetBuildRecommendations threw", tostring(pCity:GetName()));
				elseif recs == nil then
					Log("produce [%s]: GetBuildRecommendations returned nil", tostring(pCity:GetName()));
				end
				if okR and recs ~= nil then
					local bestHash, bestScore, bestKind = nil, nil, nil;
					local nRecs, nUsable = 0, 0;
					for _, kItem in pairs(recs) do
						nRecs = nRecs + 1;
						local h = kItem.BuildItemHash;
						local kType = (h ~= nil) and GameInfo.Types[h] or nil;
						local kind = (kType ~= nil) and kType.Kind or nil;
						-- KIND_DISTRICT needs a plot; not safe to auto-place blind.
						-- Wonders are excluded on purpose: the advisor scores them
						-- high (observed: Hanging Gardens as a new city's FIRST
						-- build), but a 50-turn wonder locking a young city is a
						-- decision the player should make, and the mod never
						-- overrides a queue you set yourself.
						local isWonder = false;
						if kind == "KIND_BUILDING" and kType ~= nil then
							local b = GameInfo.Buildings[kType.Type];
							isWonder = (b ~= nil) and (b.IsWonder == true or b.IsWonder == 1);
						end
						-- Veto rather than replace: the advisor keeps its judgement
						-- everywhere the guardrails are silent, and only its known
						-- failure mode (endless settlers) gets overruled.
						local vetoed, vetoWhy = CompositionVetoes(h, emp);
						if vetoed then
							Log("produce [%s]: vetoing advisor's %s (%s)",
								tostring(pCity:GetName()),
								(kType ~= nil and kType.Type) or tostring(h), tostring(vetoWhy));
						elseif not isWonder
						   and (kind == "KIND_UNIT" or kind == "KIND_BUILDING" or kind == "KIND_PROJECT"
						        or (kind == "KIND_DISTRICT" and not g_districtNoPlot[cityID .. ":" .. tostring(h)]))
						   and CanCityProduce(h) then
							nUsable = nUsable + 1;
							local s = kItem.BuildItemScore or 0;
							if bestScore == nil or s > bestScore then
								bestScore, bestHash, bestKind = s, h, kind;
							end
						end
					end
					-- Observed live: a just-founded city gets 0 recommendations --
					-- the city AI has not evaluated it yet. The advisor having no
					-- opinion must not leave the city idle, so fall back to the
					-- cheapest legal unit/building (early game that is a scout or
					-- monument -- a sane opener). CanProduce(hash, true) is the
					-- same legality test the production panel runs per row
					-- (ProductionPanel.lua:2026).
					if bestHash == nil then
						local okQ, pQueue = pcall(function() return pCity:GetBuildQueue(); end);
						if okQ and pQueue ~= nil then
							-- Our own mini-advisor. Lower rank = build sooner. The
							-- opener list is deliberate (scout for vision, then early
							-- defence, then monument for culture, then builder);
							-- anything unlisted competes by cost so this keeps
							-- working in later eras without listing every unit.
							local PREF = {
								UNIT_SCOUT        = 1,
								UNIT_SLINGER      = 2,
								UNIT_WARRIOR      = 3,
								BUILDING_MONUMENT = 4,
								UNIT_BUILDER      = 5,
								BUILDING_GRANARY  = 6,
							};
							-- Cap repeats: without this, a stretch of turns where the
							-- game advisor's whole list is ahead of our tech would
							-- build scout after scout (rank 1 wins every time).
							-- Two of any unit type is plenty for an opener.
							local tally = {};
							local okU, pUnits = pcall(function() return pPlayer:GetUnits(); end);
							if okU and pUnits ~= nil then
								for _, u in pUnits:Members() do
									-- Live units only (audit #13): corpses were
									-- consuming the 2-per-type budget.
									local info = (not u:IsDead()) and GameInfo.Units[u:GetUnitType()] or nil;
									if info ~= nil then
										tally[info.UnitType] = (tally[info.UnitType] or 0) + 1;
									end
								end
							end

							-- AUSTERITY (#32, live: gold=21 gpt=-14.9 t223): while
							-- bleeding gold the fallback's one job is fixing the
							-- economy -- gold buildings first, no new upkeep.
							local austerity = (emp.gpt or 0) < 0;
							local GOLD_PREF = {
								BUILDING_MARKET         = 1,
								BUILDING_LIGHTHOUSE     = 2,
								BUILDING_BANK           = 3,
								BUILDING_STOCK_EXCHANGE = 4,
								BUILDING_MONUMENT       = 5,
								BUILDING_GRANARY        = 6,
							};
							-- Trader overbuild gate (#28: NINE traders one session;
							-- traders beyond route capacity earn nothing).
							local routeCap = 1;
							local okRC, pTr = pcall(function() return pPlayer:GetTrade(); end);
							if okRC and pTr ~= nil then
								local okCp, cp = pcall(function() return pTr:GetOutgoingRouteCapacity(); end);
								if okCp and cp ~= nil then routeCap = cp end
							end
							local militaryShort = (emp.military or 0) < (emp.cities or 0) * WANT_MILITARY_PER_CITY;

							local pick = nil;   -- {hash, kind, rank, cost, combat}
							local relax = false; -- pass 2 of the escalation ladder
							local function consider(row, kind)
								-- Same wonder exclusion as the advisor path.
								if row.IsWonder == true or row.IsWonder == 1 then return end
								if kind == "KIND_UNIT" and not relax then
									if (tally[row.UnitType] or 0) >= 2 then return end
									-- Composition vetoes apply HERE too (#28: the 11
									-- scouts and 9 traders were all FALLBACK picks --
									-- only the advisor path was being vetoed).
									if CompositionVetoes(row.Hash, emp) then return end
									if (row.MakeTradeRoute == true or row.MakeTradeRoute == 1)
									   and (tally[row.UnitType] or 0) >= routeCap then return end
								end
								local okCan, can = pcall(function() return pQueue:CanProduce(row.Hash, true); end);
								if not (okCan and can) then return end
								local prefTable = austerity and GOLD_PREF or PREF;
								local rank = prefTable[row.UnitType or row.BuildingType or row.ProjectType] or 99;
								-- A real military gap outranks generic 99s, and among
								-- soldiers the STRONGEST producible wins, not the
								-- cheapest (Anthony live: "doesn't know what to do
								-- with later military units" -- cost-ranking kept
								-- rebuilding ancient chaff).
								local combat = 0;
								if kind == "KIND_UNIT" and (row.Combat or 0) > 0
								   and row.PromotionClass ~= "PROMOTION_CLASS_RECON" then
									combat = row.Combat or 0;
									if militaryShort and not austerity and rank == 99 then rank = 7 end
								end
								-- Projects are the engine's own designed infinite sink;
								-- with buildings exhausted and units capped they are
								-- what keeps a late-game city from idling (#28, live
								-- t206 Aachen stall).
								if kind == "KIND_PROJECT" and rank == 99 then rank = 98 end
								local cost = row.Cost or 9999;
								if pick == nil
								   or rank < pick.rank
								   or (rank == pick.rank and combat > (pick.combat or 0))
								   or (rank == pick.rank and combat == (pick.combat or 0) and cost < pick.cost) then
									pick = { hash = row.Hash, kind = kind, rank = rank, cost = cost, combat = combat };
								end
							end
							for row in GameInfo.Units() do consider(row, "KIND_UNIT") end
							for row in GameInfo.Buildings() do consider(row, "KIND_BUILDING") end
							if CityOperationTypes.PARAM_PROJECT_TYPE ~= nil then
								for row in GameInfo.Projects() do consider(row, "KIND_PROJECT") end
							end
							-- ESCALATION (audit #13): if caps+vetoes filtered
							-- EVERYTHING legal away, an idle city blocks the turn
							-- forever. Anything producible beats that -- rerun
							-- with the guardrails down.
							if pick == nil then
								relax = true;
								for row in GameInfo.Units() do consider(row, "KIND_UNIT") end
								for row in GameInfo.Buildings() do consider(row, "KIND_BUILDING") end
								if CityOperationTypes.PARAM_PROJECT_TYPE ~= nil then
									for row in GameInfo.Projects() do consider(row, "KIND_PROJECT") end
								end
								if pick ~= nil then
									Log("produce [%s]: guardrails filtered everything -- relaxed pick", tostring(pCity:GetName()));
								end
							end
							if pick ~= nil then
								bestHash, bestKind = pick.hash, pick.kind;
								local kPick = GameInfo.Types[pick.hash];
								Log("produce [%s]: advisor empty (%d recs, %d usable), own advisor -> %s (rank %d%s)",
									tostring(pCity:GetName()), nRecs, nUsable,
									(kPick ~= nil and kPick.Type) or tostring(pick.hash), pick.rank,
									austerity and ", AUSTERITY" or "");
							else
								Log("produce [%s]: idle and NOTHING is legal to produce (%d recs)",
									tostring(pCity:GetName()), nRecs);
							end
						end
					end

					if bestHash ~= nil then
						local tParameters = {};
						if bestKind == "KIND_UNIT" then
							tParameters[CityOperationTypes.PARAM_UNIT_TYPE] = bestHash;
						elseif bestKind == "KIND_BUILDING" then
							tParameters[CityOperationTypes.PARAM_BUILDING_TYPE] = bestHash;
						elseif bestKind == "KIND_DISTRICT" then
							-- A district order without a plot is silently dropped by
							-- the engine, so resolve the plot NOW or walk away. The
							-- param shape is the game's own placement confirm:
							-- StrategicView_MapPlacement.lua:204-207.
							local plot = BestDistrictPlot(pCity, bestHash);
							if plot ~= nil then
								tParameters[CityOperationTypes.PARAM_DISTRICT_TYPE] = bestHash;
								tParameters[CityOperationTypes.PARAM_X] = plot:GetX();
								tParameters[CityOperationTypes.PARAM_Y] = plot:GetY();
							else
								-- No legal plot this turn: remember that so the next
								-- pass picks the advisor's next-best item instead of
								-- retrying this district forever.
								g_districtNoPlot[cityID .. ":" .. tostring(bestHash)] = true;
								local kT = GameInfo.Types[bestHash];
								Log("produce [%s]: district %s has NO legal plot -- excluded this turn",
									tostring(pCity:GetName()), (kT ~= nil and kT.Type) or tostring(bestHash));
								bestHash = nil;
							end
						elseif bestKind == "KIND_PROJECT" then
							if CityOperationTypes.PARAM_PROJECT_TYPE == nil then bestHash = nil
							else tParameters[CityOperationTypes.PARAM_PROJECT_TYPE] = bestHash end
						end

						if bestHash ~= nil then
							tParameters[CityOperationTypes.PARAM_INSERT_MODE] = CityOperationTypes.VALUE_EXCLUSIVE;
							CityManager.RequestOperation(pCity, CityOperationTypes.BUILD, tParameters);
							g_cityOrdered[cityID] = true;   -- async: do not re-order this turn
							local kType = GameInfo.Types[bestHash];
							Log("auto-produce [%s] -> %s",
								tostring(pCity:GetName()),
								(kType ~= nil and kType.Type) or tostring(bestHash));

							-- Keep the snapshot honest for the cities later in this
							-- same pass, so the settler cap counts what we just
							-- queued and not only what already existed.
							if kType ~= nil and kType.Kind == "KIND_UNIT" then
								local uRow = GameInfo.Units[kType.Type];
								if uRow ~= nil then
									if (uRow.BuildCharges or 0) > 0 then
										emp.builders = emp.builders + 1;
									elseif uRow.FoundCity == true or uRow.FoundCity == 1 then
										emp.settlers = emp.settlers + 1;
									elseif (uRow.Combat or 0) > 0 and uRow.PromotionClass ~= "PROMOTION_CLASS_RECON" then
										emp.military = emp.military + 1;
									end
								end
							end
						end
					end
				end
			end
		end
	end
end

-- ------------------------------------------------------------------ UI -------

local function SetLbl(ctrl, text, on, warn)
	if ctrl == nil then return end
	ctrl:SetText(text);
	if warn and on then ctrl:SetColor(COL_WARN);
	elseif on then ctrl:SetColor(COL_ON);
	else ctrl:SetColor(COL_OFF); end
end

function RefreshUI()
	SetLbl(Controls.ABA_MasterLbl,   g_master and "AUTO: ON" or "AUTO: OFF", g_master);
	SetLbl(Controls.ABA_BuildersLbl, "Builders: " .. (g_builders and "ON" or "OFF"), g_builders);
	SetLbl(Controls.ABA_ArmiesLbl,   "Armies: "   .. (g_armies   and "ON" or "OFF"), g_armies);
	SetLbl(Controls.ABA_ResearchLbl, "Research: "   .. (g_research and "ON" or "OFF"), g_research);
	SetLbl(Controls.ABA_ProduceLbl,  "Production: " .. (g_produce  and "ON" or "OFF"), g_produce);
	SetLbl(Controls.ABA_AdvanceLbl,  "Advance: "    .. (g_advance  and "ON" or "OFF"), g_advance, true);

	-- Attack block: show what pressing ATTACK will actually do, right now.
	if g_target ~= nil then
		SetLbl(Controls.ABA_AttackLbl, "ATTACKING " .. string.upper(g_target.name), true, true);
		if Controls.ABA_TargetHint ~= nil then
			Controls.ABA_TargetHint:SetText("All armies are marching on " .. g_target.name .. ".");
		end
	elseif g_candidate ~= nil then
		SetLbl(Controls.ABA_AttackLbl, "ATTACK " .. string.upper(g_candidate.name), false);
		if Controls.ABA_TargetHint ~= nil then
			Controls.ABA_TargetHint:SetText("Selected: " .. g_candidate.name .. ". Press ATTACK to commit.");
		end
	else
		SetLbl(Controls.ABA_AttackLbl, "ATTACK", false);
		if Controls.ABA_TargetHint ~= nil then
			Controls.ABA_TargetHint:SetText("Click an enemy city, then ATTACK.");
		end
	end
	if Controls.ABA_ClearBtn ~= nil then Controls.ABA_ClearBtn:SetHide(g_target == nil) end

	if Controls.ABA_Body   ~= nil then Controls.ABA_Body:CalculateSize() end
	if Controls.ABA_Stack  ~= nil then Controls.ABA_Stack:CalculateSize() end
end

local function UpdateStatus(nB, nA)
	if Controls.ABA_Status == nil then return end
	local t = (Game.GetCurrentGameTurn ~= nil) and Game.GetCurrentGameTurn() or 0;
	if not g_master then
		Controls.ABA_Status:SetText("Off. The game plays as normal.");
	else
		Controls.ABA_Status:SetText("Turn " .. t .. ": " .. nB .. " builder(s), " .. nA .. " unit(s) acted.");
	end
	if Controls.ABA_Stack ~= nil then Controls.ABA_Stack:CalculateSize() end
end

-- ------------------------------------------------------------- main pass ----

local function RunAutomation()
	if not g_master then return end
	local eLocalPlayer = Game.GetLocalPlayer();
	if eLocalPlayer == -1 then return end
	local pPlayer = Players[eLocalPlayer];
	if pPlayer == nil then return end
	local pDiplo = pPlayer:GetDiplomacy();
	local pVis   = PlayersVisibility[eLocalPlayer];

	-- Stop assaulting a city that is already ours (or gone).
	if g_target ~= nil then
		local plot = Map.GetPlot(g_target.x, g_target.y);
		if plot == nil or not IsEnemyCityPlot(plot, eLocalPlayer, pDiplo, pVis) then
			Log("target %s no longer a hostile city (taken, destroyed, or peace) -- standing down", g_target.name);
			g_target = nil;
			RefreshUI();
		end
	end

	local threats = BuildThreatCache(eLocalPlayer, pDiplo, pVis);

	-- Threatened-city scan (#25): the own city closest to an enemy within
	-- CITY_DEFENSE_RADIUS. Non-nil flips nearby soldiers into defense mode and
	-- vetoes settler production for the duration.
	g_defcity = nil;
	if threats ~= nil and #threats > 0 then
		local okDC, cities = pcall(function() return pPlayer:GetCities(); end);
		if okDC and cities ~= nil then
			for _, pCity in cities:Members() do
				-- LAND threats only (audit #11): a barb galley cruising the
				-- coast flipped empire-wide defense mode that melee defenders
				-- can never resolve -- converge/hold/settler-freeze forever.
				-- The production override below keeps its own any-domain scan
				-- (it can answer boats with ranged builds; soldiers cannot).
				local d = NearestThreatDist(threats, pCity:GetX(), pCity:GetY(), true);
				if d ~= nil and d <= CITY_DEFENSE_RADIUS
				   and (g_defcity == nil or d < g_defcity.dist) then
					g_defcity = { x = pCity:GetX(), y = pCity:GetY(),
					              name = pCity:GetName(), dist = d };
				end
			end
		end
		if g_defcity ~= nil
		   and (g_defLogName ~= g_defcity.name or g_defLogDist ~= g_defcity.dist) then
			-- Log on CHANGE only: the every-pass repeat was drowning the log.
			Log("CITY UNDER THREAT: %s (enemy %d out) -- defense mode on",
				tostring(g_defcity.name), g_defcity.dist);
			g_defLogName, g_defLogDist = g_defcity.name, g_defcity.dist;
		end
	end

	-- One army snapshot per pass, taken BEFORE anything moves: every unit must
	-- judge cohesion against the same picture, or the first unit to move shifts
	-- the rally point under the feet of the next one and they chase each other.
	local army = BuildArmyCache(pPlayer);

	-- Free damage first (#29): every city/encampment strike that CAN fire, fires.
	if g_armies then
		AutomateCityStrikes(pPlayer, eLocalPlayer, pDiplo, pVis);
	end

	if g_research then
		AutomateResearch(pPlayer);
		AutomateCivics(pPlayer);
		AutomateEnvoys(pPlayer);
		AutomatePantheon(pPlayer);
		AutomateReligion(pPlayer);
		AutomateGreatPeopleClaim(pPlayer);
	end
	if g_produce then
		AutomateProduction(pPlayer, threats);
	end

	local nB, nA = 0, 0;
	local nBuilders, nSkipped = 0, 0;
	for _, pUnit in pPlayer:GetUnits():Members() do
		local id = pUnit:GetID();
		local isBuilder = IsBuilder(pUnit);
		if isBuilder then nBuilders = nBuilders + 1 end

		-- Promotions are checked for EVERY unit, BEFORE the idle test and outside
		-- the tasked debounce. A unit that earned a promotion is usually one that
		-- just fought and fortified, and fortified units do not read as idle --
		-- so gating this behind the idle test would miss precisely the units that
		-- block the turn.
		TryPromote(pUnit);
		-- Upgrades ride the same pre-idle-gate slot (#30): a fortified warrior
		-- eligible for swordsman never reads idle, exactly like promotions.
		if g_armies and IsCombatUnit(pUnit) then TryUpgrade(pUnit, pPlayer) end

		if not g_tasked[id] then
			local why = IdleReason(pUnit);
			if why == nil then
				-- Each branch returns a verb, or nil/"idle" meaning "I issued
				-- nothing". THE INVARIANT: nothing leaves this block without either
				-- a real order or the catch-all. Do not add a branch that can
				-- silently issue nothing -- that is the whole "things get stuck"
				-- bug, and it cost an entire play session to find.
				local r, kind = nil, nil;

				if g_builders and isBuilder then
					kind = "builder";
					if (g_declines[id] or 0) >= 2 then
						r = nil;   -- two no-order passes already; catch-all only
					else
						r = AutomateBuilder(pUnit, pPlayer, threats);
					end
					LogOnce("bact:" .. id .. ":" .. tostring(r), "builder %d -> %s", id, tostring(r));
					if r == "build" or r == "repair" or r == "move" then nB = nB + 1 end
					-- Unemployment signal for composition (issue #5): charges but
					-- no work means stop hiring, not hire more.
					if (r == nil or r == "idle" or r == "rest") and pUnit:GetBuildCharges() > 0 then
						g_builderIdleThisTurn = true;
					end
				elseif IsTrader(pUnit) then
					kind = "trader";
					-- Decline gates (audit #17/#24): after two no-order passes
					-- this turn the outcome is known -- catch-all only, same as
					-- the builder/army branches. Kills the per-pass re-brain churn.
					if (g_declines[id] or 0) < 2 then r = AutomateTrader(pUnit, pPlayer) end
				elseif GetGP(pUnit) ~= nil then
					kind = "greatperson";
					if (g_declines[id] or 0) < 2 then r = AutomateGreatPerson(pUnit, pPlayer, GetGP(pUnit)) end
				elseif IsSettler(pUnit) then
					kind = "settler";
					if (g_declines[id] or 0) < 2 then r = AutomateSettler(pUnit, pPlayer, threats) end
				-- Recon before combat: scouts have a combat value, so without this
				-- they fell into the armies branch and just fortified ("scouts
				-- don't know what to do with themselves"). Wounded scouts retreat
				-- and heal INSTEAD of exploring -- re-exploring while hurt was
				-- how they died.
				elseif IsRecon(pUnit) then
					kind = "recon";
					-- Threat gate BEFORE explore (issue #2): the engine ACCEPTS
					-- auto-explore for a unit in enemy contact and then instantly
					-- drops the automation -- 22 futile explore orders in one live
					-- session. Near a threat, don't even ask: disengage first,
					-- explore again once contact is broken.
					local dScout = NearestThreatDist(threats, pUnit:GetX(), pUnit:GetY());
					local inContact = (dScout ~= nil and dScout <= 3);
					if HPPercent(pUnit) < SCOUT_RETREAT_HP or inContact then
						-- Hurt but DISENGAGED -> heal where we stand. Retreating
						-- on every pass re-tasked hurt scouts to the cap turn
						-- after turn (196608/393220 live) and they never healed.
						if not inContact then
							if CanStart(pUnit, UnitOperationTypes.HEAL) then
								IssueOp(pUnit, UnitOperationTypes.HEAL);
								r = "heal";
							elseif CanStart(pUnit, UnitOperationTypes.SKIP_TURN) then
								IssueOp(pUnit, UnitOperationTypes.SKIP_TURN);
								r = "rest";
							end
						end
						if r == nil then
							r = ScoutRetreat(pUnit, pPlayer, threats) and "retreat" or nil;
						end
						if r == nil and inContact and g_armies then
							r = AutomateCombatUnit(pUnit, eLocalPlayer, pDiplo, pVis, threats, nil);
						end
					else
						r = TryAutoExplore(pUnit) and "explore" or nil;
						if r == nil then
							-- Auto-explore refused: the engine will not automate a unit
							-- in enemy contact. THIS is what stranded the scout. A scout
							-- is not a soldier: break contact FIRST so exploring works
							-- again next turn, and only fight if there is genuinely no
							-- way out. (Combat before retreat would hand the scout to
							-- AdvanceToward, which marches it AT the enemy -- suicide
							-- for 10 strength.) Army is nil on purpose: scouts are not
							-- part of the battle line and never wait to group up.
							if ScoutRetreat(pUnit, pPlayer, threats) then
								r = "withdraw";
							elseif g_armies then
								r = AutomateCombatUnit(pUnit, eLocalPlayer, pDiplo, pVis, threats, nil);
							end
						end
					end
					if r ~= nil then nA = nA + 1 end
				elseif g_armies and IsCombatUnit(pUnit) then
					kind = "army";
					-- Two dropped orders this turn = the engine is refusing this
					-- unit's plan (ZOC advance, contested tile...). A third
					-- identical attempt was never going to work -- observed as
					-- 4 warriors churning to the cap every turn. Rest instead;
					-- fresh judgement next turn.
					if (g_retasks[id] or 0) >= 2 or (g_declines[id] or 0) >= 2 then
						r = nil;
					else
						-- Sea units fight solo: the army cache is land-only, so
						-- judging a galley's cohesion against the land army's
						-- centre of mass just marched it at a coastline forever.
						local infoU = GameInfo.Units[pUnit:GetUnitType()];
						local landArmy = (infoU ~= nil and infoU.Domain == "DOMAIN_LAND") and army or nil;
						r = AutomateCombatUnit(pUnit, eLocalPlayer, pDiplo, pVis, threats, landArmy);
					end
					if r ~= nil then nA = nA + 1 end
				elseif g_armies and IsSupportUnit(pUnit) then
					kind = "support";
					r = AutomateSupportUnit(pUnit, pPlayer, army);
					if r ~= nil then nA = nA + 1 end
				else
					-- Religious units and anything else we do not model yet.
					kind = "unclassified";
				end

				g_tasked[id] = true;

				-- The catch-all. A class we DO automate retries next turn (skip);
				-- a class we have no branch for sleeps so it stops asking every
				-- turn -- and either way the log names it, which is how we learn
				-- what to automate next.
				if r == nil or r == "idle" then
					g_declines[id] = (g_declines[id] or 0) + 1;
					-- Past the strike cap the outcome is known -- order the skip
					-- without re-logging the same UNSTUCK line every re-sweep.
					EnsureOrdered(pUnit, (kind or "?") .. ": no order issued",
						kind ~= "unclassified");
				end
			elseif isBuilder then
				-- The single most useful diagnostic: "my builder just sits there"
				-- is almost always this line telling us it never looked idle.
				-- Once per unit per reason per turn (#33: the old first-two-per-
				-- PASS cap printed the same line 375 times in one session).
				nSkipped = nSkipped + 1;
				LogOnce("bskip:" .. id .. ":" .. tostring(why), "builder %d SKIPPED: %s", id, why);
			elseif g_armies
			   and why ~= "dead" and why ~= "nil-unit"
			   and why ~= "no-moves-left" and why ~= "already-has-queued-destination"
			   and IsCombatUnit(pUnit) and not IsRecon(pUnit) then
				-- THE "warriors don't fight back" fix. A unit that fortified once
				-- stops reading as AWAKE, so the idle filter hid it from us
				-- forever -- it would hold pose while barbarians razed the
				-- suburbs. Fortified is not a reason to ignore a war on the
				-- doorstep: if a visible enemy is close, wake it and fight.
				-- Melee units only wake for LAND threats -- a galley offshore
				-- is unhittable for them (Anthony's boat report).
				local dT = NearestThreatDist(threats, pUnit:GetX(), pUnit:GetY(), not IsRanged(pUnit));
				if dT ~= nil and dT <= 3 and pUnit:GetMovesRemaining() > 0
				   and not g_woken[id] and why ~= "order-in-flight" then
					-- Once per turn: this branch bypasses the idle filter by
					-- design, and without its own debounce each fortify that
					-- resolved re-woke the same unit (21x in one live session).
					g_woken[id] = true;
					Log("waking unit %d: enemy %d tiles away (was: %s)", id, dT, why);
					AutomateCombatUnit(pUnit, eLocalPlayer, pDiplo, pVis, threats, army);
					g_tasked[id] = true;
					nA = nA + 1;
				end
			end
		end
	end
	UpdateStatus(nB, nA);
end

-- ------------------------------------------------------- debounce & events --

local function RequestPass()
	g_dirty = true;
end

local function IsSafeToIssue()
	if GameConfiguration.IsAnyMultiplayer() then return false end
	local e = Game.GetLocalPlayer();
	if e == -1 then return false end
	local p = Players[e];
	if p == nil or not p:IsTurnActive() then return false end
	if UI.IsProcessingMessages() then return false end
	return true;
end

local function OnPublishComplete()
	if not g_dirty then return end
	if not g_master then g_dirty = false; return end
	if not IsSafeToIssue() then return end   -- keep dirty; retry after the next batch
	g_dirty = false;

	-- Called directly: the Safe("PublishComplete") wrapper catches and reports any
	-- throw WITH a traceback. An inner pcall here would swallow the traceback and
	-- leave us guessing at line numbers again.
	RunAutomation();
end

-- ------------------------------------------------------------- telemetry ----
--
-- The learning loop's state channel (issue #8). One [ABA-TEL] line per turn:
-- print() is the sandbox's only door to the outside (no file/net IO), and we
-- already read Lua.log externally. The REWARD side is free -- the game grades
-- itself (GetScore, plus the per-turn AI_*.csv files the engine writes) -- so
-- this line only needs the STATE the CSVs don't carry. Single line, k=v pairs,
-- trivially parseable. Every getter pcall-guarded and grep-verified:
-- GetScore ARXManager.lua:43, yields TopPanel.lua:107-147, population
-- CitySupport.lua, GetNumTechsResearched ARXManager.lua:142, Game.GetEras
-- (nil-guarded, PortraitSupport.lua:26).
local function EmitTelemetry(pPlayer)
	local function N(f, d) local ok, v = pcall(f); return (ok and v ~= nil) and v or (d or 0) end
	local turn  = N(function() return Game.GetCurrentGameTurn() end);
	local score = N(function() return pPlayer:GetScore() end);
	local sci   = N(function() return pPlayer:GetTechs():GetScienceYield() end);
	local cul   = N(function() return pPlayer:GetCulture():GetCultureYield() end);
	local gpt   = N(function() return pPlayer:GetTreasury():GetGoldYield() - pPlayer:GetTreasury():GetTotalMaintenance() end);
	local gold  = N(function() return math.floor(pPlayer:GetTreasury():GetGoldBalance()) end);
	local fpt   = N(function() return pPlayer:GetReligion():GetFaithYield() end);
	local nTech = N(function() return pPlayer:GetStats():GetNumTechsResearched() end);
	local era   = N(function() return Game.GetEras():GetCurrentEra() end, -1);

	local nCities, pop = 0, 0;
	local okC, cities = pcall(function() return pPlayer:GetCities() end);
	if okC and cities ~= nil then
		for _, c in cities:Members() do
			nCities = nCities + 1;
			pop = pop + (N(function() return c:GetPopulation() end));
		end
	end
	local nUnits, nMil = 0, 0;
	local okU, units = pcall(function() return pPlayer:GetUnits() end);
	if okU and units ~= nil then
		for _, u in units:Members() do
			if not u:IsDead() then
				nUnits = nUnits + 1;
				if IsCombatUnit(u) then nMil = nMil + 1 end
			end
		end
	end

	print(string.format(
		"[ABA-TEL] turn=%d era=%d score=%d cities=%d pop=%d units=%d mil=%d sci=%.1f cul=%.1f gpt=%.1f gold=%d fpt=%.1f techs=%d",
		turn, era, score, nCities, pop, nUnits, nMil, sci, cul, gpt, gold, fpt, nTech));
end

local function OnLocalPlayerTurnBegin()
	-- Last turn's suppressed-log summary BEFORE the reset (#33): hot blockers
	-- stay visible to the outside monitor without the per-event flood.
	for k, v in pairs(g_blkLogged) do
		if v > 1 then Log("blocker %s fired x%d last turn (suppressed)", k, v) end
	end
	g_blkLogged      = {};
	g_tasked         = {};
	g_cityOrdered    = {};
	g_cityBought     = {};
	g_promoted       = {};
	g_upgraded       = {};
	g_upgradeCount   = 0;
	g_struck         = {};
	g_researchDone   = false;
	g_civicDone      = false;
	g_envoyLastTokens = -1;
	g_retasks        = {};
	g_districtNoPlot = {};
	g_inflight       = {};
	g_woken          = {};
	g_claims         = {};
	g_refused        = {};
	g_envoyDone      = false;
	g_pantheonDone   = false;
	g_religionDone   = false;
	g_gpDone         = false;
	g_declines       = {};
	g_logOnce        = {};
	g_builderIdleLastTurn = g_builderIdleThisTurn;
	g_builderIdleThisTurn = false;
	local e = Game.GetLocalPlayer();
	if e ~= nil and e ~= -1 and Players[e] ~= nil then
		pcall(EmitTelemetry, Players[e]);
	end
	RequestPass();
end

local function OnUnitDone(player)
	if player == Game.GetLocalPlayer() then RequestPass(); end
end

-- ------------------------------------------------------ blocker watchdog ----
--
-- THE OBSERVABILITY FIX (Anthony: "I basically shouldn't have to send
-- screenshots"). The engine can flip a unit to needs-orders without firing any
-- event we subscribe to -- observed live: builder at 2/2 moves showing UNIT
-- NEEDS ORDERS while our last read said not-ready-to-move, and no later event
-- ever re-swept it. The game's OWN end-turn-blocker system is the ground
-- truth (ActionPanel.lua:612 event, :165 getter), so watch THAT:
--   * every change of blocker is logged BY NAME -> the outside monitor sees
--     exactly what the END TURN button sees, screenshot-free;
--   * a units-type blocker means some unit the sweep thinks is handled is not
--     -- clear the tasked set and re-sweep (safe now: g_inflight, not
--     g_tasked, is what prevents double-orders);
--   * any other blocker re-runs the pass so the matching automation
--     (research/civic/pantheon/religion/envoy/production) gets another shot.
local function BlockerName(eType)
	for k, v in pairs(EndTurnBlockingTypes) do
		if v == eType then return k end
	end
	return tostring(eType);
end

local function OnEndTurnBlockingChanged(ePrev, eNew)
	if eNew == nil or eNew == EndTurnBlockingTypes.NO_ENDTURN_BLOCKING then return end
	local name = BlockerName(eNew);
	-- First fire per blocker type per turn logs; repeats are counted and
	-- summarized at TurnBegin (#33: x145 UNITS lines in one session).
	g_blkLogged[name] = (g_blkLogged[name] or 0) + 1;
	if g_blkLogged[name] == 1 then Log("END-TURN BLOCKED by %s", name) end
	if eNew == EndTurnBlockingTypes.ENDTURN_BLOCKING_UNITS
	   or eNew == EndTurnBlockingTypes.ENDTURN_BLOCKING_UNIT_NEEDS_ORDERS
	   or eNew == EndTurnBlockingTypes.ENDTURN_BLOCKING_STACKED_UNITS then
		g_tasked = {};   -- someone we "handled" is not handled; look again at everyone
	elseif eNew == EndTurnBlockingTypes.ENDTURN_BLOCKING_PRODUCTION then
		-- Mirror of the units fix (issue #18, Nidaros t77 freeze): an
		-- accepted-then-dropped city order left g_cityOrdered set for the
		-- whole turn and the re-pass skipped the idle city.
		g_cityOrdered = {};
	elseif eNew == EndTurnBlockingTypes.ENDTURN_BLOCKING_GIVE_INFLUENCE_TOKEN then
		g_envoyDone = false;    -- tokens arrived after this turn's envoy pass
	elseif eNew == EndTurnBlockingTypes.ENDTURN_BLOCKING_PANTHEON then
		g_pantheonDone = false;
	elseif eNew == EndTurnBlockingTypes.ENDTURN_BLOCKING_RELIGION
	   or eNew == EndTurnBlockingTypes.ENDTURN_BLOCKING_BELIEF then
		g_religionDone = false;
	elseif eNew == EndTurnBlockingTypes.ENDTURN_BLOCKING_CLAIM_GREAT_PERSON then
		g_gpDone = false;
	elseif eNew == EndTurnBlockingTypes.ENDTURN_BLOCKING_RESEARCH then
		g_researchDone = false;   -- slot freed mid-turn; re-arm the async guard
	elseif eNew == EndTurnBlockingTypes.ENDTURN_BLOCKING_CIVIC then
		g_civicDone = false;
	end
	RequestPass();
end

-- THE "builder moved and froze" FIX (turn 5, live). One-order-per-unit-per-turn
-- deadlocks when the order finishes EARLY: builder moves one tile, has 1 move
-- left, game blocks the turn on UNIT HAS MOVES -- but the unit is already in
-- g_tasked, the turn cannot end, so TurnBegin never clears the debounce. Frozen.
--
-- The game's own end-turn panel listens to exactly these two events to update
-- the "units have moves" state (ActionPanel.lua:1350-1351,827-843), so they are
-- precisely "a unit's order resolved; re-evaluate". We clear that unit's
-- debounce and re-sweep: a unit with moves left gets its next order (builder
-- moves AND builds in one turn now), a unit without reads as not-ready and is
-- skipped. Capped per unit per turn because an order the engine accepts and
-- then drops would otherwise re-issue forever within the turn.
local MAX_RETASKS = 4;

local function OnUnitOpResolved(player, unitID, hCommand, iData1)
	if player ~= Game.GetLocalPlayer() then return end
	g_inflight[unitID] = nil;   -- whatever was pending is pending no more

	-- Death releases destination claims (audit #3): a dead unit's claim
	-- otherwise blocks that tile for every other unit until turn end.
	local pPD = Players[player];
	local pUD = (pPD ~= nil) and pPD:GetUnits():FindID(unitID) or nil;
	if pUD == nil or pUD:IsDead() then
		for k, v in pairs(g_claims) do
			if v == unitID then g_claims[k] = nil end
		end
	end

	if g_tasked[unitID] then
		-- Untask ONLY a unit that is genuinely ready for more. A resolved skip/
		-- fortify means "done for this turn" -- untasking those invited the next
		-- pass to order the same unit again, which is the skip->untask->skip
		-- oscillation and the 21-wakes-per-turn warrior from the live session.
		local pPlayer = Players[player];
		local pUnit = (pPlayer ~= nil) and pPlayer:GetUnits():FindID(unitID) or nil;
		local ready = pUnit ~= nil and not pUnit:IsDead()
			and pUnit:IsReadyToMove() and pUnit:GetMovesRemaining() > 0;
		if ready then
			local n = (g_retasks[unitID] or 0) + 1;
			g_retasks[unitID] = n;
			if n > MAX_RETASKS then
				-- Accept-then-drop loop: the engine keeps taking our order and
				-- resolving it with the unit unmoved. Leaving it tasked-but-AWAKE
				-- blocked the turn (issue #4) -- force a TERMINAL state instead.
				-- Sleep survives further passes; skip at least ends this turn.
				if n == MAX_RETASKS + 1 then
					Log("unit %d: re-task cap (%d) -- forcing rest", unitID, MAX_RETASKS);
					local opSleep = ResolveOp(UnitOperationTypes.SLEEP, "UNITOPERATION_SLEEP");
					if CanStart(pUnit, opSleep) then IssueOp(pUnit, opSleep);
					else
						-- Full lever chain incl. ALERT + step-out (issue #14 --
						-- sleep AND skip were both refused live).
						EnsureOrdered(pUnit, "re-task cap", true);
					end
				end
				return;
			end
			g_tasked[unitID] = nil;
		end
	end
	-- Always re-sweep: even an untasked unit resolving an op (a multi-turn move
	-- arriving, engine-driven exploration ending) means someone may now be idle.
	RequestPass();
end

-- A unit trained mid-turn is idle the instant it appears. Without this it just
-- stands in the city until the NEXT turn begins, which reads as "automation is
-- broken" -- you built the builder and nothing happened.
local function OnUnitAddedToMap(playerID, unitID)
	if playerID ~= Game.GetLocalPlayer() then return end
	g_tasked[unitID] = nil;   -- brand new unit: it has not been ordered this turn
	RequestPass();
end

-- ------------------------------------------------------------- toggles ------

local function Toggle(which)
	if which == "master" then
		g_master = not g_master; GameConfiguration.SetValue(KEY_MASTER, g_master);
	elseif which == "builders" then
		g_builders = not g_builders; GameConfiguration.SetValue(KEY_BUILDERS, g_builders);
	elseif which == "armies" then
		g_armies = not g_armies; GameConfiguration.SetValue(KEY_ARMIES, g_armies);
	elseif which == "advance" then
		g_advance = not g_advance; GameConfiguration.SetValue(KEY_ADVANCE, g_advance);
	elseif which == "research" then
		g_research = not g_research; GameConfiguration.SetValue(KEY_RESEARCH, g_research);
	elseif which == "produce" then
		g_produce = not g_produce; GameConfiguration.SetValue(KEY_PRODUCE, g_produce);
	end
	UI.PlaySound("Main_Menu_Mouse_Over");
	RefreshUI();
	RequestPass();   -- apply immediately if it is safe
end

-- ------------------------------------------------------- attack targeting ---
--
-- How you point at a target: click the enemy city's banner on the map. Civ6
-- raises CitySelectionChanged for ANY city you select, including ones you do
-- not own, so this needs no input hooking and cannot fight other UI mods.
-- Selecting only *arms* the button; the ATTACK press is what commits.

local function OnCitySelectionChanged(ownerPlayerID, cityID, i, j, k, isSelected, isEditable)
	if not isSelected then return end
	local eLocalPlayer = Game.GetLocalPlayer();
	if eLocalPlayer == -1 or ownerPlayerID == eLocalPlayer then return end

	local ok, pCity = pcall(function() return CityManager.GetCity(ownerPlayerID, cityID); end);
	if not ok or pCity == nil then return end

	local name = "enemy city";
	local okN, n = pcall(function() return Locale.Lookup(pCity:GetName()); end);
	if okN and n ~= nil then name = n end

	g_candidate = { x = i, y = j, name = name, owner = ownerPlayerID };
	Log("target candidate = %s (player %d) at %d,%d", name, ownerPlayerID, i, j);
	RefreshUI();
end

local function OnAttack()
	if g_candidate == nil then
		if Controls.ABA_TargetHint ~= nil then
			Controls.ABA_TargetHint:SetText("Pick a target first: click an enemy city on the map.");
		end
		return;
	end

	-- You must already be at war. We deliberately do NOT declare war for you --
	-- that is a huge, irreversible diplomatic act and nobody wants a button in a
	-- corner panel doing it. Without this check the order would look accepted and
	-- then be silently wiped by the cleanup pass, which reads as "the mod is broken".
	local eLocalPlayer = Game.GetLocalPlayer();
	local pPlayer      = Players[eLocalPlayer];
	if pPlayer ~= nil then
		local pDiplo = pPlayer:GetDiplomacy();
		if pDiplo ~= nil and not pDiplo:IsAtWarWith(g_candidate.owner) then
			Log("ATTACK refused: not at war with player %d (%s)", g_candidate.owner, g_candidate.name);
			if Controls.ABA_TargetHint ~= nil then
				Controls.ABA_TargetHint:SetText("Not at war with " .. g_candidate.name .. ". Declare war first, then press ATTACK.");
			end
			UI.PlaySound("Play_UI_Click");
			return;
		end
	end

	-- Committing an assault implies you want the army moving: turn the switches
	-- on rather than silently doing nothing behind an OFF master toggle.
	g_target = g_candidate;
	g_master = true;  GameConfiguration.SetValue(KEY_MASTER, true);
	g_armies = true;  GameConfiguration.SetValue(KEY_ARMIES, true);

	g_tasked = {};    -- re-order every unit this turn, do not wait for next turn
	Log("ATTACK committed -> %s at %d,%d", g_target.name, g_target.x, g_target.y);
	UI.PlaySound("Play_UI_Click");
	RefreshUI();
	RequestPass();
end

local function OnClearTarget()
	g_target = nil;
	g_tasked = {};
	UI.PlaySound("Main_Menu_Mouse_Over");
	RefreshUI();
	RequestPass();
end

local function OnHeader()
	g_collapsed = not g_collapsed;
	if Controls.ABA_Body ~= nil then Controls.ABA_Body:SetHide(g_collapsed) end
	if Controls.ABA_Caret ~= nil then Controls.ABA_Caret:SetText(g_collapsed and "[+]" or "[-]") end
	if Controls.ABA_Stack ~= nil then Controls.ABA_Stack:CalculateSize() end
end

local function LoadPrefs()
	local function g(k, d)
		local v = GameConfiguration.GetValue(k);
		if v == nil then return d end
		return v;
	end
	g_master   = g(KEY_MASTER,   true);
	g_builders = g(KEY_BUILDERS, true);
	g_armies   = g(KEY_ARMIES,   true);
	g_advance  = g(KEY_ADVANCE,  true);
	g_research = g(KEY_RESEARCH, true);
	g_produce  = g(KEY_PRODUCE,  true);
	-- Attack targets are deliberately NOT persisted: loading a save should never
	-- resume a war march you gave the order for two sessions ago.
	g_target, g_candidate = nil, nil;
	RefreshUI();
	UpdateStatus(0, 0);
end

-- A finished build re-opens that city for orders within the same turn, and may
-- have added great-work slots for a sleeping great person (#27).
local function OnCityProductionCompleted(playerID, cityID)
	if playerID == Game.GetLocalPlayer() then
		g_cityOrdered[cityID] = nil;
		if next(g_gpStrikes) ~= nil then
			local pP = Players[playerID];
			local okU, us = pcall(function() return pP:GetUnits(); end);
			if okU and us ~= nil then
				local opWake = ResolveOp(UnitOperationTypes.WAKE, "UNITOPERATION_WAKE");
				for _, u in us:Members() do
					local uid = u:GetID();
					if (g_gpStrikes[uid] or 0) >= 3 then
						g_gpStrikes[uid] = nil;
						if CanStart(u, opWake) then IssueOp(u, opWake) end
						Log("great person %d: a build completed -> re-checking activation", uid);
					end
				end
			end
		end
	end
	RequestPass();
end

-- --------------------------------------------------------------- init -------

-- Everything cached here is plain data (functions cannot cross a hotload --
-- AdvisorPopup.lua:479). What is NOT cached resets safely: per-turn debounce
-- tables re-derive within one pass; toggles live in GameConfiguration.
local function OnShutdown()
	for _, s in ipairs(g_eventSubs) do
		pcall(function() s.ev.Remove(s.fn) end);
	end
	g_eventSubs = {};
	LuaEvents.GameDebug_AddValue(RELOAD_CACHE_ID, "target",      g_target);
	LuaEvents.GameDebug_AddValue(RELOAD_CACHE_ID, "candidate",   g_candidate);
	LuaEvents.GameDebug_AddValue(RELOAD_CACHE_ID, "settlerPlan", g_settlerPlan);
	LuaEvents.GameDebug_AddValue(RELOAD_CACHE_ID, "rallyStuck",  g_rallyStuck);
	LuaEvents.GameDebug_AddValue(RELOAD_CACHE_ID, "gpStrikes",   g_gpStrikes);
	LuaEvents.GameDebug_AddValue(RELOAD_CACHE_ID, "plotSkip",    g_plotSkip);
	LuaEvents.GameDebug_AddValue(RELOAD_CACHE_ID, "inflight",    g_inflight);
	LuaEvents.GameDebug_AddValue(RELOAD_CACHE_ID, "tasked",      g_tasked);
	LuaEvents.GameDebug_AddValue(RELOAD_CACHE_ID, "collapsed",   g_collapsed);
end

local function OnGameDebugReturn(context, contextTable)
	if context ~= RELOAD_CACHE_ID or contextTable == nil then return end
	-- pcall like CityPanel.lua:792: a bad cache must never kill the reload.
	pcall(function()
		g_target      = contextTable["target"];
		g_candidate   = contextTable["candidate"];
		g_settlerPlan = contextTable["settlerPlan"] or {};
		g_rallyStuck  = contextTable["rallyStuck"]  or {};
		g_gpStrikes   = contextTable["gpStrikes"]   or {};
		g_plotSkip    = contextTable["plotSkip"]    or {};
		g_inflight    = contextTable["inflight"]    or {};
		g_tasked      = contextTable["tasked"]      or {};
		g_collapsed   = contextTable["collapsed"] == true;
		if Controls.ABA_Body ~= nil then Controls.ABA_Body:SetHide(g_collapsed) end
	end);
end

-- ALL event wiring lives here, through Sub(), so OnShutdown can unhook every
-- one of them by reference. Called by the engine via OnInit on every load.
local function LateInitialize()
	Sub(Events.LoadGameViewStateDone,        "LoadPrefs",        LoadPrefs);
	Sub(Events.LocalPlayerTurnBegin,         "TurnBegin",        OnLocalPlayerTurnBegin);
	Sub(Events.GameCoreEventPublishComplete, "PublishComplete",  OnPublishComplete);
	-- Both operation-resolution events AND UnitCommandStarted go through the
	-- untasking handler: commands (PROMOTE, ENTER_FORMATION, ACTIVATE, UPGRADE)
	-- resolve via their own event, not the operation queue -- without it every
	-- command froze its unit as order-in-flight all turn (live x11).
	Sub(Events.UnitOperationsCleared,        "UnitOpsCleared",   OnUnitOpResolved);
	Sub(Events.UnitOperationSegmentComplete, "UnitOpSegment",    OnUnitOpResolved);
	Sub(Events.UnitCommandStarted,           "UnitCmdStarted",   OnUnitOpResolved);
	Sub(Events.UnitMoveComplete,             "UnitMoveComplete", OnUnitDone);
	Sub(Events.EndTurnBlockingChanged,       "BlockingChanged",  OnEndTurnBlockingChanged);
	Sub(Events.UnitAddedToMap,               "UnitAddedToMap",   OnUnitAddedToMap);
	Sub(Events.CitySelectionChanged,         "CitySelChanged",   OnCitySelectionChanged);
	-- Research/civics free up mid-turn; cities go idle mid-turn; founding is
	-- async (the pass that ordered the settler ran before the city existed).
	Sub(Events.ResearchCompleted,            "ResearchDone",     RequestPass);
	Sub(Events.CivicCompleted,               "CivicDone",        RequestPass);
	Sub(Events.CityAddedToMap,               "CityAdded",        RequestPass);
	Sub(Events.CityProductionCompleted,      "ProductionDone",   OnCityProductionCompleted);
	Sub(LuaEvents.GameDebug_Return,          "DebugReturn",      OnGameDebugReturn);
end

local function OnInit(isReload)
	LateInitialize();
	if isReload then
		-- LIVE PATCH just applied (#34). LoadGameViewStateDone will not re-fire,
		-- so re-read prefs here (this resets g_target -- the cache restore that
		-- follows brings it back; LuaEvents are synchronous).
		LoadPrefs();
		LuaEvents.GameDebug_GetValues(RELOAD_CACHE_ID);
		Log("HOTLOAD complete -- new code live, state restored");
		RefreshUI();
		RequestPass();
	end
end

function Initialize()
	-- Multiplayer: disable completely (UI-context orders desync MP).
	if GameConfiguration.IsAnyMultiplayer() then
		Log("multiplayer detected -- Auto Commander disabled");
		if Controls.ABA_Root ~= nil then Controls.ABA_Root:SetHide(true) end
		return;
	end
	-- THE reason this panel was invisible despite loading fine:
	-- InGame.lua:347 loads every modded add-in with isHidden = true --
	--   local isHidden:boolean = true;
	--   ContextPtr:LoadNewContext(addin.ContextPath, Controls.AdditionalUserInterfaces, id, isHidden);
	-- so an add-in gets a HIDDEN context and must unhide itself. Nothing about
	-- the XML was wrong; the whole context was simply hidden.
	ContextPtr:SetHide(false);
	if Controls.ABA_Root ~= nil then Controls.ABA_Root:SetHide(false) end

	-- Park it against the right edge using the real screen width (see the anchor
	-- note in the XML). Falls back to a safe left-ish position if the call fails,
	-- because a visible panel in the wrong place beats an invisible one.
	pcall(function()
		local w, _ = UIManager:GetScreenSizeVal();
		if w ~= nil and w > 240 then
			Controls.ABA_Root:SetOffsetX(w - 226);
		end
	end);

	-- InGame.xml:133 declares <Container ID="AdditionalUserInterfaces"/> with NO
	-- Size, so our parent may be 0x0 and a right-anchored panel could resolve
	-- off-screen. Report real geometry rather than theorise about it again.
	-- Diagnostics must never be able to break init: everything below is pcall'd.
	pcall(function()
		local function Dim(c)
			if c == nil then return "nil" end
			local out = {};
			local okS, sx, sy = pcall(function() return c:GetSizeX(), c:GetSizeY() end);
			out[#out+1] = "size=" .. (okS and (tostring(sx) .. "," .. tostring(sy)) or "?");
			local okO, ox, oy = pcall(function() return c:GetOffsetX(), c:GetOffsetY() end);
			out[#out+1] = "offset=" .. (okO and (tostring(ox) .. "," .. tostring(oy)) or "?");
			local okH, h = pcall(function() return c:IsHidden() end);
			out[#out+1] = "hidden=" .. (okH and tostring(h) or "?");
			return table.concat(out, " ");
		end
		Log("init: panel %s", Controls.ABA_Root ~= nil and "found" or "MISSING");
		Log("init: context  %s", Dim(ContextPtr));
		Log("init: ABA_Root %s", Dim(Controls.ABA_Root));
		local okP, parent = pcall(function() return ContextPtr:GetParent() end);
		Log("init: parent   %s", okP and Dim(parent) or "?");
		local okScr, sw, sh = pcall(function() return UIManager:GetScreenSizeVal() end);
		Log("init: screen   %s x %s", okScr and tostring(sw) or "?", okScr and tostring(sh) or "?");
	end);

	-- Button callbacks are wrapped too: a throw inside a click handler is just as
	-- invisible as one inside an event handler.
	local function Bind(ctrl, name, fn)
		if ctrl ~= nil then ctrl:RegisterCallback(Mouse.eLClick, Safe(name, fn)) end
	end
	Bind(Controls.ABA_HeaderBtn,   "btn:header",   OnHeader);
	Bind(Controls.ABA_MasterBtn,   "btn:master",   function() Toggle("master") end);
	Bind(Controls.ABA_BuildersBtn, "btn:builders", function() Toggle("builders") end);
	Bind(Controls.ABA_ArmiesBtn,   "btn:armies",   function() Toggle("armies") end);
	Bind(Controls.ABA_AdvanceBtn,  "btn:advance",  function() Toggle("advance") end);
	Bind(Controls.ABA_ResearchBtn, "btn:research", function() Toggle("research") end);
	Bind(Controls.ABA_ProduceBtn,  "btn:produce",  function() Toggle("produce") end);
	Bind(Controls.ABA_AttackBtn,   "btn:attack",   OnAttack);
	Bind(Controls.ABA_ClearBtn,    "btn:clear",    OnClearTarget);

	-- Hot-reload lifecycle (#34): ALL event wiring lives in LateInitialize --
	-- the engine calls OnInit on every load (isReload=true on a live patch),
	-- and OnShutdown unhooks everything + caches state, so a mid-game file
	-- swap neither doubles handlers nor loses the war march.
	ContextPtr:SetInitHandler(OnInit);
	ContextPtr:SetShutdown(OnShutdown);

	RefreshUI();
end
Initialize();
