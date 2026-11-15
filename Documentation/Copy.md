# Poly copy guide

Every word Poly shows: menu items, subtitles, alerts, notifications and the Bluetooth permission
text. Check new or changed copy against this guide, and update the string list when copy changes.
Poly speaks rarely, so each string should be short, concrete and say what happens to the person's
own things.

## Words

| Say | Meaning | Do not say |
|---|---|---|
| **external display** | The screen a Mac is connected to. Its name when there is one ("Home Office"); "external display" only where no name fits. | monitor, screen (the code's `Monitor` type is internal) |
| **accessory, accessories** | An Apple keyboard, mouse or trackpad. Use the accessory's name whenever there is one ("Magic Mouse"); "accessories" only for a count or a group. | device, peripheral |
| **link / unlink** | Poly's own idea: an accessory belongs to an external display, so it follows whichever Mac is connected to that display. Link is always "to" a display; unlink is "from" it. | pair (that is Bluetooth's word for what Poly does underneath), learn, remember, assign |
| **connect, connected** | A Mac and an external display (by cable), or an accessory and a Mac (over Bluetooth). Statuses: "Connected", "Connecting…", "Not Connected", "Couldn’t connect". | plug in, plugged into, attach, claim |
| **your Mac** | The Mac Poly runs on. | this Mac, the computer |
| **rename** | Changing a display's or accessory's name. | |

Internal words stay in code, logs and the spec: claim, release, forget (unpair), nudge, learn,
monitor.

## Style

- **Names first.** Name the accessory and the display rather than describing them: "Link Magic
  Mouse to Home Office?", not "Link this accessory to your display?". Several accessories are
  listed by name ("Magic Keyboard and Magic Mouse").
- **Capitalization.** Menu items, buttons and menu subtitles that are statuses use title case
  ("Unlink All Accessories", "Not Connected"). Alert titles, notification titles, instructions and
  explanations use sentence case ("Couldn’t connect to Magic Mouse").
- **Punctuation.** Curly apostrophes and quotes (’ “ ”). An ellipsis (…) on items that ask for
  more before acting ("Rename…") and on ongoing states ("Connecting…"). The serial comma in lists
  ("keyboard, mouse, and trackpad"). Questions end in "?"; one-line menu text has no period;
  alert and notification bodies are full sentences with periods.
- **Buttons are verbs** that repeat the question's verb: "Link" / "Don’t Link", "Rename" / "Cancel".
- **Say what Poly will do, not how.** "Your Mac will connect to Magic Mouse automatically…", never
  Bluetooth mechanics (pairing, bonds, unpairing).
- **Calm about failures.** Say what happened and what Poly does next; suggest one action at most
  ("Click it, or switch it off and on").

## Every string

| Where | Copy |
|---|---|
| Menu, nothing linked yet | Connect your Mac to an external display and accessories to get started. (one wide line; SwiftUI drops line breaks in menu items, to revisit) |
| Menu, Bluetooth denied | Allow Poly to Use Bluetooth… |
| Menu, Bluetooth off | Bluetooth Is Off |
| Display row subtitle | Connected • 2 accessories / Connecting… • 2 accessories / Couldn’t Connect • 2 accessories / Not Connected / Connected (nothing linked yet) |
| Accessory row subtitle | Connected / Connecting… / Not Connected / Press a key, or switch it off and on (keyboard) / Click it, or switch it off and on (mouse, trackpad) |
| Display submenu | Link Magic Mouse to Home Office · Rename… · Unlink All Accessories |
| Accessory submenu | Rename… · Unlink from Home Office |
| Menu | Open at Login · Quit Poly |
| Rename alert | Rename “Home Office” · Rename / Cancel |
| Link alert, one accessory | Link Magic Mouse to Home Office? · Your Mac will connect to Magic Mouse automatically when it’s connected to Home Office. · Link / Don’t Link |
| Link alert, several | Link Magic Keyboard and Magic Mouse to Home Office? · Your Mac will connect to them automatically when it’s connected to Home Office. · a checkbox per accessory · Link / Don’t Link |
| Notification | Couldn’t connect to Magic Mouse · Poly will keep trying in the background. |
| Bluetooth permission | Poly connects your keyboard, mouse, and trackpad when your Mac is connected to the external display they’re linked to, and frees them for other Macs when it’s disconnected. |
| Display with no name | Display |
| Menu bar icon (accessibility) | Poly |
