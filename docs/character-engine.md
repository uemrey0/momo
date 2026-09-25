# Character engine

`MomoFace` turns a handful of numbers into a character that feels alive. This guide explains
the model so you can add moods, behaviours and reactions.

## Coordinate space

All drawing uses a design space measured in points. The origin is the **anchor**: the top centre
of the body, where Momo hangs from the notch. `x` grows to the right and `y` grows downwards. The
body is 140 × 78 points; eyes sit 36 points below the anchor, the mouth at 58.

## Channels and springs

Every animatable property is a `FaceChannel`, for example `gazeX`, `eyeScale`, `lid`,
`smile`, `squash` or `rotation`. Each channel owns a `Spring`. Every frame the engine computes a
target for each channel and the spring moves the value towards it:

```
acceleration = stiffness × (target − value) − damping × velocity
```

Low damping (like `rotation`) gives a pendulum that swings after a poke; high damping (like
`gazeX`) gives quick, settled eye movements.

## Layers

Targets are computed in five layers. Later layers override earlier ones.

1. **Life.** Breathing modulates `squash`; blinks are scheduled every 1.8–6 seconds, with a 20 %
   chance of a double blink; saccades nudge the gaze when nothing holds Momo's attention.
2. **Mood.** A `Mood` sets base targets (`happy` raises `smile` and `cheek` and turns the
   eyes into arcs). Some moods also animate procedurally, such as the speaking mouth or the
   sleepy head nod.
3. **Action.** A `FaceAction` is a short, one-shot behaviour with its own timeline (`yawn`,
   `peek`, `hum`...). When life is enabled, the engine plays a random idle action every
   4–8 seconds while Momo is idle.
4. **Reaction.** Cursor proximity makes Momo curious; pokes add velocity to the springs; five
   pokes within two seconds make it dizzy; long system idle time sends it to sleep. A
   `FaceEvent` maps something that happened on the Mac to a sequence of moods and actions.
5. **Particles.** `z`, notes, hearts, sparkles, sweat drops, `!` and `?` are simple particles
   with velocity, gravity and a lifetime.

## Adding a mood

1. Add a case to `Mood`.
2. Give it channel targets in `Mood.targets`.
3. Optionally add procedural motion or particles in `FaceEngine.applyMoodMotion`.
4. Add a localized display name in `MomoApp` and a test.

## Adding an idle behaviour

1. Add a case to `FaceAction` with a duration.
2. Implement its timeline in `FaceAction.apply(at:to:)`.
3. Add it to `FaceAction.idlePool` if it should play on its own.

## Reduced motion

When the system's Reduce Motion setting is on, idle actions and particles are disabled and
Momo only blinks and changes expression.
