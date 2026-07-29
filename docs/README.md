# blog.sh — documentation

The [main README](../README.md) is the tour: what the engine is, what
it can do, and why it's built the way it is. This directory holds the
guides that go deeper:

| Guide | Answers |
| --- | --- |
| [install.md](install.md) | How do I get from zero to a deployed site -- locally, on a VPS, on Cloudron, on Pages? |
| [operations.md](operations.md) | How do I run it day to day -- writing, deploying, cron, backup, troubleshooting? |

## Where to start, by situation

| Situation | Read |
| --- | --- |
| Evaluating the engine | main README → the screenshots → *Why this exists* |
| Setting up a site | [install.md](install.md), top to bottom |
| Writing and publishing posts | [operations.md → Writing and publishing](operations.md#writing-and-publishing) |
| Something failed | [operations.md → Troubleshooting](operations.md#troubleshooting) |
| Understanding the internals | the main README's *Feature overview*, plus the source -- every `lib/` file opens with a design comment |

Architecture and design-decision notes may grow into their own pages
later; until then the main README's *Why this exists* section and the
header comments across `lib/` and `build/` are the authoritative
explanation of the internals.

The `screenshot-*.png` files here are the images embedded in the main
README.
