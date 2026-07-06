# Ball Game — Multi-iPhone Tilt Game

## The Idea

A physical, multi-device iPhone game where a ball travels between real phones.

### Core mechanics

1. **Tilt to roll** — Each iPhone shows a ball on its screen. Players lean/tilt
   their phone and the ball rolls in that direction, driven by the phone's
   motion sensors.

2. **Ball moves between phones** — When phones are placed next to each other,
   the ball can roll off the edge of one screen and continue onto the
   neighboring phone's screen, as if the screens form one continuous surface.

3. **Holes** — Sometimes a hole appears on the playing surface. If the ball
   rolls over it, the ball falls in and disappears from that screen.

4. **Catch it underneath** — When the ball falls through a hole, another
   player can catch it — but only if their phone is physically held
   *underneath* the phone the ball fell from. The ball behaves as if it drops
   through real 3D space and lands on the screen below.

## Technical sketch (iOS)

| Mechanic | Likely technology |
|---|---|
| Tilt-based ball physics | Core Motion (accelerometer + gyroscope) + SpriteKit physics |
| Phone-to-phone ball handoff | Multipeer Connectivity (local Wi-Fi / Bluetooth, no server needed) |
| Detecting a phone is *underneath* another | Nearby Interaction (UWB / U1 chip) for relative position, possibly combined with device attitude from Core Motion |
| Rendering | SpriteKit (2D ball, holes, surface) |

### Open design questions

- How do phones learn their relative edge-to-edge layout? (Manual pairing
  gesture, e.g. swipe from one screen to the other? UWB ranging?)
- Vertical catch: how strict is the "underneath" check, and how long does the
  ball "fall" before it's missed?
- Game modes: co-op (keep the ball alive, pass it around) vs. competitive
  (drop the ball into holes so opponents must scramble to catch it)?
- Minimum devices: playable with 2, better with 3+?
