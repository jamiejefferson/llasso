# Llasso

Draw a box round anything on your Mac, say or type what you want, and get an answer beside the box.

P0 build: menu-bar app, ⌃⌥S overlay, region capture, on-device voice input, streamed answer card through OpenRouter, spoken answers.

Actions: Llasso guesses what the box holds (editable text, web page, image, spreadsheet, design canvas, app interface) and the model acts through tools. Every change waits for a tap on the card: put text back in place, paste, copy, open a new document, save, write spreadsheet cells, run an AppleScript. Apps with their own MCP server (Paper, Hatch, Figma's desktop server, and any local server in Claude Code's config) connect automatically; their read-only tools run straight away and their changes wait for approval.

## Build and run

    ./build.sh            # builds ~/Applications/Llasso.app
    open ~/Applications/Llasso.app

First run: paste an OpenRouter key in Settings, then allow Screen Recording, Microphone and Accessibility.

## Checks

    swift run LlassoCheck                                  # logic checks
    OPENROUTER_API_KEY=sk-or-... swift run LlassoCheck     # plus a live call
    open ~/Applications/Llasso.app --args --selftest       # capture + context + one call, no UI;
                                                           # writes ~/Library/Application Support/Llasso/selftest.json
    open ~/Applications/Llasso.app --args --mcptest        # connects each app's MCP server; writes mcptest.json
    open ~/Applications/Llasso.app --args --acttest        # TextEdit fix-in-place and an Excel formula, closed unsaved;
                                                           # writes acttest.json
