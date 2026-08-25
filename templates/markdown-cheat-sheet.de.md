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
- [Chat](#chat)
- [Trennlinie](#trennlinie)
- [Codeblöcke](#codeblocke)
- [Tabellen](#tabellen)
- [Bilder](#bilder)
- [Video](#video)
- [Audio](#audio)
- [Anhänge](#anhange)
- [Escaping](#escaping)
- [Bewusst nicht unterstützt](#bewusst-nicht-unterstutzt)

## Absätze

Absätze trennt eine Leerzeile. Ein Zeilenumbruch innerhalb eines Absatzes wird beim Rendern zu einem Leerzeichen — für einen neuen Absatz also eine Leerzeile dazwischen lassen. Für einen harten Umbruch *innerhalb* eines Absatzes die Zeile mit einem Backslash beenden:

```
Erste Zeile \
zweite direkt darunter.
```

Erste Zeile \
zweite direkt darunter.

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

Sie dürfen auch unmittelbar nebeneinander stehen, ohne Leerzeichen. Die
drei Sterne in der Mitte werden als zwei gelesen: das schließende Paar
des Fettdrucks und der einzelne, der das Kursive öffnet. Umgekehrt geht
es auch — einer schließt das Kursive, das Paar öffnet den Fettdruck.

```
**fett***kursiv*
*kursiv***fett**
```

**fett***kursiv*
*kursiv***fett**

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

Eine Aufgabenliste markiert Einträge mit eckigen Klammern — gerendert als Checkboxen (nur lesbar; Besucher haken deine Aufgaben nicht ab):

```
- [x] Beitrag schreiben
- [ ] veröffentlichen
```

- [x] Beitrag schreiben
- [ ] veröffentlichen

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

Eine letzte Zeile, die mit einem Gedankenstrich (oder `--`) beginnt, wird
zur Quellenangabe:

```
> Fang am Anfang an und lies,
> bis du ans Ende kommst: dann hör auf.
> — Lewis Carroll
```

> Fang am Anfang an und lies,
> bis du ans Ende kommst: dann hör auf.
> — Lewis Carroll

## Chat

Ein Dialog kommt in einen `chat`-Zaun, eine Zeile je Aussage — der Sprecher
vor dem Doppelpunkt. Eine Zeile ohne Doppelpunkt setzt die vorige fort.

```
Watson: Was bedeutet das?
Holmes: Elementar.
```

Geschrieben als:

    ```chat
    Watson: Was bedeutet das?
    Holmes: Elementar.
    ```

## Trennlinie

Eine Zeile aus drei oder mehr Bindestrichen, für sich allein.

```
---
```

---

## Anrisstext

Eine Zeile `//--more--//`, für sich allein, teilt den Beitrag in zwei Teile. Was darüber steht, ist der Anrisstext: genau das erscheint in der Übersicht auf der Startseite, in der Ankündigung im sozialen Netzwerk und auf der Linkkarte. Was darunter steht, liest, wer den Beitrag öffnet.

Ohne diese Zeile schneidet die Engine den Anrisstext selbst vom Textanfang ab -- und ein maschineller Schnitt endet selten dort, wo er sollte.

Genau so schreiben, ohne Leerzeichen und klein. Anders geschrieben ist die Zeile eine gewöhnliche Notiz und verschwindet beim Speichern.

```
Der erste Absatz, der neugierig machen soll.

//--more--//

Der Rest des Beitrags, den die Übersicht nicht zeigt.
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

Fängst du gleich mit der Trennzeile an, hat die Tabelle gar keine Kopfzeile -- jede Zeile ist dann Inhalt. Praktisch für eine Liste von Paaren oder eine Tabelle, die dem Layout dient, wo eine Überschrift schlicht falsch wäre. Schreib diese erste Zeile mit den äußeren Pipes, genau wie unten: daran erkennt man eine Tabelle ohne Kopfzeile von einer Aufzählung, deren erster Punkt zufällig aus Satzzeichen besteht:

```
| --- | --- |
| Ctrl + c | Kopieren |
| Ctrl + v | Einfügen |
```

| --- | --- |
| Ctrl + c | Kopieren |
| Ctrl + v | Einfügen |

## Bilder

Ein Ausrufezeichen, Alt-Text in eckigen Klammern, Pfad in runden. Nach dem Pfad kann ein Titel in Anführungszeichen stehen — er erscheint als Bildunterschrift unter dem Foto.

```
![Alt-Text für Screenreader](/pfad/zum/foto.jpg)
![Alt-Text für Screenreader](/pfad/zum/foto.jpg "Unterschrift unter dem Foto")
```

Ein Bild braucht seine eigene Zeile, mit Leerzeilen davor und danach. Mitten im Absatz geht es nicht — das Speichern hält dann an und warnt.

Der Pfad darf irgendwohin auf der Platte zeigen, die Datei wird automatisch kopiert. Ein bloßer Dateiname ohne Pfad wird im Verzeichnis `incoming/` gesucht — praktisch beim Schreiben vom Handy: das Foto per SFTP hochladen und nur beim Namen nennen.

## Video

Zwei Ausrufezeichen, sonst wie ein Bild. Funktioniert für eine lokale Datei (.mp4, .mov, .m4v) und für eine Videoadresse: YouTube, Vimeo, PeerTube, archive.org. **Bei einem Video ist die Unterschrift Pflicht.**

```
!![Videounterschrift](/pfad/zum/video.mp4)
!![Videounterschrift](https://www.youtube.com/watch?v=jNQXAC9IVRw)
```

!![Das allererste Video auf YouTube](https://www.youtube.com/watch?v=jNQXAC9IVRw)

Eine bloße YouTube-Adresse auf eigener Zeile wird **nicht** zum Player — sie wird ein gewöhnlicher Link. Das ist Absicht, damit sich ein Video auch einfach nur verlinken lässt.

## Audio

Dieselben zwei Ausrufezeichen wie beim Video — unterschieden werden sie an
der Dateiendung (.mp3, .m4a, .ogg, .opus, .aac, .flac, .wav). **Die
Unterschrift ist Pflicht**, gerendert wird ein nativer Player. Dieselbe
Zeile nimmt auch eine Adresse von Spotify, SoundCloud, Mixcloud, Funkwhale
oder Bandcamp und macht daraus den Player der jeweiligen Plattform. (Bei
den letzten beiden genügt die Adresse allein nicht, das Speichern fragt
den Dienst einmal nach seinem Player -- der einzige Moment, in dem das
Schreiben eines Beitrags das Netz braucht.)

```
!![Unterschrift der Aufnahme](/pfad/zur/aufnahme.mp3)
```

## Anhänge

Eine Zeile, die nur ein Link ist und deren Ziel ein bloßer Dateiname ist,
macht aus der Datei eine Download-Karte samt Größe -- dieselbe Kurzform
wie bei Bildern, die Datei kann also in `incoming/` liegen und wird über
ihren Namen gefunden. Zählende Endungen: .pdf, .zip, .tgz, .epub, .txt,
.md, .ics, .gpx, .csv. Ein Link auf eine Adresse bleibt ein Link.

```
[Lesetagebuch 2025](tagebuch.pdf)
```

Ein Beitrag, dessen Text nur eine kurze Zeile plus Anhänge ist, landet
unter **Dokumente**; ein ganzer Artikel, der seine Daten anhängt, bleibt
ein Artikel mit Anhang.

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

## Bewusst nicht unterstützt

Das fehlt nicht — jedes wurde abgewogen und abgelehnt, meist weil seine
Kosten alle träfen, die es *nicht* benutzen:

- Kursiv mit Unterstrichen `_so_` — Unterstriche stecken in normalem Text
  (datei_namen, snake_case); nimm Sternchen
- mit Leerzeichen eingerückte Codeblöcke — kollidiert mit der Einrückung
  verschachtelter Listen; nimm die drei Backticks
- mit `===` unterstrichene Überschriften — eine Strichzeile bedeutet schon
  Trennlinie und Frontmatter-Grenze
- verschachtelte Zitate `>>`
- Referenzlinks `[text][id]` und Fußnoten

Auch das wird genau so gerendert, wie geschrieben.
