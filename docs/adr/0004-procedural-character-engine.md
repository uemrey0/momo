# 4. Draw the character procedurally

Date: 2026-09-26

## Status

Accepted

## Context

Momo's value depends on feeling alive: breathing, blinking irregularly, glancing around,
reacting to the cursor and to events, and blending smoothly between emotions. Options:

- **Sprite or video frames:** easy to author, but transitions between states look canned and
  every new state multiplies the asset count.
- **Rive state machines:** great tooling, but behaviour lives in binary design files that are
  hard to review and diff in pull requests.
- **Procedural drawing in code:** every visual property is a number that eases towards a target
  through a spring; behaviours are layered on top.

## Decision

Implement the character as a procedural engine (`MomoFace`) that renders with SwiftUI `Canvas`.
The engine combines five layers each frame: life (breathing, blinking, saccades), mood, action,
reaction and particles. Randomness is injectable for deterministic tests.

Looks and mood parameters will be data-driven through character packs so contributors can add
characters without writing Swift.

## Consequences

- Smooth, interruptible transitions between any two states.
- Behaviour is plain Swift and fully testable and reviewable.
- Designers need to express looks as parameters; very custom art may need Rive support later,
  which can be added as an alternative renderer.
