---
title: Markdown Cheat Sheet
---
Tenhle web se píše v markdownu — v editoru, který otevře `./blog.sh add`. Není to úplný markdown, je to podmnožina šitá na míru tomuhle enginu. Tahle stránka ukazuje všechno, co umí: u každé skupiny nejdřív zdroj, jak ho napsat, a hned pod ním, jak to dopadne.

Odkaz na tuhle stránku je i v nápovědě v editoru, takže ji máte při psaní po ruce.

- [Odstavce](#odstavce)
- [Nadpisy](#nadpisy)
- [Zvýraznění textu](#zvyrazneni-textu)
- [Odkazy](#odkazy)
- [Seznamy](#seznamy)
- [Citace](#citace)
- [Chat](#chat)
- [Vodorovná čára](#vodorovna-cara)
- [Blok kódu](#blok-kodu)
- [Tabulky](#tabulky)
- [Obrázky](#obrazky)
- [Video](#video)
- [Audio](#audio)
- [Přílohy](#prilohy)
- [Escapování](#escapovani)
- [Záměrně nepodporované](#zamerne-nepodporovane)

## Odstavce

Odstavce se oddělují prázdným řádkem. Zalomení uvnitř odstavce se při zobrazení slije do mezery — pokud tedy chcete nový odstavec, nechte mezi nimi volný řádek. Pro tvrdé zalomení *uvnitř* odstavce ukončete řádek zpětným lomítkem:

```
První řádek \
druhý hned pod ním.
```

První řádek \
druhý hned pod ním.

```
První odstavec.

Druhý odstavec.
```

První odstavec.

Druhý odstavec.

## Nadpisy

Mřížky na začátku řádku, jedna až šest podle úrovně. Nadpis musí být sám na svém řádku.

```
# Nadpis první úrovně
## Nadpis druhé úrovně
### Nadpis třetí úrovně
#### Nadpis čtvrté úrovně
##### Nadpis páté úrovně
###### Nadpis šesté úrovně
```

První dvě úrovně používá tenhle článek na své vlastní sekce, takže tady je ukázka od třetí níž:

### Nadpis třetí úrovně

#### Nadpis čtvrté úrovně

##### Nadpis páté úrovně

## Zvýraznění textu

```
**tučně**, *kurzívou*, ~~přeškrtnutě~~ a `kód uvnitř věty`
```

**tučně**, *kurzívou*, ~~přeškrtnutě~~ a `kód uvnitř věty`

Zvýraznění jde kombinovat a vnořovat do sebe:

```
**tučný text s *kurzívou* uvnitř**
```

**tučný text s *kurzívou* uvnitř**

Můžou taky stát hned vedle sebe, bez mezery. Trojice hvězdiček uprostřed
se čte jako dvě: zavírací pár tučného a jedna, která otevírá kurzívu.
Funguje to i obráceně — jedna zavírá kurzívu, pár otevírá tučné.

```
**tučně***kurzívou*
*kurzívou***tučně**
```

**tučně***kurzívou*
*kurzívou***tučně**

## Odkazy

Text v hranatých závorkách, adresa v kulatých. Za adresu se dá přidat titulek v uvozovkách — ten se ukáže jako bublina po najetí myší.

```
[Příklad](https://example.com)
[Příklad s titulkem](https://example.com "Bublina po najetí myší")
```

[Příklad](https://example.com) a [Příklad s titulkem](https://example.com "Bublina po najetí myší")

Adresa napsaná přímo ve větě se na odkaz změní sama, není ji potřeba nijak označovat:

```
Píšu o tom na https://example.com pravidelně.
```

Píšu o tom na https://example.com pravidelně.

## Seznamy

Odrážky začínají pomlčkou nebo hvězdičkou, číslovaný seznam číslem s tečkou. Mezi položkami nesmí být prázdný řádek — ten by seznam ukončil. Odrážku delší než řádek můžete zalomit: zbytek odsaďte o dvě mezery a slije se do mezery stejně jako zalomení uvnitř odstavce.

```
- první odrážka
- druhá odrážka
- třetí odrážka
```

- první odrážka
- druhá odrážka
- třetí odrážka

```
1. první bod
2. druhý bod
3. třetí bod
```

1. první bod
2. druhý bod
3. třetí bod

Zaškrtávací seznam značí položky hranatými závorkami — vykreslí se jako checkboxy (jen ke čtení; návštěvník vaše úkoly neodškrtá):

```
- [x] napsat post
- [ ] publikovat ho
```

- [x] napsat post
- [ ] publikovat ho

Na číslech nezáleží, při zobrazení se přepočítají. Vnořený seznam se odsadí o dvě mezery:

```
- ovoce
  - jablko
  - hruška
- zelenina
  1. mrkev
  2. petržel
```

- ovoce
  - jablko
  - hruška
- zelenina
  1. mrkev
  2. petržel

## Citace

Každý řádek citace začíná znakem `>`.

```
> Nad Tatrou sa blýska, hromy divo bijú.
> Zastavme ich bratia, veď sa ony stratia, Slováci ožijú.
```

> Nad Tatrou sa blýska, hromy divo bijú.
> Zastavme ich bratia, veď sa ony stratia, Slováci ožijú.

Poslední řádek začínající dlouhou pomlčkou (nebo `--`) se stane atribucí:

```
> Začni na začátku a pokračuj,
> dokud nedojdeš na konec: pak přestaň.
> — Lewis Carroll
```

> Začni na začátku a pokračuj,
> dokud nedojdeš na konec: pak přestaň.
> — Lewis Carroll

## Chat

Dialog patří do ohrady `chat`, jedna replika na řádek — mluvčí před
dvojtečkou. Řádek bez dvojtečky pokračuje v předchozí replice.

```
Watson: Co to znamená?
Holmes: Elementární.
```

Zapsáno jako:

    ```chat
    Watson: Co to znamená?
    Holmes: Elementární.
    ```

## Vodorovná čára

Řádek se třemi a více pomlčkami, sám o sobě.

```
---
```

---

## Upoutávka

Řádek `//--more--//`, sám o sobě, rozdělí příspěvek na dvě části. Co je nad ním, je upoutávka: přesně tohle se ukáže ve výpisu na titulní stránce, v oznámení na sociální síti a na kartě odkazu. Co je pod ním, si přečte, kdo příspěvek otevře.

Bez tohoto řádku si engine upoutávku ustřihne ze začátku textu sám — a strojový řez zřídka skončí tam, kde by měl.

Zapisuje se přesně takhle, bez mezer a malými písmeny. Jinak zapsaný řádek je obyčejná poznámka a při uložení zmizí. Prázdné řádky kolem nejsou potřeba — stačí, když je na řádku sama.

```
První odstavec, který má zaujmout.

//--more--//

Zbytek příspěvku, který ve výpisu vidět není.
```

---

## Blok kódu

Kód se zabalí mezi řádky se třemi zpětnými apostrofy — \`\`\`. Za první trojici se dá napsat jazyk; je to jen kosmetika, na zobrazení to nemá vliv. Uvnitř bloku se nic neformátuje, hvězdičky a podobné znaky zůstanou doslova.

```ruby
def pozdrav(jmeno)
  puts "Ahoj #{jmeno}!"
end
```

Široký blok se posouvá sám v sobě, neroztáhne stránku:

```
rsync -avz --delete --rsync-path="sudo rsync" -e "ssh -p 202" ./ user@server:/dlouha/cesta/nekam/hluboko/
```

## Tabulky

První řádek je hlavička, druhý oddělovač s pomlčkami, zbytek data. Dvojtečky v oddělovači určují zarovnání sloupce: `:---` vlevo, `---:` vpravo, `:---:` na střed.

```
| Sloupec | Vpravo | Na střed |
| --- | ---: | :---: |
| první řádek | 6228 | 1 |
| druhý řádek | ~435 | **7 až 9** |
```

| Sloupec | Vpravo | Na střed |
| --- | ---: | :---: |
| první řádek | 6228 | 1 |
| druhý řádek | ~435 | **7 až 9** |

V buňkách funguje běžné formátování včetně odkazů. Široká tabulka se posouvá sama v sobě, stejně jako blok kódu.

Když začneš rovnou oddělovačem, tabulka žádnou hlavičku nemá a každý řádek je data. Hodí se na seznam dvojic nebo na tabulku použitou k rozvržení, kde by nadpis lhal. Ten první řádek piš i s vnějšími svislítky, přesně jako níž — podle nich se pozná tabulka bez hlavičky od odrážkového seznamu, jehož první položka je shodou okolností interpunkce:

```
| --- | --- |
| Ctrl + c | Kopírovat |
| Ctrl + v | Vložit |
```

| --- | --- |
| Ctrl + c | Kopírovat |
| Ctrl + v | Vložit |

## Obrázky

Vykřičník, popisek v hranatých závorkách, cesta v kulatých. Za cestu se dá přidat titulek v uvozovkách, který se zobrazí jako popisek pod fotkou.

```
![Popisek pro čtečky](/cesta/k/fotce.jpg)
![Popisek pro čtečky](/cesta/k/fotce.jpg "Titulek pod fotkou")
```

Obrázek musí být na vlastním řádku, oddělený prázdnými řádky. Uprostřed odstavce ho zapsat nejde — uložení se v takovém případě zastaví a upozorní.

Cesta může vést kamkoliv na disku, soubor se zkopíruje sám. Holé jméno souboru bez cesty se hledá ve složce `incoming/` — to se hodí při psaní z telefonu, kdy fotku nahrajete přes SFTP a v textu na ni odkážete jen jménem.

## Video

Dva vykřičníky, jinak stejně jako obrázek. Funguje pro soubor (.mp4, .mov, .m4v) i pro adresu videa: YouTube, Vimeo, PeerTube, archive.org. **Popisek je u videa povinný.**

```
!![Popisek videa](/cesta/k/videu.mp4)
!![Popisek videa](https://www.youtube.com/watch?v=jNQXAC9IVRw)
```

!![Úplně první video na YouTube](https://www.youtube.com/watch?v=jNQXAC9IVRw)

Samotná adresa na YouTube napsaná na řádku se na přehrávač **nezmění** — z ní bude obyčejný odkaz. To je schválně, aby šlo na video jen odkázat.

## Audio

Stejné dva vykřičníky jako u videa — rozlišuje je přípona souboru
(.mp3, .m4a, .ogg, .opus, .aac, .flac, .wav). **Popisek je povinný**
a soubor se vykreslí jako nativní přehrávač. Na tentýž řádek jde napsat
i adresu ze Spotify, SoundCloudu, Mixcloudu, Funkwhale nebo Bandcampu —
udělá se z ní přehrávač té platformy. (U posledních dvou samotná adresa
nestačí, takže se uložení postu jednou zeptá služby, kde má přehrávač —
jediná chvíle, kdy psaní postu potřebuje síť.)

```
!![Popisek nahrávky](/cesta/k/nahravce.mp3)
!![Popisek nahrávky](https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT)
!![Popisek nahrávky](https://soundcloud.com/nasa/sputnik-beep)
```

## Přílohy

Řádek, který je jen odkaz a jehož cíl je holé jméno souboru, udělá ze
souboru kartu ke stažení i s velikostí — stejná zkratka jako u obrázků,
takže soubor můžeš nahrát do `incoming/` a odkázat se na něj jménem.
Přípony, které se počítají: .pdf, .zip, .tgz, .epub, .txt, .md, .ics,
.gpx, .csv. Odkaz na adresu zůstává obyčejným odkazem.

```
[Čtenářský deník 2025](denik.pdf)
```

Post, jehož text je jen krátká věta plus přílohy, spadne pod
**Dokumenty**; delší článek, který k sobě přibalí data, zůstává článkem
s přílohou.

## Karta odkazu

Post může BÝT O nějaké adrese — o vydání, o cizím článku, o stránce, na
kterou chceš ukázat. To je karta nad textem, ne řádek v něm, takže se
píše do hlavičky, ne do těla:

```
---
tags: release
link: https://example.com/o-cem-to-je
link_title: O čem to je
---

A tady je, co si o tom myslím.
```

`link_title` a `link_description` jsou slova na kartě, obojí
nepovinné; bez vlastního `title:` se post jmenuje podle karty. Odstavec,
který je jen odkaz, zůstává tím, čím vypadá — obyčejným odkazem
v obyčejném textu.

## Escapování

Když chcete napsat znak, který má v markdownu význam, předsaďte mu zpětné lomítko.

```
\*tohle není kurzíva\*, maska \*.mp4, \`apostrofy\` a \[hranaté závorky\]
```

\*tohle není kurzíva\*, maska \*.mp4, \`apostrofy\` a \[hranaté závorky\]

Escapovat jde sedm znaků, které v markdownu něco znamenají:

```
*   `   ~   [   ]   !   \
```

Před jiným znakem lomítko zůstane, jak je — takže smajlík d8-\ psát nijak zvlášť nemusíte.

## Záměrně nepodporované

Tohle nechybí — každá položka byla zvážena a odmítnuta, většinou proto, že
by její cena dopadla na všechny, kdo ji *nepoužívají*:

- podtržítková kurzíva `_takhle_` — podtržítka žijí v běžném textu (názvy_souborů, snake_case); používejte hvězdičky
- blok kódu odsazený mezerami — koliduje s odsazením vnořených seznamů; používejte tři zpětné apostrofy
- nadpis podtržený `===` — řádek pomlček už znamená oddělovač a hranici frontmatteru
- vnořené citace `>>`
- referenční odkazy `[text][id]` a poznámky pod čarou

I tohle se zobrazí přesně tak, jak jste to napsali.
