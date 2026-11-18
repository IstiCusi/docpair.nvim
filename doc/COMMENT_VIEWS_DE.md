# Docpair: Kommentaransichten

## Installation des Updates

Die Dateien aus `docpair.nvim/` in deinen aktuellen, sauberen Git-Klon kopieren.
Das vorhandene `.git` behalten. Das Quellpaket enthält kein `.git`, sodass es
keine zweite Historie in deinen Klon einbringt. Änderungen prüfen, committen
und anschließend wie gewohnt pushen. Danach das Plugin in Lazy aktualisieren
und Neovim neu starten. Voraussetzung: Neovim 0.12 oder neuer, getestet 0.12.6.

## Lazy-Konfiguration

```lua
return {
  "IstiCusi/docpair.nvim",
  lazy = false,
  opts = {
    initial_view = "text",
    views = { "text", "markdown", "raw", "notes" },
    mappings = {
      cycle = "g<Tab>",
      create = "<leader>dd",
      source = "<leader>ds",
    },
    comments = { hide = true, debounce_ms = 80 },
  },
}
```

Im Normalmodus des Dokumentationsfensters zuerst `g`, dann Tab drücken.
`cycle` kann jede andere normale Tastensequenz oder `false` sein. Auch
Reihenfolge und Startansicht lassen sich ändern. `initial_view = "notes"`
öffnet zuerst die bisherigen externen Notizen.

## Bedienung

- `:Documented!`: Paar im aktuellen Tab öffnen. Ohne `!`: neuer Tab.
- Codecursor in einen dokumentierten Abschnitt bewegen: rechts erscheint die Erklärung.
- Mit Ctrl-W L ins Dokumentationsfenster wechseln: unabhängig lesen und schreiben.
- `g<Tab>`: Text → Markdown → Originalkommentar → externe Notizen → Text.
- `<leader>dd` im Code: vorhandene Dokumentation öffnen oder einen Kommentar anlegen.
- `<leader>ds`: vollständigen Source mit Kommentaren ein-/ausblenden.
- `:write` aus einer Kommentaransicht: vollständige Quelldatei speichern.
- `:wall`: auch geänderte externe Notizen speichern.
- `u` / Ctrl-R in der Kommentaransicht: Undo/Redo im Quellbuffer.

Die Kommentarzeichen werden beim Schreiben ergänzt. Beim Wechsel der Ansicht
wird kein Quelltext geändert. Ein normales C-, Zig- oder anderes Sourcefile mit
seinen Kommentaren bleibt die gespeicherte Datei. Nur die Ansicht `notes`
verwendet weiterhin eine zusätzliche Datei im bisherigen `.documented`-Ordner.

## Schutz bei Konflikten

Ein ungültiger Blockabschluss, ein inzwischen geänderter Quellkommentar oder
eine gelöschte Zuordnung wird nicht still überschrieben. Die Eingabe bleibt als
geänderter Entwurf erhalten; der Fenstertitel nennt den Grund. Text korrigieren
oder mit `:DocumentedDiscard` ausdrücklich verwerfen. Mit
`:DocumentedDrafts` lässt sich ein Entwurf nach einem Dateiwechsel wieder öffnen.

## Grenzen dieser Version

Es werden alleinstehende Kommentarblöcke verarbeitet. Kommentare hinter Code,
Python-Docstrings und erkannte Direktiven bleiben im Source sichtbar. Mit einem
passenden Tree-sitter-Parser ist die Zuordnung abschnittsbezogen; ohne Parser
wird der nächstvorangehende Kommentar bis zum nächsten Kommentar verwendet.
Das steht im Fenstertitel. Für C und Lua sind Parser in der Testumgebung
vorhanden; die anderen Sprachadapter wurden anhand von Kommentar-Testdateien
geprüft. Das ist keine pauschale Prüfung aller Dialekte und Parser.

Markdown bietet Hervorhebung und Concealment. Ein zusätzlicher Markdown-Renderer
ist optional über `on_markdown` integrierbar; ein vollständiger Renderer ist
nicht Bestandteil des Plugins.

Ausgeblendete Kommentare bleiben echte Sourcezeilen. Bereiche, Ersetzungen und
Ausschneiden arbeiten deshalb weiterhin auf dem vollständigen Text. Vor dem
Verschieben einer Funktion samt Dokumentation den vollständigen Source anzeigen.
