# PLAN.md — Re:Zero "Return by Death" Mod for Project Zomboid

## Overview

A Project Zomboid mod that recreates the "Return by Death" (死に戻り / *Shinigami*) mechanic from *Re:Zero − Starting Life in Another World*. The player gains a negative trait that, on death, resets them to a previously established "safe point" — restoring position, inventory, and world-state snapshot — instead of permanently dying. Death leaves no corpse behind (the player has looped back in time). Each return inflicts psychological cost (depression + panic/paranoia), mirroring Subaru's mental deterioration across loops.

**Target platform:** Project Zomboid (Build 41.78+ / Build 42 compatible where noted)
**Distribution:** Steam Workshop
**Primary language:** Lua (Project Zomboid modding API), with mod metadata and packaging files
**Multiplayer:** Full multiplayer compatibility is a hard requirement — every feature must work on a dedicated/co-op server, not just in single-player (see Multiplayer Compatibility section).

---

## Core Features (from spec)

### 1. New Trait: "Return by Death"
- Registered as a **negative trait** in the character creation screen.
- Awards **+1 trait point** when selected (negative traits give points back in PZ).
- Trait ID: `ReturnByDeath`
- Category: Negative
- Should appear with a custom description referencing the Re:Zero lore.
- Implemented via `TraitFactory.addTrait()` in a Lua file loaded on game boot, plus a translation entry.

### 2. Safe Point / Checkpoint System
- On a timed interval (and/or on key events), silently record a **checkpoint snapshot** of the player: this is the "safe point" the loop returns to.
- Snapshot must capture:
  - World position (x, y, z)
  - Full inventory contents (main inventory + equipped items + worn clothing), including item conditions/uses where possible
  - Player stats worth preserving at the checkpoint (health is debatable — see Design Decisions)
  - In-game time of the checkpoint
- Store the snapshot in the player's ModData so it persists across save/load.
- Only players who have the `ReturnByDeath` trait maintain checkpoints.

