# blog.sh — documentation

The [main README](../README.md) is the tour: what the engine is, what
it can do, and why it's built the way it is. This directory holds the
guides that go deeper:

| Guide | Answers |
| --- | --- |
| [install.md](install.md) | How do I get from zero to a deployed site -- locally, on a VPS, on Cloudron, on Pages? |
| [operations.md](operations.md) | How do I run it day to day -- writing, deploying, cron, backup, troubleshooting? |
| [architecture.md](architecture.md) | How does it work inside -- content model, build pipeline, deploy, client side, security? |
| [decisions.md](decisions.md) | Why is it built this way -- the trade-offs, each with its admitted cost? |
| [importing.md](importing.md) | How do I bring an old blog in -- per-source guides, what gets kept, how to undo? |
| [skinning.md](skinning.md) | How do I make it look like something else -- without forking the engine? |
| [localization.md](localization.md) | How do I translate the engine into my language? |

## Where to start, by situation

| Situation | Read |
| --- | --- |
| Evaluating the engine | main README → the screenshots → *Why this exists* → *What it does* |
| Setting up a site | [install.md](install.md), top to bottom |
| Writing and publishing posts | [operations.md → Writing and publishing](operations.md#writing-and-publishing) |
| Dressing the site differently | [skinning.md](skinning.md) -- try `./style.sh` first; a skin is the expensive answer |
| Moving content in from elsewhere | [importing.md](importing.md), then `./import.sh` |
| Taking content out, or moving the whole site | [operations.md → Taking your content elsewhere](operations.md#taking-your-content-elsewhere), then `./blog.sh export` |
| Checking that the archive itself is sound | [operations.md → Checking the archive](operations.md#checking-the-archive), then `./blog.sh check` |
| Something failed | [operations.md → Troubleshooting](operations.md#troubleshooting) |
| Understanding the internals | [architecture.md](architecture.md), then the source -- every `lib/` file opens with a design comment |
| Translating the engine | [localization.md](localization.md) -- a partial locale is useful from day one |
| Writing an importer | [architecture.md → Importing](architecture.md#importing) for the adapter contract, [→ Field reference](architecture.md#field-reference) for the schema to produce |
| Questioning a design choice | [decisions.md](decisions.md) first -- it may already argue both sides |

The `screenshot-*.png` files here are the images embedded in the main
README.
