# Ball Game

A multi-iPhone game: tilt your phone to roll a ball, pass it to other phones,
and catch it when it falls through a hole. Full concept in
[GAME_IDEA.md](GAME_IDEA.md).

## Current status

- ✅ **Milestone 1** — one phone, one ball: tilt the phone and the ball rolls
  and bounces off the screen edges. Flick the phone up and the ball hops
  (and can jump over holes); landings have haptics and dust effects.
- ✅ **Milestone 2** — holes the ball can fall into.
- ✅ **High-score mode** — an endless climb, generated as you go. Score is
  how far you climb (best saved on device); dying restarts the run with a
  brand-new random course. Obstacle bands:
  - **Hurdles** — amber chevron bars spanning the whole screen; the only
    way past is a hop (flick the phone up).
  - **Bumpers** — coral rings that fling the ball back hard.
  - **Chasms with narrow bridges** — a dark drop across the screen with
    one plank; roll off the plank (while grounded) and the run ends. A
    hop clears a chasm entirely — or a friend's phone underneath
    catches the falling ball and the play continues on their screen.
  - **Walls with guarded gaps** — charcoal hazard walls that can't be
    jumped; a bumper guards the opening.
  The geometric obstacles are placeholders: drop images named
  `prop_stone`, `prop_branch`, `prop_mushroom`, `prop_hurdle`,
  `prop_fence` into the app bundle and they replace the drawn art
  automatically (like `deck.png` does for the floor).
- ✅ **Ball skins** — color + pattern picker, paint your own skin on a 3D
  ball, or put a photo from your library on it. Patterns scroll with the
  roll; a painted/photo skin shows the whole picture on the ball's face
  and spins as it rolls, so you can always tell what it is. Skins travel
  with the ball to the other phone.
- ✅ **Milestone 3** — ball rolls between two phones placed side by side
  (entry height matches the sender's physical screen height).
- ✅ **Milestone 4** — catch the falling ball with a phone underneath.
  The two phones sense their real physical arrangement over **UWB**
  (Nearby Interaction; requires two UWB iPhones — iPhone 11 or later,
  not SE/16e), exchanging discovery tokens over the Multipeer link and
  crossing the measured direction with gravity:
  - **Side by side** (or arrangement unknown) — the side walls open and
    the ball rolls across the edges; a chasm fall just ends the run,
    nothing ever drops "down" to a phone that's actually beside you.
  - **Stacked** (UWB says the peer is below, within 0.7 m) — a ball that
    falls into a chasm drops *through* the deck almost instantly,
    keeping its momentum, onto the phone below: the co-op rescue. The
    lower phone can simply rest face up (within ~30° of level); tipped
    over or face down misses and the ball returns near where it fell.
    The landing spot is mapped in physical points from the screen
    center, nudged onto safe ground on the receiving course, with a
    brief grace period so the ball can't fall straight back down.
  The HUD shows what UWB sees live (↓ below / ↑ above / ↔ beside).
  Without UWB on both phones the game plays side-by-side only.
- ✅ **Localization** — follows the device language like any international
  app: Japanese devices get Japanese, everything else falls back to
  English (App Store country doesn't matter; iOS apps read the phone's
  language setting).
- ✅ **Menu screen** — pick ひとりであそぶ (solo; no peer search) or
  ふたりであそぶ (auto-connects to a nearby iPhone) at launch; the house
  button in-game returns to the menu.

## How to run it on your iPhone

1. Open `BallGame/BallGame.xcodeproj` in Xcode (double-click it).
2. Click the **BallGame** project in the left sidebar, select the **BallGame**
   target, open the **Signing & Capabilities** tab, and pick your **Team**
   (your Apple ID — add it under Xcode ▸ Settings ▸ Accounts if it's not
   listed). If Xcode complains the bundle identifier is taken, change
   `com.example.BallGame` to something personal like `com.yourname.BallGame`.
3. Plug in your iPhone with a cable and select it in the device menu at the
   top of the Xcode window.
4. Press **Run** (▶). The first time, your iPhone will ask you to trust the
   developer: on the phone go to **Settings ▸ General ▸ VPN & Device
   Management** and trust your Apple ID, then run again.
5. Tilt the phone — the ball rolls.

> Note: the tilt sensor doesn't exist in the Simulator, so the ball only
> moves on a real iPhone.
