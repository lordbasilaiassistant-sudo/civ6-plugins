# Civ6 Unit Taxonomy (grep-verified, Units.xml + 01_GameplaySchema.sql)

Branch on **PromotionClass** first; combat columns confirm. Schema: Combat:2838,
RangedCombat:2839, Range:2840, Bombard:2841, CanTargetAir:2881 (NO CanTargetSea exists).

## Category tests
| Category | Test |
|---|---|
| melee land | PromotionClass=MELEE (Combat>0 only) |
| ranged land | PromotionClass=RANGED (RangedCombat>0, Range>=1) |
| anti-cav / lt-cav / hv-cav | PROMOTION_CLASS_ANTI_CAVALRY / LIGHT_CAVALRY / HEAVY_CAVALRY |
| siege | PROMOTION_CLASS_SIEGE == Bombard>0 & Domain=LAND (anti-city column) |
| naval melee / ranged | NAVAL_MELEE / (NAVAL_RANGED or NAVAL_RAIDER) |
| recon | PROMOTION_CLASS_RECON |
| support | FormationClass=FORMATION_CLASS_SUPPORT (all Combat=0: ram, siege tower, engineer(BuildCharges=2!), medic, balloon, AA guns) |
| civilian | FormationClass=FORMATION_CLASS_CIVILIAN |
| religious actor | ReligiousStrength>0 (missionary/apostle/inquisitor/guru; NO religious formation class exists) |
| trader / settler / builder | MakeTradeRoute=true / FoundCity=true / BuildCharges>0 AND FormationClass=CIVILIAN |
| air | Domain=DOMAIN_AIR (AIR_FIGHTER RangedCombat, AIR_BOMBER Bombard) |

## Can hit SEA targets from land
Purely mechanical: `Domain=LAND AND (RangedCombat>0 OR Bombard>0) AND Range>=1`.
Melee land can NEVER hit boats. (Archer 25/2, Catapult bombard 35/2.)

## Early land units (era proxy = PrereqTech)
Scout 10 recon | Warrior 20 melee | Slinger 5/15/1 ranged | Archer 15/25/2 (ARCHERY)
Spearman 25 anti-cav (BRONZE) | Heavy Chariot 28 hv-cav (WHEEL) | Swordsman 35 melee (IRON+iron)
Horseman 36 lt-cav (HORSEBACK+horses) | Catapult 25/–/2/B35 siege (ENGINEERING)

Strategic gating: `StrategicResource` column (iron/horses/niter). Upgrade timing:
`MandatoryObsoleteTech` (Warrior→GUNPOWDER). Full citations in issue tracker / agent report.
