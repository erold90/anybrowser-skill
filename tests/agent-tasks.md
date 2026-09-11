# Agent tasks

The tests in this folder check that macuse works. These check that an agent can
*use* it: give a fresh agent only `SKILL.md` and one of these tasks, and ask for
a report on every step, every command, and every place the docs or a report
misled it. Each round of fixes to macuse so far came from these reports.

Measure: steps completed, number of tool calls, and the list of frictions.
Adapt names to your system language.

## 1. A document (TextEdit)

1. Create a new TextEdit document (don't touch documents already open).
2. Type: `Hello from macuse — città, perché, €5`
3. Select all and make it bold with the menus (not a shortcut).
4. Verify the document holds exactly that text, and that it's bold.
5. Close only that document, without saving.

History: 5/5 in 10 calls (first round).

## 2. A web form (Safari, local page)

Serve `tests/page.html` (`python3 -m http.server -d tests 8799`), then:

1. Open `http://127.0.0.1:8799/page.html` in Safari.
2. Fill Name and Email, choose "Team" in Plan.
3. Click "Show alert" and dismiss the alert.
4. Upload a file through the page's "Upload file" control.
5. Click Send and confirm the status line from the page itself.
6. Close the tab you opened.

History: 8/8 in 5 calls.

## 3. Files (Finder)

In a scratch folder holding `bozza.txt`, `note.txt`, `foto.png.txt`:

1. Open the folder in a Finder window.
2. Create a folder `Archivio` through Finder's UI.
3. Rename `bozza.txt` to `definitiva.txt` through Finder's UI.
4. Drag `definitiva.txt` into `Archivio` with the mouse.
5. Verify in Finder, then with `ls -R`.
6. Close the window.

History: 6/6 in 13 calls.
