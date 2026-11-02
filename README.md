# Llasso

## Install

    curl -fsSL https://raw.githubusercontent.com/jamiejefferson/llasso/main/install.sh | sh

Needs a Mac with Apple silicon and macOS 26 or later. Run the same command to update. First run: paste an OpenRouter key in Settings, then allow Screen Recording, Microphone and Accessibility.

Draw a box round anything on your Mac, say or type what you want, and get an answer beside the box.

Hold ⌘ and drag a box round anything on screen. A prompt opens when you let go: type and press Return, or hold the mic and talk. The answer arrives on a card beside the box; click Thanks! to close it. A ⌘-click that doesn't move still goes to the app as normal. Where ⌘-drag doesn't suit, press ⌃⌥S or choose Draw a box from the menu bar. To drag with other keys, such as ⌥⇧, choose them in Settings › Use.

Actions: Llasso guesses what the box holds (editable text, web page, image, spreadsheet, design canvas, app interface) and the model acts through tools. Every change waits for a tap on the card: put text back in place, paste, copy, open a new document, Save to… (a save panel that opens in the project behind the box, or the last folder used), write spreadsheet cells, run an AppleScript. Text always checks whether it can go back where it came from: a selection, a field, or, with nothing selected, the lines of editable text the box covers (Notes, TextEdit, Mail and other native editors). When it can, the card asks "Replace the boxed text in Notes with this?" and replaces only after the tap; when it can't, the card says so. If Llasso's own window was in front, the box belongs to the app whose window is under it. Apps with their own MCP server (Paper, Hatch, Figma's desktop server, and any local server in Claude Code's config) connect automatically. Their read-only tools run straight away, and so do Hatch's navigation and Paper's undoable edits; other changes wait for approval. In Paper the box decides what changes, so nothing needs selecting: Llasso finds the boxed text or frame through Paper's tools and changes it in the file. Before the request is done, it searches the rest of the file for the same old wording or style and asks, for example "I've changed the one in the box. 2 other artboards still say Overviw: Pricing and About. Change those too?" With Check the screen with Jev on (Settings › Models, on by default), Llasso looks at the screen before and after each change it makes (Replace, Paste, Write cells, Run, Add as a layer, and Paper and Photoshop steps) and the card says whether the change shows. A ring Llasso shows moves onto the control when a close-up says the model missed it, and the model can ask Jev quick questions about the screen instead of taking screenshots. Those screenshots go to Jev through OpenRouter.

Code edits: when the box shows a page served from this Mac (a Hatch project, or any dev server on localhost) or a file open in an editor, Llasso finds the project folder and the model can hand the change to Claude Code, run headless in that folder with file tools only. The card shows the files and the diff with Keep and Undo. Undo restores the snapshot Llasso took just before the edit; in a git repo it uses a private index, so the user's staged work, branches and commits are left alone.

Models: Llasso reads each request as one of seven kinds of work (writing, coding, design, image, motion, sound, admin) and picks a model for it from OpenRouter's live lists, weighing benchmarks OpenRouter publishes and Llasso's ratings of each model family against price and speed. Settings › Models sets the balance (best results, balanced or lowest cost) and lets you choose your own model for any kind of work in a picker with search, filters and prices; a model you choose is always used. The card names the model a request runs on and why it was picked. Jev, a fast decision model on OpenRouter, reads the typed request when it can answer within 1.5 s; otherwise keyword rules and the kind of box decide. Pictures, video clips, music and speech are all made through OpenRouter and wait on the card to be saved or copied.

Categories: Settings › Models lists the seven built-in kinds of work and any you add, such as Illustration or Voice. Each category runs as one of the seven, which sets the models it can use and how they are rated, and a Sound category can be set to speech only or music only. A category has its own description and trigger words. A request that uses one of the words goes straight to it; otherwise Jev reads every category's description and picks one. Each category has its own model, chosen or left on Auto, and the card names the category. A speech-only category of your own also voices spoken answers. The pencil beside a category edits it. Built-ins can be renamed, described and reset; your own can be deleted.

Updates: Llasso checks GitHub for a newer release a few seconds after launch and once a day. When there is one, a line at the top of the request list and the menu-bar menu says so, with one sentence on what changed. Nothing pops up. Update downloads the same zip the install command uses, checks it is signed with the same certificate as the running copy, waits for running requests to finish, then swaps the app in place and reopens it, so macOS keeps its permissions. If any step fails, the old copy keeps running and the line offers the install command instead. Settings › Updates turns checking off. Releases need `LLASSO_NOTE="one plain sentence" ./release.sh`; that sentence is the line people see.

Plans: when one result can't answer a request (a caption and an illustration, or a clip with its own spoken line), the model proposes a plan of up to five steps. The card lists each step with the model that will make it, and the cost of any clip, and nothing is made until you tap Make these. Each step runs on the model for its kind of work. A step can take in earlier results: text goes into its instruction, a picture goes in as an image or a clip's first frame, and a combine step joins a picture or clip with a sound into one clip on the Mac. Every result no later step uses shows on the card with its own buttons. If a step fails, everything already made still shows. Requests that one result answers never get a plan.

The microphone is on only while you hold the mic on the prompt; releasing sends. Opening the prompt never touches the mic, so other audio keeps playing.

Several requests can run at once. A sent request shrinks to a Working chip at the screen edge, and its card comes up when it finishes. The menu bar icon counts jobs that are running or waiting on you, and clicking it lists every task and brings its card back.

Feedback: Send feedback… in the menu bar sends a note (feedback, bug or idea, with an optional email and screenshot) to the `llasso_feedback` table in Supabase, defined in `supabase/llasso_feedback.sql`. The app's key can add rows and nothing else. A copy stays in `feedback.md` in the history folder.

## Release

Raise `CFBundleShortVersionString` in `Resources/Info.plist`, commit, then run `./release.sh`. It builds the app, zips it and publishes a GitHub release, which the install command picks up.

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
    open ~/Applications/Llasso.app --args --feedbacktest   # pictures the form as feedback-form.png; add --send to post a test note
    open ~/Applications/Llasso.app --args --drawtest       # draws a box by ⌘-drag, ⌃⌥S and the menu, checks a
                                                           # ⌘-click reaches the app, then switches the keys to ⌥⇧
                                                           # and checks ⌘-drags reach the app; writes drawtest.json
    open ~/Applications/Llasso.app --args --papertest      # a scratch Paper file with one typo on three artboards: changes the
                                                           # boxed one, asks about the other two, answers yes; writes papertest.json
    open ~/Applications/Llasso.app --args --checktest      # in a TextEdit note, a Replace must be seen on screen and a script that
                                                           # does nothing flagged; two quick looks; rings that miss on purpose
                                                           # must move onto the control and rings that hit must stay; writes checktest.json
    open ~/Applications/Llasso.app --args --jevlooktest    # times Jev 1.14 reading the look-test screenshots (yes/no, pick-one,
                                                           # before and after, finding a control) against the chat models
                                                           # ringing the same controls; writes jevlooktest.json
    open ~/Applications/Llasso.app --args --savetest       # opens Save to… over the overlay and checks it sits on top
                                                           # and starts in the project; writes savetest.json

## Licence

MIT. See LICENSE.
