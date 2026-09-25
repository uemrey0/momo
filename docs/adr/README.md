# Architecture Decision Records

We record significant technical decisions as short ADRs, following
[Michael Nygard's format](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions).

An ADR is never edited after it is accepted, apart from its status. To change a decision, add a
new ADR that supersedes the old one.

| ADR | Title | Status |
| --- | ----- | ------ |
| [0001](0001-native-swift-macos.md) | Build a native Swift app for macOS only | Accepted |
| [0002](0002-swiftpm-without-xcode-project.md) | Use Swift Package Manager without a checked-in Xcode project | Accepted |
| [0003](0003-bring-your-own-subscription.md) | Use the user's own subscriptions and keys instead of a hosted service | Accepted |
| [0004](0004-procedural-character-engine.md) | Draw the character procedurally | Accepted |

To add one, copy the structure of an existing ADR, use the next number, and add it to this
table.
