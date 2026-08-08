## What this changes

<!-- A sentence or two. Link an issue with "Fixes #123" if there is one. -->

## Why

<!-- What problem does it solve? If it works around a Windows quirk, please say so in a
     code comment too, so the next person does not remove it. -->

## How it was tested

Please tick what you actually ran. There are no automated tests, because nearly everything
here touches real processes, windows and profile directories.

- [ ] The window opens and lists profiles with the correct running state
- [ ] Created a profile, launched it, and deleted it
- [ ] `-List`, `-Shortcut` and `-Install` still behave
- [ ] A profile launched **from a desktop shortcut** opens a visible Claude window
- [ ] Ran `Invoke-ScriptAnalyzer -Path .\ClaudeSwitcher.ps1`

Environment:

- Windows version:
- Claude desktop build: Store (MSIX) / installer

## Anything reviewers should look at closely

<!-- Optional. -->
