# Ball Game

A multi-iPhone game: tilt your phone to roll a ball, pass it to other phones,
and catch it when it falls through a hole. Full concept in
[GAME_IDEA.md](GAME_IDEA.md).

## Current status

- ✅ **Milestone 1** — one phone, one ball: tilt the phone and the ball rolls
  and bounces off the screen edges. Flick the phone up and the ball hops
  (and can jump over holes); landings have haptics and dust effects.
- ✅ **Milestone 2** — holes the ball can fall into.
- ✅ **Adventure mode** — three hand-built desk courses: roll from start to
  the glowing goal hole past pencils, erasers, dominoes and coin bumpers,
  hopping over trap holes; falling restarts the level.
- ⬜ Milestone 3 — ball rolls between two phones placed side by side
- ✅ **Milestone 4** — catch the falling ball with a phone held underneath:
  with two phones connected, a ball that drops into a hole falls *through*
  the desk. On the other phone a shadow swells at the same spot on screen —
  hold that phone level (face up) underneath and the ball lands with a
  bounce; tilt it away and the ball whiffs past and returns to the thrower.

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
