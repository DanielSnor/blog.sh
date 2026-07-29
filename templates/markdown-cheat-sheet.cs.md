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
- [Vodorovná čára](#vodorovna-cara)
- [Blok kódu](#blok-kodu)
- [Tabulky](#tabulky)
- [Obrázky](#obrazky)
- [Video](#video)
- [Escapování](#escapovani)
- [Co zatím nefunguje](#co-zatim-nefunguje)

## Odstavce

Odstavce se oddělují prázdným řádkem. Zalomení uvnitř odstavce se při zobrazení slije do mezery — pokud tedy chcete nový odstavec, nechte mezi nimi volný řádek.

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

Odrážky začínají pomlčkou nebo hvězdičkou, číslovaný seznam číslem s tečkou. Mezi položkami nesmí být prázdný řádek — ten by seznam ukončil.

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

## Vodorovná čára

Řádek se třemi a více pomlčkami, sám o sobě.

```
---
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

## Obrázky

Vykřičník, popisek v hranatých závorkách, cesta v kulatých. Za cestu se dá přidat titulek v uvozovkách, který se zobrazí jako popisek pod fotkou.

```
![Popisek pro čtečky](/cesta/k/fotce.jpg)
![Popisek pro čtečky](/cesta/k/fotce.jpg "Titulek pod fotkou")
```

Obrázek musí být na vlastním řádku, oddělený prázdnými řádky. Uprostřed odstavce ho zapsat nejde — uložení se v takovém případě zastaví a upozorní.

Cesta může vést kamkoliv na disku, soubor se zkopíruje sám. Holé jméno souboru bez cesty se hledá ve složce `incoming/` — to se hodí při psaní z telefonu, kdy fotku nahrajete přes SFTP a v textu na ni odkážete jen jménem.

## Video

Dva vykřičníky, jinak stejně jako obrázek. Funguje pro soubor i pro YouTube. **Popisek je u videa povinný.**

```
!![Popisek videa](/cesta/k/videu.mp4)
!![Popisek videa](https://www.youtube.com/watch?v=jNQXAC9IVRw)
```

!![Úplně první video na YouTube](https://www.youtube.com/watch?v=jNQXAC9IVRw)

Samotná adresa na YouTube napsaná na řádku se na přehrávač **nezmění** — z ní bude obyčejný odkaz. To je schválně, aby šlo na video jen odkázat.

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

## Co zatím nefunguje

Ať nikoho nepřekvapí, že něco zůstane, jak to napsal:

- podtržítková kurzíva `_takhle_` — používejte hvězdičky
- tvrdé zalomení řádku (dvě mezery na konci)
- zaškrtávací seznamy `- [ ]`
- blok kódu odsazený mezerami — používejte tři apostrofy
- vnořené citace `>>`
- nadpis podtržený `===` pod textem
- referenční odkazy `[text][id]` a poznámky pod čarou

Nic z toho text nezkomolí, jen se to zobrazí tak, jak jste to napsali.