### 3. Death Interception → Return by Death
- Hook the player-death event. When a `ReturnByDeath` player dies:
  1. **Prevent the permanent-death / respawn-to-menu flow.**
  2. **Bypass the death screen entirely.** The base game shows a death overlay with "Quit to Menu / Quit to Desktop" when the player dies. For a `ReturnByDeath` player this screen must **never appear** — the return should be seamless. Suppress/close the death UI (`UIManager` death screen / the game-over state) so control returns straight to the looped-back character. The player should not see or have to click through the game-over screen at all.
  3. **Suppress corpse creation** — no body left behind (they looped back, so no death occurred in the new timeline).
  4. Teleport the player back to the last checkpoint position.
  5. Restore inventory to the checkpoint snapshot (clear current inventory, re-add snapshot items).
  6. Restore in-world state relevant to the loop (see Design Decisions on how far the reset extends).
  7. Apply the psychological penalty (see #5).
  8. Play the Return by Death audio (see #4).

### 4. Return by Death Audio
- The audio file lives in the GitHub repository for this mod. It must be:
  - Copied into the mod's `media/sound/` directory.
  - Registered in a **`scripts/*.txt` sound definition** (Project Zomboid loads custom sounds via a `sound` script block, not just by file presence).
  - Triggered on every Return by Death event via `getSoundManager():PlaySound(...)` or the appropriate emitter call so the local player hears it.
- Sound ID suggestion: `ReturnByDeathTrigger`
- **Action item for Fable 5:** confirm the exact filename/format in the repo. PZ prefers `.ogg`. If the repo file is `.mp3` or `.wav`, convert to `.ogg` and document the conversion.

### 5. Psychological Penalty on Return
Each time the player returns by death, apply:
- **Depression** — increase via `getBodyDamage():setUnhappynessLevel(...)` / the misery-inducing stat path. Gain a moderate chunk per loop.
- **Panic / paranoia (tense)** — Project Zomboid doesn't have a literal "paranoia" stat; the closest analog is **Panic** and the **Stress** level. Raise both so the player becomes jumpy/tense. Stress also feeds into the "Tense" moodle.
- Penalty should be **noticeable but not instantly crippling** on a single loop, and should **stack across loops** so repeated deaths (like Subaru's spirals) genuinely wear the character down.

### 6. "Tell Them About Return by Death" — Context Menu Kill
- Add an entry to the **right-click-on-player context menu** (multiplayer): **"Tell them about Return by Death"**.
- Selecting it:
  1. **Instantly kills the targeted player.** (Lore: the Witch's tendrils crush the heart of anyone Subaru tries to tell about Return by Death.)
  2. Plays the Return by Death audio.
- Must only appear when right-clicking an actual player character (not zombies/NPCs), and the acting player should have the trait (thematically, only a Return-by-Death bearer is bound by the taboo — see Design Decisions).
- **Networking note:** the kill must be applied to the *target* player. This requires a client→server→target command round-trip using PZ's `sendClientCommand` / `OnClientCommand` (or the Build 42 equivalent). A purely client-side kill on someone else's character won't replicate. Document this clearly for Fable 5.

---

## Suggested Additional Features (improvements)

These make the mod more faithful, more fun, and more complete. Fable 5 should implement the ones marked **[recommended]** and treat the rest as optional/config-gated.

- **[recommended] Sandbox options.** Add a Sandbox settings page so server admins can tune:
  - Checkpoint interval (how often the safe point updates)
  - Depression amount per loop
  - Panic/stress amount per loop
  - Whether penalties stack or reset each loop
  - Whether the "Tell them" kill is enabled on the server
  - Whether health is restored on return (see below)
- **[recommended] "Witch's Miasma" screen effect on return.** A brief visual cue (fade to black / red vignette, or a short freeze) the instant Return by Death triggers, so the loop reset reads clearly to the player rather than a jarring teleport. Re:Zero uses the heartbeat-and-darkness motif.
- **[recommended] Manual checkpoint interaction.** Let the player right-click a spot or object to **"Set as safe point"** so they can deliberately choose where a loop returns them, instead of relying only on the interval. Optionally gate this behind a cooldown.
- **[recommended] Loop counter.** Track how many times the player has died and returned, stored in ModData. Surface it somewhere subtle (e.g., a line in the character info panel). Escalate psychological penalties with loop count for the true Subaru experience.
- **Memory of death ("Suffering doesn't disappear").** Since inventory resets, optionally keep a small persistent journal/ModData log of what killed the player each loop ("You remember dying to: a horde on West Point Bridge"). Flavor only.
- **Death-cause awareness.** Capture *how* the player died and reflect it in a UI message on return ("Return by Death. You were bitten.") to make each loop feel consequential.
- **"Witch's Scent" debuff (optional, lore-accurate).** After a return, briefly increase zombie attraction/aggro for a short window, representing the miasma clinging to Subaru post-loop. Config-gated and off by default since it can be brutal.
- **Cooldown / limit option.** Optional sandbox cap on returns (e.g., X returns per in-game day) to prevent trivializing death on servers that want stakes.
- **Audio safeguards.** Ensure the return audio doesn't overlap/stack if multiple triggers fire quickly; stop any currently-playing instance before replaying.
- **Multiplayer-safe corpse suppression.** Verify no corpse, blood decal, or death sound from the *base game* leaks through on return in MP — the whole point is that no death happened in the new timeline.
- **Trait conflict handling.** Decide interaction with other "second life"/respawn mods and with the base "Cheat Death" style effects to avoid double-triggering.

---

## Technical Architecture

### Mod folder structure (Workshop-ready)
```
ReturnByDeath/                     <- Workshop content root
├── mods/
│   └── ReturnByDeath/
│       ├── mod.info               <- mod metadata (id, name, description, poster, versionMin)
│       ├── poster.png             <- Workshop/mod preview image
│       └── media/
│           ├── lua/
│           │   ├── shared/
│           │   │   ├── ReturnByDeath_Traits.lua      <- trait registration
│           │   │   └── Translate/EN/                 <- trait name/description, UI strings
│           │   ├── client/
│           │   │   ├── ReturnByDeath_Checkpoint.lua  <- snapshot capture (interval + events)
│           │   │   ├── ReturnByDeath_OnDeath.lua     <- death interception, restore, penalties, audio
│           │   │   ├── ReturnByDeath_ContextMenu.lua <- right-click "Tell them..." entry
│           │   │   └── ReturnByDeath_FX.lua          <- optional screen effect on return
│           │   └── server/
│           │       └── ReturnByDeath_Commands.lua    <- OnClientCommand handler for the MP kill
│           ├── sound/
│           │   └── ReturnByDeath.ogg                 <- the audio from the GitHub repo (convert if needed)
│           └── scripts/
│               └── ReturnByDeath_sounds.txt          <- sound script definition registering the ogg
├── preview.png                    <- top-level Steam Workshop preview
└── workshop.txt                   <- Workshop metadata (title, description, tags, visibility)
```

### Key implementation notes for Fable 5
- **Trait registration** runs in `shared` on the `OnGameBoot` (or equivalent) event using `TraitFactory.addTrait("ReturnByDeath", ...)` with `isFree = false` so it grants points; set cost negative to yield **+1**. Verify sign convention against current API — in PZ, negative traits use a positive cost value that *adds* points; test that the character screen shows **+1**.
- **Checkpoint capture** should live client-side, ticking on `EveryOneMinute` or `OnTick` throttled, writing to `player:getModData()`. Serialize inventory as a list of `{fullType, condition/uses}` entries so it can be reconstructed.
- **Death hook:** use `OnPlayerDeath` (fires as death resolves). Because base-game death is hard to fully cancel, the robust approach is: on the tick the player would die, if they have the trait and a valid checkpoint, **restore them before the death/corpse pipeline completes** — clamp lethal health, teleport, restore inventory, then apply the psychological hit. Fable 5 should test both `OnPlayerDeath` interception and a pre-death health-guard approach and use whichever reliably prevents the corpse in single-player *and* MP.
- **Corpse suppression:** confirm no `IsoDeadBody` is spawned. If the engine spawns one before Lua regains control, remove it immediately as part of the return routine.
- **Inventory restore:** clear current inventory (main + worn + equipped), then re-add from the snapshot. Re-equip primary weapon/clothing where the snapshot recorded them.
- **Audio:** register via the `scripts/*.txt` sound block, then `getSoundManager():PlaySound("ReturnByDeathTrigger", false, 0.0)` (or emitter-based playback) on return. For the MP "Tell them" case, play the audio on the *teller's* client (and optionally the victim's, briefly, before they die).
- **MP kill command:** teller's client calls `sendClientCommand(player, "ReturnByDeath", "TellAndKill", { target = targetOnlineID })`; server's `OnClientCommand` validates and applies death to the target; server tells the target's client to play audio. Never trust the client to kill another player directly.
- **Stats:** depression via the unhappiness/misery stat, tension via `getStats():setStress()` and panic via `getStats():setPanic()` (clamp to valid ranges). Confirm exact method names against the running build.

---

## Multiplayer Compatibility (hard requirement)

Every feature must function on a dedicated server and in co-op, not only in single-player. Build and test against a running MP server, not just the SP sandbox.

- **Client/server split.** Anything that affects another player, spawns/removes world objects, or must be authoritative runs **server-side**; per-player UI, audio, and local checkpoint capture run **client-side**. Use `isClient()` / `isServer()` / `isCoopHost()` guards so code runs in the right context and doesn't double-fire on the host.
- **The "Tell them about Return by Death" kill is server-authoritative.** A client cannot kill another player's character directly and have it replicate. Flow: teller's client `sendClientCommand(player, "ReturnByDeath", "TellAndKill", { target = targetOnlineID })` → server `OnClientCommand` validates the target and applies death server-side → server instructs the target's client (and teller's client) to play the audio. Never trust a client to kill another client.
- **Return by Death is per-player and must not desync.** Each player's checkpoint snapshot lives in their own ModData. On return, the position teleport, inventory restore, corpse suppression, and death-screen bypass must all replicate correctly for the returning player while **not** affecting anyone else on the server.
- **Corpse & death-artifact suppression in MP.** Confirm that on a return no `IsoDeadBody`, blood decal, base-game death sound, or PVP/kill feed entry leaks to other clients — from their perspective the death never happened. If the server spawns a corpse before Lua regains control, remove it server-side and ensure the removal replicates.
- **Death-screen bypass is client-local.** The game-over/"Quit to Menu" overlay is a client UI event; suppress it on the returning player's client. Verify it never appears for a `ReturnByDeath` player in MP and that other clients see nothing unusual.
- **Audio replication.** Return audio plays on the correct client(s) via server instruction, not broadcast to everyone within earshot unless intended. Decide whether nearby players should hear the return sound (recommend: only the returning/telling players, kept simple).
- **ModData sync.** Use the proper transmit calls (`transmitModData()` / server ModData sync) so checkpoint and loop-counter data survive relog and stay consistent between client and server.
- **Sandbox options must be server-driven.** All tunables (checkpoint interval, penalty amounts, whether the "Tell them" kill is enabled, health-reset toggle) are read from the server's sandbox config so the whole server behaves consistently; clients don't set their own values.
- **Anti-abuse.** Because the "Tell them" option is an instant kill, gate it behind a sandbox toggle (default configurable) and validate server-side that the actor and target are valid players in range — so it can't be exploited via crafted client commands.
- **Testing checklist:** verify trait/points on the character screen, checkpoint capture, seamless return with correct inventory and no corpse, no death screen, stacking penalties, and the context-menu kill — each confirmed on a **dedicated server with at least two connected clients**.

---

## Steam Workshop Upload

1. **Assemble the folder** exactly as above; the Workshop content root contains the `mods/` folder plus `preview.png` and `workshop.txt`.
2. **`workshop.txt`** must define: `version=1`, `title`, `description`, `tags` (e.g., `Build 41`, `Misc`, `Multiplayer`), and `visibility` (`public`/`friends`/`private`).
3. **`mod.info`** must have a unique `id`, a `name`, a `description`, `poster=poster.png`, and a compatible `versionMin`/build tag.
4. **Preview images:** provide `preview.png` (Workshop card, 512×512 recommended) and the in-game `poster.png`.
5. **Upload method:** use Project Zomboid's built-in **Workshop uploader** (Main Menu → Workshop) which reads `workshop.txt`, or the SteamCMD `workshop_build_item` route with a VDF. Document whichever Fable 5 uses.
6. **After first upload:** copy the generated Workshop ID back into your records; subsequent updates re-publish to the same item.
7. **Legal/asset note for the description:** *Re:Zero* is a licensed IP and the audio clip is fan-content. Mark the mod as an unofficial fan project, credit the source, and confirm the audio's usage is acceptable for Workshop distribution before publishing.

---

## Open Questions for Fable 5 to Resolve During Build
- Exact filename, format, and length of the audio file in the GitHub repo — convert to `.ogg` if it isn't already.
- Whether **health/injuries** should reset on return (lore says yes — full clean slate to the safe point) or persist. Default: **reset to the checkpoint's health state**, sandbox-toggleable.
- How far the **world reset** extends: pure-player reset (position + inventory + stats) is the reliable, performant choice. A full world-state rewind (respawned loot, un-killed zombies, reverted map changes) is likely infeasible/expensive in PZ — recommend **player-scoped reset only** and document that limitation in the Workshop description so expectations are set.
- Build 41 vs Build 42 API differences for death events, sound, and context menus — target one, note compatibility for the other.

---

## Definition of Done
- Trait appears in character creation as negative, grants +1 point, with lore description.
- Dying with the trait returns the player to the safe point with the correct inventory, leaves **no corpse**, applies depression + panic/tension, and plays the audio — verified in **single-player and multiplayer**.
- The base-game **death screen ("Quit to Menu / Quit to Desktop") never appears** for a Return by Death player; the return is seamless with no click-through.
- Right-clicking a player shows "Tell them about Return by Death," which kills that player (**server-authoritative**) and plays the audio.
- Sandbox options page exposes the key tunables and is read from the server config in MP.
- **Full multiplayer compatibility verified on a dedicated server with 2+ clients** — every feature works and nothing desyncs or leaks to other players.
- Mod packages cleanly and uploads to Steam Workshop with valid metadata and preview images.
