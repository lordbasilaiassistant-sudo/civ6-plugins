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
local MELEE_WOUNDED_HP  = 40   -- ...or if the enemy is at/below this HP%

-- ---------------------------------------------------------------- helpers ---

-- Guarded CanStartOperation wrapper.
local function CanStart(pUnit, op, tParams)
	if tParams ~= nil then
		return UnitManager.CanStartOperation(pUnit, op, nil, tParams);
	end
	return UnitManager.CanStartOperation(pUnit, op, nil, false, false);
end

-- Why is this unit NOT idle? Returns nil when it IS idle and awaiting orders.
-- Returning the reason (rather than a bare boolean) is what makes "my builder
-- just sits there" diagnosable from the log instead of guessable.
local function IdleReason(pUnit)
	if pUnit == nil then return "nil-unit" end
	if pUnit:IsDead() then return "dead" end
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
						t[#t + 1] = { x = u:GetX(), y = u:GetY() };
					end
				end
			end
		end
	end
	return t;
end

-- Distance from (x,y) to the nearest visible threat; nil if none visible.
local function NearestThreatDist(threats, x, y)
	local best = nil;
	for _, th in ipairs(threats) do
		local d = Map.GetPlotDistance(x, y, th.x, th.y);
		if best == nil or d < best then best = d end
	end
	return best;
end

local function MoveTo(pUnit, x, y)
	local tParams = {
		[UnitOperationTypes.PARAM_X] = x,
		[UnitOperationTypes.PARAM_Y] = y,
		[UnitOperationTypes.PARAM_MODIFIERS] = UnitOperationMoveModifiers.NONE,
	};
	if CanStart(pUnit, UnitOperationTypes.MOVE_TO, tParams) then
		UnitManager.RequestOperation(pUnit, UnitOperationTypes.MOVE_TO, tParams);
		return true;
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

local function TryAutoExplore(pUnit)
	local op = UnitOperationTypes.AUTOMATE_EXPLORE;
	if op == nil then
		local row = GameInfo.UnitOperations["UNITOPERATION_AUTOMATE_EXPLORE"];
		op = (row ~= nil) and row.Hash or nil;
	end
	if op == nil then return false end
	if not CanStart(pUnit, op) then return false end
	UnitManager.RequestOperation(pUnit, op);
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
			UnitManager.RequestOperation(pUnit, UnitOperationTypes.HEAL);
			Log("scout %d: clear of threats, healing", pUnit:GetID());
			return true;
		end
		if CanStart(pUnit, UnitOperationTypes.SKIP_TURN) then
			UnitManager.RequestOperation(pUnit, UnitOperationTypes.SKIP_TURN);
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

-- ------------------------------------------------------------- builders -----

-- Nearest reachable, unimproved tile the game recommends improving.
local function BestBuildTargetPlot(pPlayer, pUnit)
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
						if plot ~= nil and plot:GetImprovementType() == -1 and not plot:IsWater() and not plot:IsImpassable() then
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
	return best;
end

-- Returns one of: "repair" | "build" | "move" | "idle"
local function AutomateBuilder(pUnit, pPlayer)
	local x, y = pUnit:GetX(), pUnit:GetY();
	local plot = Map.GetPlot(x, y);

	-- 1) Repair a pillaged improvement/road under the builder first.
	if plot ~= nil and (plot:IsImprovementPillaged() or plot:IsRoutePillaged()) then
		if CanStart(pUnit, UnitOperationTypes.REPAIR) then
			UnitManager.RequestOperation(pUnit, UnitOperationTypes.REPAIR);
			return "repair";
		end
	end

	-- 2) Build the engine's recommended improvement on the current (unimproved) tile.
	if plot ~= nil and plot:GetImprovementType() == -1 then
		local tParams = { [UnitOperationTypes.PARAM_X] = x, [UnitOperationTypes.PARAM_Y] = y };
		local ok, res = UnitManager.CanStartOperation(pUnit, UnitOperationTypes.BUILD_IMPROVEMENT, nil, tParams, true);
		if ok and res ~= nil and res[UnitOperationResults.IMPROVEMENTS] ~= nil and #res[UnitOperationResults.IMPROVEMENTS] > 0 then
			local eBest = res[UnitOperationResults.BEST_IMPROVEMENT];
			if eBest == nil or eBest == -1 then eBest = res[UnitOperationResults.IMPROVEMENTS][1] end
			tParams[UnitOperationTypes.PARAM_IMPROVEMENT_TYPE] = eBest;
			local ok2 = UnitManager.CanStartOperation(pUnit, UnitOperationTypes.BUILD_IMPROVEMENT, nil, tParams, false);
			if ok2 then
				local info = GameInfo.Improvements[eBest];
				tParams[UnitOperationTypes.PARAM_IMPROVEMENT_TYPE] = (info ~= nil and info.Hash) or eBest;
				UnitManager.RequestOperation(pUnit, UnitOperationTypes.BUILD_IMPROVEMENT, tParams);
				return "build";
			end
		end
	end

	-- 3) Otherwise relocate toward the nearest recommended tile.
	local target = BestBuildTargetPlot(pPlayer, pUnit);
	if target ~= nil then
		local tParams = {
			[UnitOperationTypes.PARAM_X] = target:GetX(),
			[UnitOperationTypes.PARAM_Y] = target:GetY(),
			[UnitOperationTypes.PARAM_MODIFIERS] = UnitOperationMoveModifiers.NONE,
		};
		if CanStart(pUnit, UnitOperationTypes.MOVE_TO, tParams) then
			UnitManager.RequestOperation(pUnit, UnitOperationTypes.MOVE_TO, tParams);
			return "move";
		end
	end

	-- 4) Nothing worth doing: skip so it stops nagging, re-evaluated next turn.
	if CanStart(pUnit, UnitOperationTypes.SKIP_TURN) then
		UnitManager.RequestOperation(pUnit, UnitOperationTypes.SKIP_TURN);
	end
	return "idle";
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
			UnitManager.RequestOperation(pUnit, UnitOperationTypes.SKIP_TURN);
		end
		return "hold";
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
				UnitManager.RequestOperation(pUnit, UnitOperationTypes.FOUND_CITY);
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
			UnitManager.RequestOperation(pUnit, UnitOperationTypes.FOUND_CITY);
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
		UnitManager.RequestOperation(pUnit, UnitOperationTypes.FOUND_CITY);
		Log("settler: no better site reachable, founding at %d,%d", pUnit:GetX(), pUnit:GetY());
		return "found";
	end
	return "idle";
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

