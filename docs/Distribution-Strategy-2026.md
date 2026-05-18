# Distribution- & Marketing-Strategie: AstroBlink

**Datum:** Mai 2026
**Frage:** Wie verbreitet man AstroBlink nachweislich und ohne großen Aufwand in der
Astro-/macOS-Community? Foren (CloudyNights, Astrotreff) sind zäh — gibt es Besseres?

---

## 0. Die strategische Grundannahme (wichtig)

AstroBlink ist **kostenlos, GPLv3, Open Source, im Mac App Store UND auf GitHub**.
Das heißt: Es gibt **keinen Kauf-Friction**. Das Problem ist **nicht** Conversion,
sondern reine **Awareness/Distribution**. Dazu kommt ein seltener Glücksfall:

> Es gibt **kein** gutes natives Apple-Silicon-Blink-Tool mit Quality-Scoring.
> Mac-Astrofotografen sind ein kleiner, lauter, **unterversorgter** Markt.
> Das ist kein Produkt-Problem — es ist ein „die richtigen 5.000 Leute müssen
> es sehen"-Problem. Solche Produkte verbreiten sich selbst, *sobald* sie
> vor der richtigen Zielgruppe landen.

Konsequenz: Foren sind nicht „falsch", sie sind nur der **ineffizienteste
Kanal pro Aufwand**. Sie werden nicht abgeschafft, sondern degradiert.

---

## 1. Warum Foren zäh sind (und was stattdessen funktioniert)

CloudyNights/Astrotreff sind langsam, weil die **aktive** Astro-Community
2024–2026 größtenteils auf **YouTube, Discord und Reddit** abgewandert ist.
Foren sind heute v. a. ein durchsuchbares Archiv, kein Verbreitungsmotor.

**Kanäle nach Hebelwirkung pro Aufwand (das Kernergebnis):**

| Rang | Kanal | Aufwand | Hebel | Messbar? |
|------|-------|---------|-------|----------|
| **S** | YouTube-Creator-Seeding | niedrig (async, einmalig) | sehr hoch, evergreen | ja (UTM/Referrer) |
| **S** | Reddit r/astrophotography (Value-Post) | niedrig | hoch, schnell | ja (Referrer/Link) |
| **S** | Discord (NINA/Cuiv/AstroBin) als echtes Mitglied | mittel (laufend) | hoch | teilweise |
| **A** | Homebrew Cask | sehr niedrig (1× PR) | dauerhaft + Stats | **ja (Homebrew-Analytics)** |
| **A** | SEO-Landingpage (GitHub Pages) | niedrig–mittel | evergreen Inbound | ja (Search Console) |
| **A** | PixInsight-Forum (Importer-Plugin) | niedrig | hoch (seriöseste Imager) | ja |
| **A** | AstroBin (Software-Listing + Acquisition-Credit) | niedrig | compounding Social Proof | teilweise |
| **B** | Show HN / Product Hunt | niedrig (1×) | Spike + Backlinks/SEO | ja |
| **B** | Facebook/Telegram-Gruppen (DACH + intl.) | niedrig | mittel | schwer |
| **C** | CloudyNights/Astrotreff | mittel | niedrig pro Aufwand | schwer |

---

## 2. Die konkreten Maßnahmen

### S-Tier

#### 2.1 YouTube-Creator-Seeding — der mit Abstand größte Hebel
Ein einziges Video des richtigen Creators = tausende exakt passende
Mac-Astrofotografen, **evergreen** (liefert über YouTube-Suche jahrelang weiter)
und sauber messbar. Da die App **kostenlos + Open Source** ist, ist das „Ja"
für Creator nahezu reibungslos.

**Internationale Zielliste (priorisiert):**
1. **Cuiv, The Lazy Geek** — extrem workflow-/tool-fokussiert, technische
   NINA/Automatisierungs-Audience, macht regelmäßig „dieses kostenlose Tool"-Videos.
   **Top-Ziel.**
2. **Nico Carver (Nebula Photos)** — große Einsteiger/Fortgeschrittenen-Audience,
   Champion für kostenlose Workflows (Siril-Publikum = oft Mac-Nutzer). **Top-Ziel.**
3. **Trevor Jones (AstroBackyard)** — größte Reichweite, mainstream.
4. Peter Zelinka, Russ' Astrophotography, Visible Dark, Deep Sky Detail,
   Patriot Astro, The Astro Imaging Channel (TAIC-Livestreams), Connect the Dots.

