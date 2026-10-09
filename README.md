# SwitchClaude

A personal Mac utility for running several Claude Desktop accounts at the same time. Each profile has its own sign-in, chat history, settings and MCP config, and gets its own coloured launcher in `~/Applications/Claude Profiles/`, so it shows up in Launchpad and Spotlight and can be kept in the Dock.

It doesn't bundle or modify Claude. It launches your installed Claude Desktop with a separate data folder (`--user-data-dir`) for each profile.

## Build and install

You need macOS 12 or later and the Xcode Command Line Tools (`xcode-select --install`).

```bash
cd SwitchClaude
sed -i '' 's/\$ARCH…/${ARCH}.../' build.sh && ./build.sh --install     # builds, copies to ~/Applications and opens it
```

Without `--install` the app is left in `build/SwitchClaude.app`.

## Using it

1. **New Profile** → give it a name and colour, then pick a type (see below).
2. Click **Launch**, or open the profile from Launchpad, Spotlight or `~/Applications/Claude Profiles/`. Sign in with whichever account that profile is for.
3. Run as many profiles as you like at once and switch between them with Cmd-Tab.

If you already use Claude Desktop, the banner offers to **import** your current sign-in and history into a named profile. Quit Claude first. The data is copied, and the original install is left as it was.

The ⋯ menu on each profile gives you Rebuild, Switch type, Show in Finder, Open Data Folder, Edit MCP Config (each profile has its own `claude_desktop_config.json`) and Delete.

## Profile types

| | Standalone (default) | Lightweight |
|---|---|---|
| Dock / Cmd-Tab icon | Its own (Claude icon + coloured badge) | The standard Claude icon |
| What runs | An APFS clone of Claude.app, ad-hoc re-signed | The official, Anthropic-signed Claude.app |
| Claude updates | Shows "Needs rebuild"; click **Rebuild All** (takes a few seconds and keeps your data) | Nothing to do |
| Feature parity | Most things. Features that rely on Anthropic's signature (some sandbox/VM features, auto-update) may not work | Everything |

Both types put a coloured launcher in Launchpad and Spotlight. If anything misbehaves in a Standalone profile, use ⋯ → **Switch to Lightweight**. Your sign-in and data stay as they are.

## Where things live

- Profile list: `~/Library/Application Support/SwitchClaude/profiles.json`
- Profile data (sign-in, chats, config): `~/Library/Application Support/SwitchClaude/Profiles/<id>/`
- Launchers: `~/Applications/Claude Profiles/<Name>.app`

## Things to know

- **Keychain prompt.** The first time a profile launches, macOS may ask whether it can use the "Claude Safe Storage" keychain item. Choose **Always Allow**.
- **The menu bar still says "Claude"** in Standalone profiles. Electron uses that name to find its helper processes, so it's left unchanged. The badge colour and initial on the icon tell the profiles apart.
- **Browser sign-in callbacks.** If you sign in through the browser and the `claude://` link opens the wrong profile, keep only the profile you're signing into running while you sign in.
- **Managed Macs.** If your device policy blocks ad-hoc signed apps, Standalone profiles won't open. Use Lightweight instead.
