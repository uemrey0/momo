# Character packs

Momo can wear different looks. Seven ship with the app (Classic, Snow, Kitty, Robo, Peach,
Scholar and Sprout), and you can add your own with a small JSON file. No code needed.

## Add a character

1. Open **Settings → Character → Open Characters Folder**
   (`~/Library/Application Support/Momo/Characters`).
2. Save a `.json` file there, for example `lava.json`.
3. Click **Reload** and pick your character.

```json
{
  "id": "lava",
  "name": { "en": "Lava", "tr": "Lav" },
  "bodyColor": "#3A0F0A",
  "eyeColor": "#FFB36B",
  "blushColor": "#FF5A3C",
  "eyeShape": "round",
  "accessory": "freckles",
  "accessoryColor": "#FFD29B"
}
```

## Fields

| Field            | Required | Description                                                                 |
| ---------------- | -------- | --------------------------------------------------------------------------- |
| `id`             | yes      | A unique identifier. Built-in IDs can't be replaced.                        |
| `name`           | yes      | Names by language code. `en` is used when the user's language is missing.  |
| `bodyColor`      | yes      | `#RRGGBB`. Light colours automatically get a darker outline.                |
| `eyeColor`       | no       | A fixed eye (and mouth) colour. Leave it out to use the brain's colour.     |
| `blushColor`     | yes      | Cheek colour.                                                               |
| `eyeShape`       | yes      | `pill`, `round` or `square`.                                                |
| `accessory`      | yes      | `none`, `whiskers`, `glasses`, `bow`, `freckles` or `sprout`.               |
| `accessoryColor` | no       | Colour of the accessory.                                                    |

Even with a fixed `eyeColor`, the eyes still tint towards the active brain's colour (lavender
for your subscription, amber for an API key) so you can always tell who is answering.

## Share it

Open a pull request that adds your character to `CharacterAppearance.builtIns` in
`Sources/MomoFace/CharacterAppearance.swift`, with a screenshot, or share the JSON file in
GitHub Discussions.

New accessories need a few lines in `FaceRenderer.drawAccessory`. Keep them on the visible
part of the body: its top edge hides behind the notch.
