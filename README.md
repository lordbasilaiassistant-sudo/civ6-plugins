# Civ6 Plugins

Open collection of **Sid Meier's Civilization VI mods** focused on one thing: making the game
play itself so you can enjoy the parts you actually like. Each mod lives in its own folder and
installs by simple copy — no ModBuddy, no Steam Workshop needed (works on the Microsoft
Store / Xbox Game Pass PC build too, which Workshop doesn't support).

## Mods

### AutoBuildersArmies — "Auto Commander"
Near-total automation of the boring clicks, driven by the game's **own advisor AIs** wherever
possible, with an on-screen panel (top right) to toggle each system:

- **Research & Civics** — auto-picked from the Grand Strategic AI's recommendation (the advisor
  star) the moment a slot opens. Never leaves you idle.
- **City production** — idle cities take the city AI's top *legal* pick (validated against
  `CanProduce`, wonders and districts deliberately left to you), with a ranked fallback opener
  when the advisor has no opinion, and a defense override that builds your strongest land unit
  when enemies are near the city.
- **Settlers** — walk to the engine's recommended city site, commit to it (no wandering), flee
  to the nearest city if enemies appear, and found on arrival.
- **Builders** — repair pillaged tiles first, then build the engine-recommended improvement,
  relocating between cities as needed. Never wastes a charge.
- **Scouts** — handed to the game's native auto-explore; retreat and heal when wounded instead
  of marching back into the fight.
- **Military** — ranged units fire from safety, melee only takes favorable fights, wounded
  units heal, idle units fortify, fortified units **wake up and fight** when an enemy closes in,
  and optional *Advance* marches on the nearest known enemy (barbarians included).
- **ATTACK button** — click any enemy city banner, press ATTACK, and every combat unit
  marches on that city until it falls or you press Stand Down.
- Single-player only (hard-disables itself in multiplayer), everything logged to `Lua.log`
  with an `[ABA]` prefix so behavior is debuggable, not mysterious.

Known gaps (contributions welcome — see `HANDOFF.md` for a maintained list with API pointers):
unit promotions, pantheon picks, envoys, district placement, traders, religious units.

## Install

Copy the mod folder (e.g. `AutoBuildersArmies/`) into your Civ6 Mods directory, then enable it
in **Main Menu → Additional Content**:

| Platform | Mods folder |
|---|---|
| Steam | `Documents\My Games\Sid Meier's Civilization VI\Mods` |
| Microsoft Store / Game Pass | `Documents\My Games\Sid Meier's Civilization VI (WinApp)\Mods` |

(If your Documents folder is OneDrive-redirected, the path starts with `OneDrive\Documents\...`.)

Or run the installer from PowerShell, which detects the right folder:

```powershell
.\install.ps1
```

## Contributing

PRs welcome — new mods (one folder per mod, hand-written `.modinfo`) and improvements to
existing ones. Ground rules that keep this codebase debuggable:

1. **Verify APIs against the game's own source** (`...\Civilization VI\Base\Assets\`) before
   using them — the wikis are full of Civ5 leftovers and functions that don't exist.
2. Every event handler goes through the `Safe()` wrapper; every silent skip logs a reason.
3. Engine requests are async — debounce per unit/city per turn.
4. Test in a real game and read `Lua.log` before claiming something works.

`HANDOFF.md` tracks current state, open problems, and next planned features with verified API
references — start there.

## License

MIT — see [LICENSE](LICENSE).

---

*Built and maintained with AI assistance (Claude). Development compute is partly funded by
referrals: if you want the free GLM coding models we use for grunt work, our referral link is
[z.ai](https://z.ai/subscribe?ic=BWTG6TRYYQ) — disclosed as a referral, costs you nothing extra.*
