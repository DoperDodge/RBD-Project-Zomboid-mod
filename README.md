# Return by Death (Re:Zero) — Project Zomboid Mod

Death is not the end — it is a checkpoint.

This mod recreates the **Return by Death** (死に戻り) mechanic from *Re:Zero − Starting Life in Another World* for Project Zomboid **Build 41.78+**, fully multiplayer compatible and packaged ready for the Steam Workshop.

Built from the design in [PLAN.md](PLAN.md).

## Features

- **"Return by Death" negative trait** (+1 point) in character creation, with lore description.
- **Safe point system** — your loop silently anchors your position and full loadout (inventory, equipped hands, worn clothing, nested bag contents, item condition/uses, loaded ammo) on a configurable interval. Auto-anchors are skipped while zombies are nearby or you're badly hurt, so the loop never anchors inside a death trap. You can also right-click anywhere to **Set Safe Point** manually (cooldown-gated).
- **Return by Death** — at the brink of death you seamlessly loop back to your safe point: teleport, inventory restored, body restored (sandbox-toggleable), **no corpse, no death screen, no click-through**. The Witch's Miasma screen effect (black slam + red heartbeat) marks the reset and the Return by Death audio plays.
- **Psychological cost** — every loop adds depression, stress and panic. Penalties escalate per loop (configurable), grinding the survivor down the way the loops grind Subaru.
- **Memory of death** — the mod remembers what killed you ("You remember dying: torn apart by the infected"), keeps a journal of your last 20 loops in ModData, and shows your loop count on every return. Right-click → *Reflect on your loops* for flavor.
- **The taboo: "Tell them about Return by Death..."** — right-click another player. The Witch's unseen hand crushes their heart: instant, absolute death (their own Return by Death cannot save them). **Server-authoritative**: the teller's client only *requests* the kill; the server validates the feature toggle, the teller's trait, the target and the range before instructing the target's client. Crafted client commands are dropped.
- **Witch's Scent** (optional, off by default) — a fresh return briefly attracts the dead to the miasma clinging to you.
- **Sandbox page** with every tunable: checkpoint interval, safe-anchor rule, manual cooldown, health restore, guard threshold, depression/stress/panic per loop, escalation %, max returns per day, audio, death-cause message, taboo kill toggle + range, witch scent + radius.

## How death interception works (please read before reporting bugs)

Base-game death is effectively impossible to cancel cleanly once the engine's corpse/death-screen pipeline starts, so the mod uses a layered approach (as planned in PLAN.md):

1. **Primary — pre-death guard.** Health is watched on every player update *and* on every damage event. When overall health falls to the **Return trigger threshold** (sandbox, default 15%), the return fires **before** the engine kills you. No death ⇒ no corpse, no death screen, nothing for other clients to see. This is the path taken in virtually all deaths (combat, bleeding, infection, fire, falls).
2. **Fallback — post-mortem revive.** If an instant kill ever outruns the guard, `OnPlayerDeath` attempts a revive; if the engine accepts, the return runs, any corpse at the death spot is swept, and any death UI is suppressed for a few seconds. If the engine refuses, the vanilla death proceeds untouched — you get a normal death rather than a broken half-dead state.

Consequences to be aware of:
- The loop triggers *at the brink* of death (the threshold), which is the lore anyway — Subaru returns as he dies.
- The **world is not rewound**: loot, killed zombies and map changes persist. The reset is player-scoped (position/inventory/body). A true world rewind is not feasible in PZ.
- The Knox infection is always cleared on return (even with health restore off) — otherwise the infection would chain-trigger returns forever.

## Repository layout