local function BestMeleeTarget(pUnit, eLocalPlayer, pDiplo, pVis, myStr)
	local ok, reach = pcall(function() return UnitManager.GetReachableTargets(pUnit); end);
	if not ok or reach == nil then return nil end
	local best, bestScore = nil, -1;
	for _, idx in ipairs(reach) do
		local plot = Map.GetPlotByIndex(idx);
		local e = GetEnemyOnPlot(plot, eLocalPlayer, pDiplo, pVis);
		if e ~= nil then
			local eStr = math.max(e:GetCombat(), e:GetRangedCombat());
			local eHp  = HPPercent(e);
			if (myStr >= eStr - MELEE_STR_MARGIN) or (eHp <= MELEE_WOUNDED_HP) then
				local score = (myStr - eStr) + (100 - eHp);
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
			UnitManager.RequestOperation(pUnit, UnitOperationTypes.MOVE_TO, tParams);
			return true;
		end
	end
	return false;
end

local function AutomateCombatUnit(pUnit, eLocalPlayer, pDiplo, pVis, threats)
	local x, y   = pUnit:GetX(), pUnit:GetY();
	local hp     = HPPercent(pUnit);
	local myStr  = math.max(pUnit:GetCombat(), pUnit:GetRangedCombat());
	local ranged = IsRanged(pUnit);

	-- A) Attack. Ranged fires from safety; melee only hits weaker/wounded foes.
	-- Only if the unit actually has an attack left: the base game gates its own
	-- target display on this (SelectedUnit.lua:62), and without it a spent unit
	-- burns its whole move walking onto a target it cannot hit.
	local okAtk, attacksLeft = pcall(function() return pUnit:GetAttacksRemaining() end);
	local canAttack = (not okAtk) or attacksLeft == nil or attacksLeft > 0;

	-- Branch on unit class INSIDE the attack gate: `ranged and canAttack ...
	-- else melee` would drop a ranged unit that had already fired into the
	-- melee branch and charge it into the enemy it just shot at.
	if canAttack then
		if ranged then
			local target = BestRangedTarget(pUnit, eLocalPlayer, pDiplo, pVis);
			if target ~= nil then
				local tParams = { [UnitOperationTypes.PARAM_X] = target:GetX(), [UnitOperationTypes.PARAM_Y] = target:GetY() };
				if CanStart(pUnit, UnitOperationTypes.RANGE_ATTACK, tParams) then
					UnitManager.RequestOperation(pUnit, UnitOperationTypes.RANGE_ATTACK, tParams);
					return "range";
				end
			end
		else
			local target = BestMeleeTarget(pUnit, eLocalPlayer, pDiplo, pVis, myStr);
			if target ~= nil then
				local tParams = {
					[UnitOperationTypes.PARAM_X] = target:GetX(),
					[UnitOperationTypes.PARAM_Y] = target:GetY(),
					[UnitOperationTypes.PARAM_MODIFIERS] = UnitOperationMoveModifiers.ATTACK,
				};
				if CanStart(pUnit, UnitOperationTypes.MOVE_TO, tParams) then
					UnitManager.RequestOperation(pUnit, UnitOperationTypes.MOVE_TO, tParams);
					return "attack";
				end
			end
		end
	end

	-- B) Wounded and safe -> heal (fortify until healed).
	if hp < HEAL_HP_THRESHOLD and StrongestAdjacentEnemy(x, y, eLocalPlayer, pDiplo, pVis) == 0 then
		if CanStart(pUnit, UnitOperationTypes.HEAL) then
			UnitManager.RequestOperation(pUnit, UnitOperationTypes.HEAL);
			return "heal";
		end
	end

	-- C) An explicit ATTACK order overrides everything: march on THAT city.
	--     Still respects healing above, so a broken unit pulls back rather than
	--     feeding itself to the walls one at a time.
	if g_target ~= nil and hp >= HEAL_HP_THRESHOLD then
		if AdvanceToward(pUnit, eLocalPlayer, pDiplo, pVis, myStr, g_target, threats) then
			return "assault";
		end
	end

	-- D) Optional: march on the nearest enemy along safe tiles (higher risk).
	if g_advance and hp >= HEAL_HP_THRESHOLD then
		if AdvanceToward(pUnit, eLocalPlayer, pDiplo, pVis, myStr, nil, threats) then
			return "advance";
		end
	end

	-- E) Hold the line.
	if CanStart(pUnit, UnitOperationTypes.FORTIFY) then
		UnitManager.RequestOperation(pUnit, UnitOperationTypes.FORTIFY);
		return "fortify";
	elseif CanStart(pUnit, UnitOperationTypes.SKIP_TURN) then
		UnitManager.RequestOperation(pUnit, UnitOperationTypes.SKIP_TURN);
	end
	return "hold";
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
	return true;
