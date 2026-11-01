import Foundation

/// Mixtape speaks German or English, following the system language (or the per-app
/// language set in System Settings → General → Language & Region). German is the source
/// language; the English comes from this table.
let appLanguageIsGerman = Locale.preferredLanguages.first?.hasPrefix("de") ?? false

func L(_ german: String) -> String {
    appLanguageIsGerman ? german : (english[german] ?? german)
}

private let english: [String: String] = [
    // Menus
    "Neue Kassette": "New Cassette",
    "Kassetten-Designs hinzufügen …": "Add Cassette Designs…",
    "Gratis-Designs laden …": "Get Free Designs…",
    "Gratis-Designs laden": "Get Free Designs",
    "Mehr Designs ansehen …": "See More Designs…",
    "Drei Kassetten aus der 80s Collection – Worn Edition, geschenkt. Mixtape ist ein Hobbyprojekt: Wenn dir die App gefällt, freue ich mich über eine kleine Spende.": "Three cassettes from the 80s Collection – Worn Edition, free. Mixtape is a labour of love: if you like it, a small donation would make my day.",
    "Spenden & laden": "Donate & Download",
    "Nur laden": "Just Download",
    "Abbrechen": "Cancel",
    "Designs werden geladen …": "Getting the designs…",
    "Schreibschutz": "Write Protection",
    "Prägeband": "Label Tape",
    "Neues Band – das alte abschneiden": "New strip – cut off the old one",
    "Weiteres Band prägen": "Press Another Strip",
    "Als Link – ein Klick, und es spielt …": "As Link – one tap and it plays…",
    "Link wird erstellt …": "Making the link…",
    "Der Link konnte nicht erstellt werden.": "The link couldn’t be made.",
    "Link kopiert": "Link copied",
    "Er funktioniert %d Tage lang.": "It works for %d days.",
    "Er funktioniert ohne Ablaufdatum.": "It doesn’t run out.",
    "In einer Mail erscheint er als kleine Kassette, in Nachrichten als Link. Ein Tipp darauf, und das Tape spielt.": "In an email it shows as a little cassette, in messages as a link. One tap and the tape plays.",
    "Letzter Link ist abgelaufen": "Last link has run out",
    "Letzten Link kopieren – ohne Ablaufdatum": "Copy Last Link – doesn’t run out",
    "Letzten Link kopieren – noch %d Tage": "Copy Last Link – %d days left",
    "Doppelklick aufs Band: prägen, verschieben, an den Ecken drehen": "Double-click a strip: press, move, turn it by its corners",
    "Alle abziehen": "Peel All Off",
    "Weiterprägen": "Press On",
    "Gerade ausrichten": "Straighten",
    "Doppelklick auf die Kassette: neues Band an dieser Stelle": "Double-click the cassette: a new strip right there",
    "Rechtsklick aufs Band: weiterprägen, ausrichten, abziehen": "Right-click a strip: press on, straighten, peel off",
    "Abziehen": "Peel Off",
    "Band ziehen verschiebt es, an den Ecken dreht es sich": "Drag the tape to move it, drag a corner to turn it",
    "Seite %@ – Lasche herausgebrochen": "Side %@ – tab broken out",
    "„%@“ ist installiert": "“%@” is installed",
    "%d neue Kassetten findest du im Menü unter „Neue Kassette“.": "You’ll find %d new cassettes in the menu under “New Cassette”.",
    "Das ist kein gültiges Kassetten-Design.": "This isn’t a valid cassette design.",
    "Öffnen …": "Open…",
    "Beschriften": "Write Label",
    "Auf die Kassette malen": "Draw on the Cassette",
    "Malen beenden": "Stop Drawing",
    "Kassette umdrehen": "Turn Cassette Over",
    "Pause – geht auch aus jeder App mit ⌥⌘P": "Pause – also from any app with ⌥⌘P",
    "Aufnehmen von": "Record From",
    "Systemton (alles, was der Mac abspielt)": "System Audio (everything the Mac plays)",
    "Mikrofon": "Microphone",
    "Klang": "Sound",
    "Bandrauschen": "Tape Hiss",
    "Leiern": "Wow & Flutter",
    "Bandklang (weiche Höhen)": "Tape Tone (soft highs)",
    "Spulgeräusch": "Winding Noise",
    "Tastenklacken": "Key Clunks",
    "Effekt und Stärke": "Effect and Strength",
    "Wird mit der Kassette gespeichert": "Saved with the cassette",
    "Die Webseite konnte nicht erstellt werden.": "The web page couldn’t be created.",
    "An Freunde verschicken": "Send to a Friend",
    "Als Webseite – spielt in jedem Browser …": "As Web Page – plays in any browser…",
    "Als Mixtape-Datei – für Freunde mit der App …": "As Mixtape File – for friends with the app…",
    "Webseite wird erstellt …": "Making the web page…",
    "Über Mixtape": "About Mixtape",
    "WIE 1986": "Like it’s 1986",
    "Die Webseite ist %d MB groß – zu groß für die meisten E-Mails. Teile sie am besten als Link, z. B. über iCloud Drive oder WeTransfer.": "The web page is %d MB – too big for most emails. Share it as a link instead, for example with iCloud Drive or WeTransfer.",
    "Immer im Vordergrund": "Always on Top",
    "Kassette schließen": "Close Cassette",
    "Mixtape beenden": "Quit Mixtape",
    "Ablage": "File",
    "Schließen": "Close",
    "Bearbeiten": "Edit",
    "Ausschneiden": "Cut",
    "Kopieren": "Copy",
    "Einsetzen": "Paste",
    "Alles auswählen": "Select All",
    "Klar": "Clear",

    // Panel
    "Zählwerk – klicken zum Nullstellen": "Tape counter – click to reset",
    "Aufnahme (R) – mit Pause: Aufnahmebereitschaft": "Record (R) – with Pause: record standby",
    "Zurückspulen (←) – während der Wiedergabe gedrückt halten zum hörbaren Zurückspulen":
        "Rewind (←) – hold during playback to hear the tape run backwards",
    "Wiedergabe (Leertaste)": "Play (Space)",
    "Vorspulen (→) – während der Wiedergabe gedrückt halten zum hörbaren Vorspulen":
        "Fast forward (→) – hold during playback to hear the tape whizz past",
    "Auswerfen und umdrehen": "Eject and turn over",
    "Stopp": "Stop",
    "Pause (P) – aus jeder App: ⌥⌘P": "Pause (P) – from any app: ⌥⌘P",
    "Aussteuerung": "Level meters",
    "Mehr": "More",
    "Systemton aufnehmen – alles, was der Mac gerade abspielt": "Record system audio – everything the Mac is playing",
    "Mikrofon aufnehmen": "Record the microphone",
    "Aufnahmepegel – Doppelklick setzt ihn zurück. Im roten Bereich wird das Band übersteuert: Es verzerrt, wird aber kaum lauter.":
        "Recording level – double-click to reset. In the red the tape is overdriven: it distorts but hardly gets louder.",
    "Letzten Strich zurücknehmen": "Undo last stroke",
    "Lautstärke – Doppelklick setzt sie zurück. Während einer Aufnahme wird der Regler zum Aufnahmepegel.":
        "Volume – double-click to reset. While recording, this fader becomes the recording level.",
    "Alles auf dieser Seite wegradieren": "Erase everything on this side",
    "Fertig": "Done",
    "Doppelklick zum Beschriften": "Double-click to write a label",

    // Messages
    "Systemeinstellungen öffnen": "Open System Settings",
    "Mixtape neu starten": "Restart Mixtape",
    "Die Aufnahme konnte nicht starten.": "The recording couldn’t start.",
    "Die Kassette konnte nicht gespeichert werden.": "The cassette couldn’t be saved.",
    "Die Aufnahme bekommt keinen Ton": "The recording isn’t getting any sound",
    "Vom Systemton kommt gerade nichts an. Das passiert zum Beispiel kurz nach dem Wechsel von Kopfhörern. Versuch es gleich nochmal. Klappt es weiter nicht, starte Mixtape neu. Hilft auch das nicht, prüfe unter „Datenschutz & Sicherheit → Bildschirm- & Systemaudioaufnahme“, ob Mixtape eingeschaltet ist.":
        "No system audio is coming through right now. This can happen just after switching headphones. Try again in a moment. If it still doesn’t work, restart Mixtape. If that doesn’t help either, check under “Privacy & Security → Screen & System Audio Recording” that Mixtape is switched on.",
    "Vom Mikrofon kommt nichts an. Prüfe in den Systemeinstellungen unter „Datenschutz & Sicherheit → Mikrofon“, ob Mixtape es benutzen darf.":
        "Nothing is coming from the microphone. Check in System Settings under “Privacy & Security → Microphone” whether Mixtape may use it.",
    "Mixtape darf das Mikrofon nicht benutzen. Du kannst es in den Systemeinstellungen unter „Datenschutz & Sicherheit → Mikrofon“ erlauben.":
        "Mixtape isn’t allowed to use the microphone. You can allow it in System Settings under “Privacy & Security → Microphone”.",
    "Vom Systemton kommt nichts an. Prüfe unter „Datenschutz & Sicherheit → Bildschirm- & Systemaudioaufnahme“, ob Mixtape aufnehmen darf.":
        "No system audio is arriving. Check under “Privacy & Security → Screen & System Audio Recording” whether Mixtape may record.",
    "Kein Mikrofon gefunden.": "No microphone found.",
    "„%@“ ist keine lesbare Mixtape-Kassette.": "“%@” isn’t a readable Mixtape cassette.",
    "%@ ist fehlgeschlagen.": "%@ failed.",
    "Systemton-Aufnahme fehlgeschlagen (%@, Fehler %d).": "System audio recording failed (%@, error %d).",
]
