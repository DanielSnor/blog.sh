---
title: Markdown-Spickzettel
---
Diese Seite wird in Markdown geschrieben — in dem Editor, den `./blog.sh add` öffnet. Es ist kein vollständiges Markdown, sondern eine auf diese Engine zugeschnittene Teilmenge. Diese Seite zeigt alles, was unterstützt wird: je Gruppe zuerst der Quelltext, wie du ihn tippst, und direkt darunter, wie er herauskommt.

Ein Link auf diese Seite steht auch in der Editor-Hilfe, sie ist beim Schreiben also immer zur Hand.

- [Absätze](#absatze)
- [Überschriften](#uberschriften)
- [Hervorhebungen](#hervorhebungen)
- [Links](#links)
- [Listen](#listen)
- [Zitate](#zitate)
- [Trennlinie](#trennlinie)
- [Codeblöcke](#codeblocke)
- [Tabellen](#tabellen)
- [Bilder](#bilder)
- [Video](#video)
- [Escaping](#escaping)
- [Noch nicht unterstützt](#noch-nicht-unterstutzt)

## Absätze

Absätze trennt eine Leerzeile. Ein Zeilenumbruch innerhalb eines Absatzes wird beim Rendern zu einem Leerzeichen — für einen neuen Absatz also eine Leerzeile dazwischen lassen.

```
Erster Absatz.

Zweiter Absatz.
```

Erster Absatz.

Zweiter Absatz.

## Überschriften

Rauten am Zeilenanfang, eine bis sechs je nach Ebene. Eine Überschrift braucht ihre eigene Zeile.

```
# Überschrift erster Ebene
## Überschrift zweiter Ebene
### Überschrift dritter Ebene
#### Überschrift vierter Ebene
##### Überschrift fünfter Ebene
###### Überschrift sechster Ebene
```

Die ersten beiden Ebenen nutzt dieser Artikel selbst für seine Abschnitte, hier deshalb eine Probe ab Ebene drei:

### Überschrift dritter Ebene

#### Überschrift vierter Ebene

##### Überschrift fünfter Ebene

## Hervorhebungen

```
**fett**, *kursiv*, ~~durchgestrichen~~ und `Code mitten im Satz`
```

**fett**, *kursiv*, ~~durchgestrichen~~ und `Code mitten im Satz`

Hervorhebungen lassen sich kombinieren und verschachteln:

```
**fetter Text mit *Kursivem* darin**
```

**fetter Text mit *Kursivem* darin**

## Links

Text in eckigen Klammern, Adresse in runden. Nach der Adresse kann ein Titel in Anführungszeichen stehen — er erscheint beim Überfahren als Tooltip.

```
[Beispiel](https://example.com)
[Beispiel mit Titel](https://example.com "Tooltip beim Überfahren")
```

[Beispiel](https://example.com) und [Beispiel mit Titel](https://example.com "Tooltip beim Überfahren")

Eine direkt im Satz geschriebene Adresse wird von selbst zum Link, ganz ohne Markup:

```
Darüber schreibe ich regelmäßig auf https://example.com.
```

Darüber schreibe ich regelmäßig auf https://example.com.

## Listen

Aufzählungen beginnen mit Bindestrich oder Sternchen, eine nummerierte Liste mit Zahl und Punkt. Keine Leerzeile zwischen den Einträgen — die würde die Liste beenden.

```
- erster Punkt
- zweiter Punkt
- dritter Punkt
```

- erster Punkt
- zweiter Punkt
- dritter Punkt

```
1. erster Eintrag
2. zweiter Eintrag
3. dritter Eintrag
```

1. erster Eintrag
2. zweiter Eintrag
3. dritter Eintrag

Die Zahlen sind egal, beim Rendern wird neu durchnummeriert. Eine verschachtelte Liste wird um zwei Leerzeichen eingerückt:

```
- Obst
  - Apfel
  - Birne
- Gemüse
  1. Karotte
  2. Petersilie
```

- Obst
  - Apfel
  - Birne
- Gemüse
  1. Karotte
  2. Petersilie

## Zitate

Jede Zeile eines Zitats beginnt mit `>`.

```
> Fang am Anfang an, sagte der König ernst,
> und lies, bis du ans Ende kommst: dann hör auf.
```

> Fang am Anfang an, sagte der König ernst,
> und lies, bis du ans Ende kommst: dann hör auf.

## Trennlinie

Eine Zeile aus drei oder mehr Bindestrichen, für sich allein.

```
---
```

---

## Codeblöcke

Code steht zwischen Zeilen aus drei Backticks — \`\`\`. Nach dem ersten Dreier kann eine Sprache folgen; sie ist rein kosmetisch und ändert am Rendern nichts. Im Block wird nichts formatiert, Sternchen und ähnliche Zeichen bleiben, wie sie sind.

```ruby
def greet(name)
  puts "Hello #{name}!"
end
```

Ein breiter Block scrollt in sich selbst, statt die Seite zu dehnen:

```
rsync -avz --delete --rsync-path="sudo rsync" -e "ssh -p 202" ./ user@server:/some/long/path/deep/down/
```

## Tabellen

Die erste Zeile ist der Kopf, die zweite ein Bindestrich-Trenner, der Rest sind Daten. Doppelpunkte im Trenner setzen die Spaltenausrichtung: `:---` links, `---:` rechts, `:---:` zentriert.

```
| Spalte | Rechts | Zentriert |
| --- | ---: | :---: |
| erste Zeile | 6228 | 1 |
| zweite Zeile | ~435 | **7 bis 9** |
```

| Spalte | Rechts | Zentriert |
| --- | ---: | :---: |
| erste Zeile | 6228 | 1 |
| zweite Zeile | ~435 | **7 bis 9** |

In Zellen funktioniert normale Formatierung, Links eingeschlossen. Eine breite Tabelle scrollt in sich selbst, wie ein Codeblock.

## Bilder

Ein Ausrufezeichen, Alt-Text in eckigen Klammern, Pfad in runden. Nach dem Pfad kann ein Titel in Anführungszeichen stehen — er erscheint als Bildunterschrift unter dem Foto.

```
![Alt-Text für Screenreader](/pfad/zum/foto.jpg)
![Alt-Text für Screenreader](/pfad/zum/foto.jpg "Unterschrift unter dem Foto")
```

Ein Bild braucht seine eigene Zeile, mit Leerzeilen davor und danach. Mitten im Absatz geht es nicht — das Speichern hält dann an und warnt.

Der Pfad darf irgendwohin auf der Platte zeigen, die Datei wird automatisch kopiert. Ein bloßer Dateiname ohne Pfad wird im Verzeichnis `incoming/` gesucht — praktisch beim Schreiben vom Handy: das Foto per SFTP hochladen und nur beim Namen nennen.

## Video

Zwei Ausrufezeichen, sonst wie ein Bild. Funktioniert für eine lokale Datei und für YouTube. **Bei einem Video ist die Unterschrift Pflicht.**

```
!![Videounterschrift](/pfad/zum/video.mp4)
!![Videounterschrift](https://www.youtube.com/watch?v=jNQXAC9IVRw)
```

!![Das allererste Video auf YouTube](https://www.youtube.com/watch?v=jNQXAC9IVRw)

Eine bloße YouTube-Adresse auf eigener Zeile wird **nicht** zum Player — sie wird ein gewöhnlicher Link. Das ist Absicht, damit sich ein Video auch einfach nur verlinken lässt.

## Escaping

Um ein Zeichen zu schreiben, das in Markdown etwas bedeutet, stell ihm einen Backslash voran.

```
\*kein Kursiv\*, die Maske \*.mp4, \`Backticks\` und \[eckige Klammern\]
```

\*kein Kursiv\*, die Maske \*.mp4, \`Backticks\` und \[eckige Klammern\]

Sieben Zeichen mit Bedeutung in Markdown lassen sich escapen:

```
*   `   ~   [   ]   !   \
```

Vor jedem anderen Zeichen bleibt der Backslash stehen, wie er ist — das Emoticon d8-\ braucht also keine Sonderbehandlung.

## Noch nicht unterstützt

Damit dich nichts überrascht, wenn es so bleibt, wie du es getippt hast:

- Kursiv mit Unterstrichen `_so_` — nimm Sternchen
- harte Zeilenumbrüche (zwei Leerzeichen am Zeilenende)
- Aufgabenlisten `- [ ]`
- mit Leerzeichen eingerückte Codeblöcke — nimm die drei Backticks
- verschachtelte Zitate `>>`
- mit `===` unterstrichene Überschriften
- Referenzlinks `[text][id]` und Fußnoten

Nichts davon zerlegt deinen Text, es wird nur genau so gerendert, wie geschrieben.