end

local function AutomateCivics(pPlayer)
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

local function AutomateProduction(pPlayer, threats)
	local okC, pCities = pcall(function() return pPlayer:GetCities(); end);
	if not okC or pCities == nil then return end

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
				local okCan, can = pcall(function() return pQueue:CanProduce(h, true); end);
				return okCan and can == true;
			end

			-- Defense first: with a visible enemy near the city, the advisor's
			-- settler/builder preferences are suicide (observed: Xi'an kept
			-- pumping settlers straight into barbarian hands). Build the
			-- strongest trainable land unit until the area is clear.
			local dCity = NearestThreatDist(threats, pCity:GetX(), pCity:GetY());
			if dCity ~= nil and dCity <= 4 then
				local best = nil;
				for row in GameInfo.Units() do
					if (row.Combat or 0) > 0 and row.Domain == "DOMAIN_LAND"
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
						if not isWonder and (kind == "KIND_UNIT" or kind == "KIND_BUILDING" or kind == "KIND_PROJECT")
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
									local info = GameInfo.Units[u:GetUnitType()];
									if info ~= nil then
										tally[info.UnitType] = (tally[info.UnitType] or 0) + 1;
									end
								end
							end

							local pick = nil;   -- {hash, kind, rank, cost}
							local function consider(row, kind)
								-- Same wonder exclusion as the advisor path.
								if row.IsWonder == true or row.IsWonder == 1 then return end
								if kind == "KIND_UNIT" and (tally[row.UnitType] or 0) >= 2 then return end
								local okCan, can = pcall(function() return pQueue:CanProduce(row.Hash, true); end);
								if okCan and can then
									local rank = PREF[row.UnitType or row.BuildingType] or 99;
									local cost = row.Cost or 9999;
									if pick == nil
									   or rank < pick.rank
									   or (rank == pick.rank and cost < pick.cost) then
										pick = { hash = row.Hash, kind = kind, rank = rank, cost = cost };
									end
								end
							end
							for row in GameInfo.Units() do consider(row, "KIND_UNIT") end
							for row in GameInfo.Buildings() do consider(row, "KIND_BUILDING") end
							if pick ~= nil then
								bestHash, bestKind = pick.hash, pick.kind;
								Log("produce [%s]: advisor empty (%d recs, %d usable), own advisor -> rank %d",
									tostring(pCity:GetName()), nRecs, nUsable, pick.rank);
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

	if g_research then
		AutomateResearch(pPlayer);
		AutomateCivics(pPlayer);
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

		if not g_tasked[id] then
			local why = IdleReason(pUnit);
			if why == nil then
				if g_builders and isBuilder then
					local r = AutomateBuilder(pUnit, pPlayer);
					g_tasked[id] = true;
					Log("builder %d -> %s", id, tostring(r));
					if r == "build" or r == "repair" or r == "move" then nB = nB + 1 end
				elseif IsSettler(pUnit) then
					AutomateSettler(pUnit, pPlayer, threats);
					g_tasked[id] = true;
				-- Recon before combat: scouts have a combat value, so without this
				-- they fell into the armies branch and just fortified ("scouts
				-- don't know what to do with themselves"). Wounded scouts retreat
				-- and heal INSTEAD of exploring -- re-exploring while hurt was
				-- how they died. Healthy but nothing to explore -> combat branch.
				elseif IsRecon(pUnit) then
					local handled = false;
					if HPPercent(pUnit) < SCOUT_RETREAT_HP then
						handled = ScoutRetreat(pUnit, pPlayer, threats);
					else
						handled = TryAutoExplore(pUnit);
					end
					if not handled and g_armies then
						AutomateCombatUnit(pUnit, eLocalPlayer, pDiplo, pVis, threats);
					end
					g_tasked[id] = true;
				elseif g_armies and IsCombatUnit(pUnit) then
					AutomateCombatUnit(pUnit, eLocalPlayer, pDiplo, pVis, threats);
					g_tasked[id] = true;
					nA = nA + 1;
				end
			elseif isBuilder then
				-- The single most useful diagnostic: "my builder just sits there"
				-- is almost always this line telling us it never looked idle.
				nSkipped = nSkipped + 1;
				if nSkipped <= 2 then Log("builder %d SKIPPED: %s", id, why) end
			elseif g_armies
			   and why ~= "dead" and why ~= "nil-unit"
			   and why ~= "no-moves-left" and why ~= "already-has-queued-destination"
			   and IsCombatUnit(pUnit) and not IsRecon(pUnit) then
				-- THE "warriors don't fight back" fix. A unit that fortified once
				-- stops reading as AWAKE, so the idle filter hid it from us
				-- forever -- it would hold pose while barbarians razed the
				-- suburbs. Fortified is not a reason to ignore a war on the
				-- doorstep: if a visible enemy is close, wake it and fight.
				local dT = NearestThreatDist(threats, pUnit:GetX(), pUnit:GetY());
				if dT ~= nil and dT <= 3 and pUnit:GetMovesRemaining() > 0 then
					Log("waking unit %d: enemy %d tiles away (was: %s)", id, dT, why);
					AutomateCombatUnit(pUnit, eLocalPlayer, pDiplo, pVis, threats);
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

local function OnLocalPlayerTurnBegin()
	g_tasked      = {};
	g_cityOrdered = {};
	RequestPass();
end

local function OnUnitDone(player)
	if player == Game.GetLocalPlayer() then RequestPass(); end
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

-- --------------------------------------------------------------- init -------

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

	-- Every handler is wrapped: if one throws, the log names it and the rest live.
	Events.LoadGameViewStateDone.Add(       Safe("LoadPrefs",        LoadPrefs));
	Events.LocalPlayerTurnBegin.Add(        Safe("TurnBegin",        OnLocalPlayerTurnBegin));
	Events.GameCoreEventPublishComplete.Add(Safe("PublishComplete",  OnPublishComplete));
	Events.UnitOperationsCleared.Add(       Safe("UnitOpsCleared",   OnUnitDone));
	Events.UnitMoveComplete.Add(            Safe("UnitMoveComplete", OnUnitDone));
	Events.UnitAddedToMap.Add(              Safe("UnitAddedToMap",   OnUnitAddedToMap));
	Events.CitySelectionChanged.Add(        Safe("CitySelChanged",   OnCitySelectionChanged));

	-- Research/civics free up mid-turn, not just at turn start; catch those the
	-- moment they land so a slot is never left idle.
	Events.ResearchCompleted.Add(           Safe("ResearchDone",     RequestPass));
	Events.CivicCompleted.Add(              Safe("CivicDone",        RequestPass));

	-- Cities go idle mid-turn too, and founding is ASYNC: the pass that ordered
	-- the settler ran before the city existed, so without these two events a
	-- brand-new city sat with an empty queue until next turn (observed live:
	-- Rome founded turn 1, no production chosen).
	Events.CityAddedToMap.Add(              Safe("CityAdded",        RequestPass));
	-- A finished build re-opens that city for orders within the same turn --
	-- clear its debounce flag or it would wait for the next turn.
	Events.CityProductionCompleted.Add(     Safe("ProductionDone",   function(playerID, cityID)
		if playerID == Game.GetLocalPlayer() then g_cityOrdered[cityID] = nil end
		RequestPass();
	end));

	RefreshUI();
end
Initialize();
