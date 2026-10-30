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
    "Wird mit der Kassette gespeichert": "Saved with the cassette",
    "Per E-Mail verschicken …": "Send by Email…",
    "Im Finder zeigen": "Show in Finder",
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
    "Abbrechen": "Cancel",
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
    "Ich hab dir ein Mixtape aufgenommen": "I made you a mixtape",
    "Ich hab dir „%@“ aufgenommen": "I made you a mixtape: “%@”",
]
