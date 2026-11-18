# Neovim-Kompatibilitätskorrektur

Stand: 18. November 2026. Basis: GitHub-main `2694fd6`.

## Ursache und Korrektur

Die vorherige Version brach beim Laden des Plugins mit einer Assertion ab,
sobald Neovim älter als 0.12 war. Dieser Mindeststand war zu hoch: Die
verwendeten Funktionen zum Verstecken ganzer Zeilen und zur Beschränkung auf
bestimmte Fenster sind bereits seit 0.11 vorhanden. Der ursprüngliche
Startfehler wurde mit dem ausgelieferten Paket unter Neovim 0.11.5 reproduziert.

Der neue Stand prüft die tatsächlich benötigten Fähigkeiten:

- Neovim 0.11 und neuer: Kommentaransichten einschließlich Ausblenden.
- Neovim 0.10: Kommentaransichten, Bearbeitung, Speichern, Ansichtswechsel und
  Fensterpaare; die Kommentare bleiben zusätzlich im Source sichtbar.
- Älter als 0.10: kein Abbruch der gesamten Konfiguration. Das Plugin bleibt
  deaktiviert; beim Aufruf von `:Documented` wird die benötigte Version genannt.
  Für diese ältere Versionsgruppe wurde keine vollständige Laufzeitprüfung vorgenommen.

`:checkhealth docpair` zeigt Version, Programmpfad und verfügbare Funktionen.
Die unmittelbaren Befehle dafür sind `:version` und `:echo v:progpath`.

## Laufzeitprüfungen

Die Tests starten echte offizielle Neovim-Binärdateien. Der neue Starttest lädt
`plugin/docpair.lua` vor einem expliziten `setup`, wie beim beobachteten
Lazy-Start. Er prüft danach die Konfigurationsübernahme, das Öffnen eines Paares,
Bearbeiten und Speichern eines Kommentars, Ansichtswechsel, Tab-Duplizierung
und die Gesundheitsprüfung.

| Neovim | Kommentarprüfungen | Bestehende Fenster-/Notiztests | Starttest |
| --- | --- | --- | --- |
| 0.10.4 | 52 bestanden; 2 nicht verfügbare Ausblendtests übersprungen | 54 bestanden | bestanden |
| 0.11.5 | 54 bestanden; 0 nicht verfügbare Ausblendtests übersprungen | 54 bestanden | bestanden |
| 0.12.6 | 54 bestanden; 0 nicht verfügbare Ausblendtests übersprungen | 54 bestanden | bestanden |

Zusätzlich bestehen 16 Prüfschritte im echten Terminal auf Neovim 0.11.5,
einschließlich `g<Tab>`, Schreiben, großen Dateien und Tabwechseln.

Der Test für einen abgebrochenen `:qall` unterdrückt lediglich den nativen
Hit-Enter-Prompt älterer Neovim-Versionen mit `silent`; die Fehlermeldung und
der Schutz ungespeicherter Notizen bleiben Gegenstand der Prüfung.

## Übernahme

Die Dateien aus dem enthaltenen `docpair.nvim/` in den bestehenden Git-Klon
übernehmen, dessen `.git` behalten, Änderungen committen und pushen. Danach
die installierte Plugin-Kopie aktualisieren und Neovim neu starten.
Das Paket ist vollständig; keine Patch-Datei ist erforderlich.

Die genaue lokal laufende Version des Nutzers lässt sich aus dem übermittelten
Stacktrace nicht ablesen. Der Trace belegt nur, dass die Prüfung auf 0.12
fehlgeschlagen ist.
