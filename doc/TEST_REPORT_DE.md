# Kommentaransichten: Implementierung und Prüfung

Stand: 17. November 2026. Ausgangspunkt ist der veröffentlichte GitHub-Commit
`7b29b89` (Fenster-Fix). Der neue Stand liegt auf `feature/comment-views`.

## Ergebnis

- 54 bestehende Integrationstests für Fenster, Tabs und externe Notizen bestanden.
- 54 neue Integrationstests für Kommentaransichten bestanden.
- 14 Schritte im bisherigen Terminalablauf bestanden.
- 16 Schritte im neuen Terminalablauf mit `g<Tab>` bestanden.
- Keine fehlgeschlagenen Tests oder Testfehler in diesen vier Läufen.
- Echte Neovim-Prozesse mit Version 0.12.6; keine nachgebildeten Fenster-APIs.

Der neue Terminalablauf verwendet Dateityperkennung und Syntaxhervorhebung.
Der Test wartet vor Zustandsabfragen auf die nachgelagerte Fensterverwaltung.
Die Kommentaransicht wurde auch über Neovims Bildschirminhalt geprüft:
Die erste sichtbare Zeile ist tatsächlich Code; ausgeblendete Kommentare
hinterlassen keine Leerflächen. Ein sichtbares D kennzeichnet Dokumentation.

## Enthalten

Text, Markdown, Originalkommentar und externe Notizen sind umschaltbar.
`g<Tab>` ist im Dokumentationsfenster vorbelegt. Taste, Reihenfolge,
Startansicht und die Tasten für Anlegen/Einblenden sind per Lazy-`opts` steuerbar.

Der Sourcebuffer enthält immer die vollständige Datei. Kommentaransichten
sind bearbeitbare Speicherbuffer; `:write` dort schreibt die normale Quelldatei.
Ein Ansichtswechsel fügt keinen Quelltext-Undo-Schritt hinzu. Freies Scrollen,
getrennte Positionen in Tabs, gemeinsame Inhalte, native Sessions und
Wiederherstellung der aktuellen Leseposition sind geprüft.

Sprachfixtures prüfen C, C++, Zig, Rust, Python, Lua, JavaScript, TypeScript,
Java, Go, C#, Pascal, HTML, CSS, SQL, Shell und Ruby. Prüffälle enthalten
Strings, Multiline-Strings, Heredocs, Raw-Strings und Direktiven. Das ist keine
vollständige Prüfung jedes Dialekts. C-/Lua-Parser sind in der Testumgebung
vorhanden; andere Sprachen verwenden dort die lexikalische Rückfallebene.

## Schutzfälle

Geprüft sind unter anderem gleichzeitige Ansichten, veraltete Projektionen,
ungültige Blockabschlüsse, Originalansichten mit eingeschobenem Code,
C/C++-Zeilenfortsetzungen, schreibgeschützte Quellen, direkte Sourceänderungen,
Undo/Redo, kontinuierliches Tippen, Unicode, CRLF, Einrückung, Speichern direkt
nach einer Eingabe und das Wiederöffnen zurückgehaltener Entwürfe.

Ein unbearbeitetes Sourcefile wird durch Öffnen, Umschalten und Speichern nicht
umformatiert. Ein C-Beispiel bleibt nach Bearbeitung seiner Dokumentation vom
verfügbaren C-Compiler mit `-fsyntax-only` akzeptiert. Versteckte, vollständig
übernommene Kommentaransichten werden freigegeben, damit wiederholte Dateiwechsel
nicht fortlaufend zusätzliche Dokumentkopien im Speicher hinterlassen.

## Belastungslauf

| Fall | Messwert des letzten Laufs |
| --- | --- |
| 250.003 Sourcezeilen, davon 50.000 Dokumentationszeilen | 28,127,818 Bytes insgesamt |
| Öffnen und erste Erkennung dieser Datei | 3.33 s |
| Zweimaliger Ansichtswechsel bei diesem Dokument | 0.35 s |
| Bearbeiten des ersten Absatzes einschließlich Abgleich | 0.41 s |
| 80.000 Sourcezeilen mit 20.000 kleinen Kommentarblöcken, öffnen und ans Ende springen | 0.66 s |

Die Zeiten enthalten die Wartezeit der Testzustandsabfrage und sind Messwerte
dieser Umgebung, keine Hardware-unabhängigen Zusagen. Auch die bisherigen
Belastungstests mit 200.000 Codezeilen und großen externen Notizen bestehen.

Validierte Änderungen im Kommentar-Textmodus aktualisieren die bekannten
Bereiche ohne vollständige Neuinterpretation des Sources. Direkte Änderungen
am Source oder an der Original-Kommentarsyntax können eine Neuindexierung
veranlassen. Bei sehr großen Dateien kann diese sichtbar Zeit beanspruchen.

## Bewusste Grenzen

Nur alleinstehende Kommentarblöcke werden projiziert. Nachgestellte Kommentare,
Python-Docstrings und erkannte Direktiven bleiben im Source. Markdown bietet
Hervorhebung/Concealment; ein vollständiger Renderer ist optional integrierbar.

Tree-sitter liefert Abschnittsgrenzen, wenn ein geeigneter Parser vorhanden ist.
Ohne Parser gilt der nächstvorangehende Kommentar bis zum nächsten Kommentar;
die Ansicht kennzeichnet das ausdrücklich. Unvollständige Syntax, Sprachdialekte
und eingebettete Sprachen können diese Zuordnung begrenzen.

Ausgeblendete Kommentare bleiben physische Sourcezeilen. Bereichsbefehle,
Ersetzungen und Verschieben arbeiten auf dem vollständigen Text. Für das
Verschieben einer Funktion samt Kommentar sollte der Source eingeblendet werden.

Die Sessiondatei speichert Zuordnungen und Positionen, keine Textsicherung.
Nicht übernommene Entwürfe blockieren die Session-Wiederherstellung.
Erzwungenes Beenden kann ungespeicherte Eingaben verwerfen. Eine pauschale
Kompatibilität mit jedem Drittplugin ist nicht behauptet.

## Dateien für die Nachprüfung

- `tests/results/regression-0.12.6.json`
- `tests/results/comments-0.12.6.json`
- `tests/results/terminal-0.12.6.json`
- `tests/results/comments-terminal-0.12.6.json`
- `tests/run.py`, `tests/comments.py`, `tests/tui.py`, `tests/comments_tui.py`
- `doc/COMMENT_VIEWS_DE.md`, `examples/lazy.lua`, `examples/tutorial.c`
