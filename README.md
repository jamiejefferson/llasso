# Llasso

Draw a box round anything on your Mac, say or type what you want, and get an answer beside the box.

Hold ⌘ and drag a box round anything on screen. A prompt opens when you let go: type and press Return, or hold the mic and talk. The answer arrives on a card beside the box; click Thanks! to close it. A ⌘-click that doesn't move still goes to the app as normal. Where ⌘-drag doesn't suit, press ⌃⌥S or choose Draw a box from the menu bar.

Actions: Llasso guesses what the box holds (editable text, web page, image, spreadsheet, design canvas, app interface) and the model acts through tools. Every change waits for a tap on the card: put text back in place, paste, copy, open a new document, Save to… (a save panel that opens in the project behind the box, or the last folder used), write spreadsheet cells, run an AppleScript. Apps with their own MCP server (Paper, Hatch, Figma's desktop server, and any local server in Claude Code's config) connect automatically. Their read-only tools run straight away, and so do Hatch's navigation and Paper's undoable edits; other changes wait for approval.

Code edits: when the box shows a page served from this Mac (a Hatch project, or any dev server on localhost) or a file open in an editor, Llasso finds the project folder and the model can hand the change to Claude Code, run headless in that folder with file tools only. The card shows the files and the diff with Keep and Undo. Undo restores the snapshot Llasso took just before the edit; in a git repo it uses a private index, so the user's staged work, branches and commits are left alone.

The microphone is on only while you hold the mic on the prompt; releasing sends. Opening the prompt never touches the mic, so other audio keeps playing.

Several requests can run at once. A sent request shrinks to a Working chip at the screen edge, and its card comes up when it finishes. The menu bar icon counts jobs that are running or waiting on you, and clicking it lists every task and brings its card back.

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
    open ~/Applications/Llasso.app --args --codetest       # a scratch repo served on localhost: resolve, edit_code,
                                                           # Claude Code edit, diff, Undo; writes codetest.json
    open ~/Applications/Llasso.app --args --jobtest        # two jobs at once, a click away mid-job; writes jobtest.json
    open ~/Applications/Llasso.app --args --pastetest      # replaces a selection in a Chrome page by paste, then undoes it; writes pastetest.json
    open ~/Applications/Llasso.app --args --looktest       # the marquee, prompt and card on light and dark; writes look-*.png
    open ~/Applications/Llasso.app --args --drawtest       # draws a box by ⌘-drag, ⌃⌥S and the menu, and checks a
                                                           # ⌘-click reaches the app; writes drawtest.json
    open ~/Applications/Llasso.app --args --savetest       # opens Save to… over the overlay and checks it sits on top
                                                           # and starts in the project; writes savetest.json
