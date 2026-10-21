# Llasso

Draw a box round anything on your Mac, say or type what you want, and get an answer beside the box.

P0 build: menu-bar app, ⌃⌥S overlay, region capture, on-device voice input, streamed answer card through OpenRouter, spoken answers.

## Build and run

    ./build.sh            # builds ~/Applications/Llasso.app
    open ~/Applications/Llasso.app

First run: paste an OpenRouter key in Settings, then allow Screen Recording, Microphone and Accessibility.

## Checks

    swift run LlassoCheck                                  # logic checks
    OPENROUTER_API_KEY=sk-or-... swift run LlassoCheck     # plus a live call
    open ~/Applications/Llasso.app --args --selftest       # capture + context + one call, no UI;
                                                           # writes ~/Library/Application Support/Llasso/selftest.json