**DACH (für Astrotreff-Reichweite ohne Foren-Zähigkeit):**
- Astro mit Frank (Frank Sackenheim), AstroPhotonsTV, Clear-Sky-Channel u. a.

**So wird das „Ja" mühelos (= „ohne riesen Aufwand"):**
- Kurze, persönliche Mail/DM (kein Massenmailing).
- Fertiges 1-Seiten-Presskit beilegen: Competitive-Tabelle (aus
  `docs/Competitive-Analysis-2026.md`), Screenshots aus `screenshots/`,
  20-Sek.-Before/After-Clip („300 XISF in 20 s blinken; PixInsight Blink
  crasht bei 200").
- Den Schmerz nennen, nicht Features: *„PixInsight Blink crasht bei 200 XISF
  und zeigt null Metriken — das hier ist nativ, GPU, kostenlos."*
- Einen fertigen Story-Winkel mitliefern, damit der Creator nur aufnehmen muss.

#### 2.2 Reddit r/astrophotography (~Millionen) + r/AskAstrophotography
Viel schnellerer Feedback-Loop als CloudyNights. Reddit belohnt **FOSS** stark.
**Format entscheidet:** *Nicht* „Ich habe eine App gebaut" (wird entfernt),
sondern **Value-First**: ein Workflow-/Before-After-Post oder GIF
(„300 Subs in 20 s aussortiert, hier wie"), Tool als Mittel erwähnt, betont
kostenlos + Open Source. Monatliche „What's your workflow?"-Threads sind
natürliche Mention-Stellen. Messbar über Reddit-Referrer + getrackten Link.

#### 2.3 Discord — wo die Community wirklich lebt
Genau hier sind die aktiven Leute, die in Foren fehlen. Server: großer
allgemeiner Astro-Imaging-Discord, Cuiv-Discord, AstroBin-Discord,
Nebula-Photos/Nico-Discord, ZWO/ASIAIR-Communities, **NINA-Discord** (die App
integriert NINA-Metadaten tief → natürlicher, glaubwürdiger Touchpoint).
Strategie: **echtes hilfreiches Mitglied** sein, ein #showcase/#tools-Post,
und die ständig auftauchende Frage „bestes Cull-Tool für Mac?" beantworten
(heute lautet die Antwort schwach „PixInsight in einer VM" oder „Siril" —
das lässt sich direkt verbessern).

### A-Tier

#### 2.4 Homebrew Cask — niedrigster Aufwand, dauerhaft, messbar
`brew install --cask astroblink`. Mac-Astrofotografen (NINA/INDI/KStars-Umfeld)
sind technisch. Ein einmaliger PR an `homebrew-cask` = permanenter, auffindbarer
Distributionskanal + **öffentliche, anonyme Install-Statistik** → genau das
„nachweislich", das gefragt war. Sehr hoher Glaubwürdigkeits-Effekt für minimalen Aufwand.

#### 2.5 SEO-Landingpage (GitHub Pages, `docs/` existiert bereits)
Leute googeln wörtlich: *„PixInsight Blink alternative Mac"*, *„cull astro subs
macOS"*, *„Siril blink Mac"*, *„FITS viewer macOS"*, **„XISF QuickLook Mac"**.
Dafür gibt es heute kaum gute Treffer. Eine schnelle statische Seite mit
Competitive-Tabelle + 20-Sek-GIF + dem **QuickLook-Hook** (nahezu konkurrenzlos
googelbar) wird ein evergreen Inbound-Funnel. Messbar via Search Console.

#### 2.6 PixInsight-Forum — Importer-Plugin ist bereits gebaut
`pixinsight-astroblink/` enthält ein fertiges PI-Update-Repository. Eine
Ankündigung des Importers im **offiziellen PixInsight-Forum** (forum.pixinsight.com,
Bereich Tools/Scripts) ist legitim (echtes PI-Tool, keine reine Werbung) und
erreicht die seriösesten Imager — PI ist plattformübergreifend, also auch
Brückenkopf zu Mac-Besitzern, die noch PI nutzen.
Framing: *„Kostenloses PI-Script, das gewichtetes Culling aus einer Mac-App
in WBPP importiert."*

#### 2.7 AstroBin — compounding Social Proof
Weltweite Bild-Plattform der ernsthaften Astrofotografen. Zwei Hebel:
- **Software-/Acquisition-Feld:** AstroBlink als genutzte Software taggen
  lassen → erscheint passiv in Aufnahme-Metadaten = sich selbst verstärkender
  Social Proof, v. a. wenn IOTD-Imager es im Workflow nennen.
- AstroBin-Software-Datenbank-Eintrag + Forenpräsenz.

### B-Tier (je 1× mitnehmen)

- **Show HN (Hacker News):** Open-Source + Metal-Engineering-Story
  (Zero-Copy Unified Memory, GPU-PSF-Fitting, natives QuickLook) — spiky,
  aber kostenlos, gut für Backlinks/SEO und Tech-affine Mac-User.
- **Product Hunt:** einmaliger Spike, nischig, aber gute SEO-Backlinks.
- **Facebook/Telegram-Gruppen:** „Astrophotography", ZWO ASI Users,
  NINA-Users, DACH-Gruppen — große, ältere Reichweite ohne Foren-Latenz.
- **Partner-Newsletter:** NINA-Projekt (tiefe Integration → glaubwürdige
  Erwähnung), ZWO/ASIAIR (App parst ASIAIR-Dateinamen).

### C-Tier

- **CloudyNights/Astrotreff:** nicht aufgeben, aber **als Anker, nicht Motor**:
  *ein* gut platzierter Value-First-Thread (Software-/Mac-Subforum) mit
  Competitive-Tabelle + Screenshots, danach nur noch als Link-Referenz nutzen.

---

## 3. Die „nachweislich"-Schicht (Messung = das, was die Strategie real macht)

Ohne Messung ist es eine Wunschliste. Minimal-Setup:

1. **Eine kanonische Landingpage** (GitHub Pages) als überall genutzter Link,
   mit **per-Kanal-UTM** (`yt-cuiv`, `yt-nico`, `reddit`, `discord-nina`,
   `pixinsight`, `hn`, `astrotreff`).
2. **GitHub-Release-Download-Counts** pro Asset (GitHub-API, kostenlos) über
   Zeit tracken.
3. **App-Store-Connect-Analytics**: Quellen, Impressions, Conversions.
4. **Homebrew-Analytics**: öffentliche Install-Zahlen.
5. **Optionaler, datenschutzkonformer Adoption-Zähler:** Die App spricht
   bereits mit Supabase (Target-Katalog/Kalibrierung). Ein minimaler,
   **opt-in**, anonymer Active-Install/Version-Ping (im Rahmen von
   `PRIVACY.md`) liefert die echte Adoptionszahl = wörtlich das gewünschte
   „nachweislich". (Nur opt-in, sonst gar nicht.)
6. **Funnel + 90-Tage-Ziel** definieren: Impressions → Landing-Visits →
   Downloads → aktive Installs → AstroBin/Forum-Mentions. Erfolg wird so
   beweisbar statt gefühlt.

---

## 4. Priorisierter 30/60/90-Tage-Plan (Aufwand bewusst klein gehalten)

**Woche 1–2 (höchster ROI, ~2 Tage Arbeit):**
- Landingpage aus `docs/` → GitHub Pages: Competitive-Tabelle +
  20-Sek-Before/After-GIF + QuickLook-Hook + UTM/Download-Tracking.
- Homebrew-Cask-PR einreichen.
- PixInsight-Forum-Thread zum Importer.

**Woche 2–4:**
- Personalisierte Outreach an 6–10 Creator (gestaffelt: Cuiv & Nico Carver
  zuerst, dann DACH). 1-Seiten-Presskit + Demo-Footage beilegen, damit es
  für den Creator **null Aufwand** ist.
- 2–3 Discords als echtes Mitglied seeden.
- *Ein* starker Value-First-Reddit-Post.

**Monat 2–3:**
- Show HN / Product Hunt.
- AstroBin-Software-Listing + Acquisition-Credit aktiv anstoßen.
- Follow-ups; **auf den Kanal verdoppeln, den das Tracking als Konverter zeigt.**
- Wiederkehrender monatlicher Reddit/Discord-Workflow-Content.

---

## 5. Die Kurzantwort

Der eine größte Hebel bei minimalem Aufwand: **YouTube-Creator-Seeding**
(kostenlos, async, evergreen, hyper-zielgenau, messbar). Der
aufwandsärmste Dauerkanal: **Homebrew-Cask + SEO-Landingpage**. Foren
sind der schlechteste Aufwand/Nutzen → degradieren, nicht abschaffen.
Weil die App gratis + Open Source + auf einer unterversorgten Plattform mit
klarer 10×-Differenzierung ist, ist Verbreitung ein reines Sichtbarkeits-
problem — und genau das lösen die S-Tier-Kanäle.
