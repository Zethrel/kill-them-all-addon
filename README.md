# KillThemAll

Randomly plays Old Gods whispers audio files, reproducing the effect of the
sha-touched weapons of Mists of Pandaria.

Original addon by Thex ([upstream repo](https://github.com/Thex-PiedDroit/KillThemAll),
[CurseForge](https://www.curseforge.com/wow/addons/killthemall)). This is a fork
that updates it for **Midnight (12.0.7)**, since upstream last shipped against
Interface 100207 (Dragonflight 10.2.7).

## Why bumping the .toc alone did not work

Setting `## Interface: 120007` gets the addon *loaded*, but it still errors out,
because three APIs it calls were removed from retail in 11.0:

| Removed API | Replacement | Used in |
| --- | --- | --- |
| `InterfaceOptions_AddCategory` | `Settings.RegisterCanvasLayoutCategory` + `Settings.RegisterAddOnCategory` | `Settings/SettingsFrame.lua` |
| `InterfaceOptionsFrame_OpenToCategory` | `Settings.OpenToCategory(categoryID)` | `Settings/SettingsFrame.lua` |
| `GetAddOnMetadata` | `C_AddOns.GetAddOnMetadata` | `Settings.lua` |

`GetAddOnMetadata` is the fatal one: it runs from `LoadSettings()` on
`ADDON_LOADED`, so it throws before any of the addon's state is initialised and
takes the whole addon down with it. `InterfaceOptions_AddCategory` then breaks
the options panel, and `InterfaceOptionsFrame_OpenToCategory` breaks the
minimap button's right-click.

All three call sites are feature-detected, so the same code still runs on
Classic flavours that retain the old globals.

## What was *not* the problem

Worth recording, because these were plausible suspects:

- **`setfenv` / `getfenv`** still exist in 12.0.7, so `Libraries/Cerberus`
  (which relies on them for its global-scope sandboxing) needed no changes.
- **`UIDropDownMenu*`** is deprecated but still shipped, so the sound-channel
  dropdown still works as-is.
- **`PlaySoundFile`**, `InCombatLockdown`, the `Minimap` global, and every
  frame template the addon uses (`UIPanelButtonTemplate`, `UICheckButtonTemplate`,
  `InputBoxTemplate`, `BackdropTemplate`, `UIDropDownMenuTemplate`) are all
  still present.
- Midnight's **secret values / restricted aura APIs** do not affect this addon —
  it reads no combat or unit state beyond the player's own dead/ghost flag.

## Also fixed

**`/kta setdelay` blew the stack.** `SetOverrideValue` commits a value and then
re-enters `SetDelay`, which comes straight back to it. Its guard only stopped
that when no override existed yet — but the second pass always has one, so any
delay differing from the saved global recursed until Lua gave out. Present in
upstream 1.6.4 and unrelated to Midnight; the test suite now covers it.

Plus a set of undefined-global reads that silently evaluated to `nil`:

- `TryParseSoundChannel` tested `soundChannel` instead of `sSoundChannel`, so the
  `Default` sound channel never resolved.
- `CreateCheckButton` referenced `button` instead of `checkButton` when given an
  `OnCheckCallback`.
- `SetDefaultGods` read a `bSilent` that was never in scope, so `/kta setgods
  default` always printed.
- `SaveDefaultVariableAsGlobal` read the override off the wrong table and then
  re-assigned an undefined `value`, wiping the setting it had just saved.
- `InitSettingsFrames` passed an undefined `buttons` as the sound-channel
  label's font size.

## Development

The addon files live at the repository root rather than in a subfolder, which
keeps every path identical to upstream — future upstream changes stay a plain
merge rather than a rename-tracking exercise.

```sh
lua5.1 Tests/run.lua      # test suite
tools/package.sh          # build dist/KillThemAll-<version>.zip
```

**Lua 5.1 specifically.** `Libraries/Cerberus` sandboxes every file with
`setfenv`/`getfenv`, which 5.2 deprecated and 5.4 removed. WoW is 5.1 anyway.

`Tests/wow_stub.lua` models *Midnight 12.0.7* rather than WoW in general: any
API Blizzard removed is simply absent, so calling one fails the suite instead of
shipping. Restoring the old `GetAddOnMetadata` call reproduces the original
crash exactly:

```
Settings.lua:283: attempt to call local 'GetMetadata' (a nil value)
        in function 'TryRecoverPreviousVersion'
```

The suite also asserts that the addon reads no global missing from 12.0.7 beyond
a short, documented list of feature-detection fallbacks — the compatibility
audit, executable.

`tools/package.sh` refuses to build if the TOC and the files on disk disagree,
since a file missing from the TOC loads in the harness but never in the game.

## Releasing

Tag a commit; CI runs the suite, builds the zip, and attaches it to a GitHub
Release.

```sh
git tag v1.7.1 && git push origin v1.7.1
```

The tag must match `## Version:` in the TOC or the workflow fails. CurseForge
upload is skipped until the `CF_API_KEY` secret and `CF_PROJECT_ID` variable are
set on the repository.

## Compatibility

- **Retail / Midnight 12.0.7** — `KillThemAll.toc`
- **Classic flavours** — `KillThemAll_Classic.toc`, `KillThemAll_ClassicEra.toc`
  are carried over from upstream with their original interface versions and have
  not been retested.

## Licence

MIT, as upstream. See [LICENSE](LICENSE).
