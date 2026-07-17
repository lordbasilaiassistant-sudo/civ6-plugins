# Civ6 AutoBuildersArmies — Session Handoff (2026-07-17)

Goal: **fully autonomous Civ6 gameplay** — Anthony watches, optionally does diplomacy/trades;
everything else runs itself. One mod, verified live over ~8 restarts tonight.

## Where everything lives
- **The mod (only artifact that matters):**
  `C:\Users\drlor\OneDrive\Documents\My Games\Sid Meier's Civilization VI (WinApp)\Mods\AutoBuildersArmies\`
  (`AutoBuildersArmies.modinfo`, `UI/AutoBuildersArmies.xml` panel, `UI/AutoBuildersArmies.lua` ~1500 lines — all logic)
- **Game install (read-only reference, grep it before writing ANY API call):**
  `C:\XboxGames\Civilization VI PC\Content\Base\Assets\` — Xbox/Game Pass build: no ModBuddy, no FireTuner, no Workshop.
- **Logs:** `%LOCALAPPDATA%\Firaxis Games\Sid Meier's Civilization VI\Logs\Lua.log` — every mod decision prints as `[ABA] ...`.
- **Validator (run after EVERY edit, catches 5 bug classes):**
  `py "<scratchpad>\validate_aba.py"` — session-scratchpad copy; if gone, recreate: luaparser syntax + XML parse
  + Controls-vs-XML cross-check + modinfo file existence + file-level use-before-declaration check.
- **Live-watch pattern:** `tail -n 0 -F Lua.log | grep --line-buffered "\[ABA\]|Runtime Error.*AutoBuildersArmies"`
  via Monitor tool. `-n 0` matters (old log replays otherwise).

## VERIFIED WORKING (seen in live logs, not assumed)
- Panel renders (needs `ContextPtr:SetHide(false)` — engine loads all mod UI hidden, InGame.lua:347).
- Auto research + civics via `GetGrandStrategicAI()` recommendations, re-picks instantly on completion.
- Auto production: advisor recs filtered through `CanProduce(hash,true)` legality + wonder-exclusion + district-exclusion;
  fallback "own advisor" (ranked opener: scout→slinger→warrior→monument→builder→granary, cap 2/unit-type) when advisor empty;
  city debounce (one order/city/turn); defense override (enemy ≤4 tiles → strongest land unit).
- Auto settle: commit-to-site (no oscillation), flee threats ≤3 tiles → nearest own city, threat-checked site choice.
- Builders: repair→build-recommended→relocate loop.
- Scouts: native `UNITOPERATION_AUTOMATE_EXPLORE`; retreat+heal when HP<70.
- Fortified units WAKE when visible enemy ≤3 tiles (fortified units stop reading ACTIVITY_AWAKE — biggest bug of the night).
- ATTACK button: click enemy city banner → all armies march (city-plot melee assault included). NOT yet war-tested live.
- Errors: every handler wrapped in `Safe(name, fn)` → `[ABA] HANDLER FAILED [name]: <traceback>`; never chase raw line numbers (they shift with edits while the game holds old code).

## THE OPEN PROBLEM — "things get stuck often"
Turn won't end / needs manual clicks. Diagnosed causes, in likely frequency order:
1. **Unit promotions pending** — blocks end turn; we never promote. Fix: auto-pick first/best promotion.
   API: grep `PromotionPopup.lua` / UnitPanel for `UnitCommandTypes.PROMOTE` + `PARAM_PROMOTION_TYPE`.
2. **Pantheon choice** — blocks once per game. API already verified: `PantheonChooser.lua:132` →
   `UI.RequestPlayerOperation(pid, PlayerOperations.FOUND_PANTHEON, {PARAM_BELIEF_TYPE=hash})`.
3. **Envoy tokens** — blocks. API verified: `CityStates.lua:759` → `PlayerOperations.GIVE_INFLUENCE_TOKEN`.
   Strategy: dump into the city-state we already lead.
4. **Unhandled unit classes idle-block**: support (FORMATION_CLASS_SUPPORT — rams/towers), religious (missionaries),
   great people awaiting activation, traders. Minimum fix: catch-all → any AWAKE unit no branch claims gets
   SLEEP (not SKIP — skip re-blocks next turn) + loud log so we know what class to automate next.
5. **Diplomacy first-contact/deal modals** — inherently manual (Anthony said he'd do diplomacy anyway). Leave.
6. Tech/civic-boost & era popups — dismissable noise, low priority.

## Next features after unstuck (in order)
- District auto-placement: `CityManager.GetOperationTargets(pCity, CityOperationTypes.BUILD, {PARAM_DISTRICT_TYPE=hash})`
  returns valid PLOTS (AdjacencyBonusSupport.lua:290). Pick best-adjacency plot, then BUILD with plot param.
  This is the single biggest empire-strength lever (currently districts are never built → hard economic cap).
- Wonder opt-in toggle; trader auto-routes; naval/air handling (air currently excluded from combat).
- Between-games stat telemetry (science/culture per turn by era via `Game:SetProperty`) — measure rule changes, no NN
  (no network/file IO in Civ6 Lua; LLM-in-mod is impossible — settled, don't revisit).

## Hard-won rules for the next agent (violating these wasted hours tonight)
1. **Grep the install before writing any API call.** Plausible-sounding APIs that didn't exist tonight:
   `SetResearchingTech`, `Alert_Warmonger`, `GameEvents.OnCombat`, `AlwaysMet`, `REQUIREMENTSET_TEST_NONE`.
2. **Run the validator after every edit.** It caught an XML `--`-in-comment (kills whole panel) and two
   use-before-declaration nil-global crashes.
3. **Never edit the Lua while the game runs and then reason from logged line numbers** — the game holds the old file.
4. **All engine requests are ASYNC** — debounce everything (g_tasked units, g_cityOrdered cities), and clear
   debounce on the matching completion event.
5. **Every silent skip must log a reason** — "idle but nothing ordered (N recs, M usable)" style lines found
   3 root causes tonight in minutes each.
6. Lua file-level locals resolve by declaration order; a later-declared local silently compiles as nil global.
7. Restart the game to load Lua changes (no hot reload from Mods dir).