```
ReturnByDeath/                     ← Steam Workshop content root
├── preview.png                    ← Workshop card image (512×512)
├── workshop.txt                   ← Workshop metadata (title, description, tags)
└── mods/
    └── ReturnByDeath/
        ├── mod.info               ← mod id/name/description/poster
        ├── poster.png             ← in-game mod poster (256×256)
        └── media/
            ├── sandbox-options.txt
            ├── lua/
            │   ├── shared/        ← trait, core helpers, translations
            │   ├── client/        ← checkpoint, death guard/return, context menu, FX, net client
            │   └── server/        ← server-authoritative command handlers
            ├── scripts/
            │   └── ReturnByDeath_sounds.txt   ← registers the sound below
            └── sound/
                └── ReturnByDeath.ogg          ← converted from the repo's mp3
```

The source audio (`Return by death audio.mp3`, 12 s) was converted to Ogg Vorbis with:
`ffmpeg -i "Return by death audio.mp3" -c:a libvorbis -q:a 6 -ar 44100 ReturnByDeath.ogg`

## Installing locally for testing

Copy `ReturnByDeath/mods/ReturnByDeath` into your `Zomboid/mods` folder:

- Windows: `C:\Users\<you>\Zomboid\mods\ReturnByDeath`
- Linux: `~/Zomboid/mods/ReturnByDeath`

Enable **Return by Death (Re:Zero)** in Mods from the main menu, then start a new game (or add it to an existing save; sandbox options will use their defaults).

For a dedicated server add `ReturnByDeath` to `Mods=` and the Workshop ID to `WorkshopItems=` in your server ini once published.

## Testing checklist (from PLAN.md — run before publishing)

On single-player **and** on a dedicated server with 2+ clients:

- [ ] Trait shows in character creation as negative with +1 point and the lore description.
- [ ] A fresh character auto-anchors a safe point within ~10 seconds of spawning.
- [ ] Automatic re-anchoring happens on the sandbox interval, and is deferred while zombies are within 15 tiles.
- [ ] Manual **Set Safe Point** works and respects its cooldown (tooltip shows remaining minutes).
- [ ] Dying (let a horde chew on you) returns you to the safe point with the exact loadout — worn clothing worn, weapons in hand, bag contents intact — **no corpse, no death screen**, audio + screen effect play, loop counter shows.
- [ ] Depression/stress/panic visibly rise each loop and escalate on repeated loops.
- [ ] With `Max returns per day` set, exceeding it produces a warning and then a **final** vanilla death.
- [ ] MP: another client watching a returning player sees a teleport but **no corpse/kill feed/death artifacts**.
- [ ] MP: right-click another player → *Tell them about Return by Death...* kills **them** (server log line appears), audio plays for both, and their own trait does **not** save them.
- [ ] MP: the taboo kill is refused beyond the sandbox range and when disabled in sandbox settings.
- [ ] Relogging preserves the safe point, loop counter and journal (ModData persists with the character).

## Publishing to the Steam Workshop

1. Copy the **contents** of this repo's `ReturnByDeath/` folder to `C:\Users\<you>\Zomboid\Workshop\ReturnByDeath\` (so that `workshop.txt` and `mods/` sit directly inside it).
2. Launch Project Zomboid → main menu → **Workshop** → **Create/Update items**.
3. Select **ReturnByDeath** — the uploader reads `workshop.txt` (title, description, tags `Build 41; Multiplayer; Pop Culture; Traits`, visibility `public`) and `preview.png`.
4. Upload. After the first upload Steam assigns a Workshop ID; the uploader writes `id=<number>` back into `workshop.txt`. **Commit that line** so future updates re-publish to the same item.
5. Subsequent updates: same menu, same item — do not delete the `id=` line.

### Legal note

This is an unofficial fan project. *Re:Zero − Starting Life in Another World* is the property of Tappei Nagatsuki, KADOKAWA and the respective rights holders. The bundled audio is fan content; confirm you are comfortable distributing it on the Workshop before publishing (the Workshop description already carries this disclaimer).

## Build 42

This mod targets **Build 41.78**. For Build 42 the Workshop layout changes (`mods/ReturnByDeath/42/media/...` + `common/`), and several APIs (death events, sound scripts, context menus) have B42 variants — porting is a follow-up task; the Lua is written defensively (pcall-guarded API calls) to ease it.
