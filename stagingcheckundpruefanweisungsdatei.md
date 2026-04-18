# Quality Staging Pipeline — Prüfanweisung

## Kontext

- **Repo:** [AstroBlinkV2](https://github.com/joergs-git/AstroBlinkV2)
- **Datei:** `AstroTriage/Engine/QualityEstimator.swift` (1999 Zeilen)
- **Zweck:** Five-tier quality classification pipeline für astrofotografische Sub-Exposures
- **Ausführungsreihenfolge der Stages** (wichtig — weicht von der Nummerierung ab):
  1. Pre-processing (solar-system exclusion, grouping via `GroupKey`)
  2. Per-group loop: **Stage 1** (absolute garbage) → **Stage 2** (weighted z-score) → **Stage 3** (rescue)
  3. Session-wide post-passes (nach allen Gruppen): **Stage 1.5** (session sanity demote) → **Stage 1.5b** (historical demote) → **Stage 4** (FWHM rescue)
- **Seitliche Overrides:** `isLockedKeep` (≥30 learned frames in Calibration DB), `isCommunityFloorLocked` (Community baseline fallback)

## Auftrag an den prüfenden Prozess

Für jeden der 10 Findings unten:

1. **Verifiziere** den Befund durch Code-Analyse an den angegebenen Zeilen.
2. Wenn **Bug bestätigt**: formuliere einen minimalen Fix (Diff-Stil).
3. Wenn **Intentional**: dokumentiere den vermutlichen Grund und schlage ggf. einen klärenden Kommentar im Code vor.
4. Wenn **unklar**: formuliere eine präzise Rückfrage an Joerg (keine Ja/Nein-Fragen — offene, spezifische Fragen).
5. **Wichtig:** Bevor du einen Fix implementierst, prüfe ob Tests in `Tests/QualityEstimatorTests.swift` den betroffenen Pfad bereits abdecken. Wenn nein — schlag einen Regressions-Test vor (nicht implementieren, nur skizzieren).

Kontext von Joerg: **Die Logik ist organisch gewachsen aufgrund konkreter Auffälligkeiten und Vorkommnisse in realen Imaging-Sessions.** Das heißt: Verdächtige Thresholds oder Special-Cases können empirisch auf echten Kurations-Daten (4550+ Frames) kalibriert sein. Nicht reflexartig "aufräumen" — erst verstehen warum es so ist.

## Prioritätsskala

- **P0** — Klarer Logikfehler, Fehlverhalten reproduzierbar konstruierbar
- **P1** — Wahrscheinlicher Bug oder Inkonsistenz, Kontext unklar
- **P2** — Design-Schwäche, Kalibrierungs-Frage, nicht eindeutig falsch
- **P3** — Tote Konstante, Cleanup

## Response-Format (bitte vom prüfenden Prozess verwenden)

Pro Finding ein Block:

```
FINDING-XX: [confirmed bug | intentional | uncertain | invalid]
Reasoning: <2-4 Sätze Begründung mit Zeilenref>
Fix: <Diff oder "n/a">
Test-Gap: <welcher Test fehlt oder "covered by TestName">
Question-for-Joerg: <offene Rückfrage oder "none">
```

---

## FINDING-01 [P0] Stage 4 revertiert Stage-1.5- und Stage-1.5b-Demotes

**Ort:** Stage 4 Zeilen 1089–1145. Stage 1.5 Zeilen 1744–1758. Stage 1.5b Zeilen 1508–1522.

**Beobachtung:** Stage 4 selektiert rettungsfähige Frames mit:

```swift
case .trash where bd.garbageReasons.isEmpty:
    zScoreTrash.append((entry.url, fwhmVal))
```

Sowohl Stage 1.5 als auch Stage 1.5b erzeugen ihre Demote-Breakdowns mit `garbageReasons: []` und legen die Begründungen stattdessen in `sessionSanityReasons` bzw. `historicalBaselineReasons` ab:

```swift
var demoted = QualityBreakdown(tier: .trash, ..., garbageReasons: [], ...)
demoted.sessionSanityReasons = flags      // Stage 1.5
demoted.historicalBaselineReasons = flags // Stage 1.5b
```

Damit matcht Stage 4 auch diese beiden Demote-Typen und kann sie zurück auf `.borderline` heben — und überschreibt dabei die Reasoning-Text mit "FWHM comparable to good frames".

**Warum problematisch:** Der Kommentar an Stage 4 nennt explizit nur "z-score trash" (also Stage 2) als Zielgruppe. Session-Sanity und Historical-Baseline demoten aber aus *anderen* Gründen (SNR-Drop, Sternzahl-Drop, historische Baselines) — deren FWHM kann trotzdem gut sein, weil Wolken/Dew etc. die FWHM nicht zwingend degradieren.

**Verifikation:**
```bash
grep -n "sessionSanityReasons\|historicalBaselineReasons" AstroTriage/Engine/QualityEstimator.swift
```
Sollte zeigen dass weder Name in der Stage-4-Schleife (Zeile 1089–1145) vorkommt.

**Fix-Vorschlag:**
```swift
// Zeile ~1109
case .trash where bd.garbageReasons.isEmpty
              && bd.sessionSanityReasons.isEmpty
              && bd.historicalBaselineReasons.isEmpty:
    zScoreTrash.append((entry.url, fwhmVal))
```

**Test-Gap:** Kein Test erzwingt die Kombination "Stage 1.5-demoted + FWHM-im-good-90p" → bleibt Trash. Regressions-Test hinzufügen.

---

## FINDING-02 [P1] Per-night-Overwrite kann relative Stage-1-Garbage-Flags des Combined-Pass erasen

**Ort:** Zeilen 293–331 (groupsList-Aufbau) und 849–869 (Garbage-Result-Assignment + continue).

**Beobachtung:** `groupsList` enthält zuerst Combined-Gruppen, dann per-night-Gruppen wo `indices.count >= minGroupSize`. Die Hauptschleife iteriert in dieser Reihenfolge und schreibt pro Frame `result[entry.url] = breakdown`. Per-night-Write überschreibt Combined-Write.

Für **absolute** Garbage-Regeln (Rule 0 `noData`, Rule 1a `stars < 10`, Rule 1b decentered via solved coords, Rule 10 twilight) sind beide Pässe deterministisch gleich — kein Problem.

Für **relative** Garbage-Regeln (Rule 1b via `median * dropThreshold`, Rule 2 SNR via `median * 0.5`, Rule 3/4 FWHM/HFR via `median / 0.5`, Rule 7 starCountAnomaly, Rule 7b starCountDrop, Rule 8 backgroundAnomaly, Rule 9 chain detection) kann ein Frame im Combined-Pass als Garbage markiert werden (großer Median → hohe Schwelle) und im Per-night-Pass nicht (kleiner Median → Schwelle nicht erreicht). Der per-night-Pass schreibt dann ein nicht-garbage Breakdown, das Label ist weg.

**Warum problematisch:** Die absolute Aussage "dieses Frame ist katastrophal" wird durch relative Betrachtung in kleinerer Stichprobe aufgehoben — obwohl die Stichprobe nur kleiner, nicht "korrekter" ist.

**Verifikation:** Konstruiere ein synthetisches Szenario:
- Combined-Gruppe: 30 Frames, davon 1 Wolkenframe mit 60 Sternen, Median = 500.
- Rule 1b: `60 < 500 * 0.3 = 150` → `.noStars` appended.
- Per-night-Gruppe: 8 Frames derselben Nacht, der Wolkenframe dabei, Median = 80.
- Rule 1b: `60 < 80 * 0.3 = 24` → feuert nicht.
- Ergebnis: Frame wird nicht mehr als Garbage markiert.

**Fragen an Joerg:** Ist das gewollt? Der Kommentar "per-night scoring is more accurate" bezieht sich offenbar auf Z-Scores — gilt das auch für absolute-Outlier-Detection? Eine mögliche Semantik wäre: **Garbage-Flags aus dem Combined-Pass nie überschreiben, nur erweitern.**

**Fix-Skizze (wenn Bug):** Vor der per-night-Assignment bestehende `garbageReasons` mergen statt überschreiben.

---

## FINDING-03 [P1] Rescue-Reasoning bleibt stehen, wenn `.uncertain` Override Stage 3 verwirft

**Ort:** Zeilen 948–996 (Stage 3 rescue + reasoning-Text-Generierung) und 1019–1024 (uncertain-Override).

**Beobachtung:** Ablauf im Code:
1. Stage 3 rettet Frame zu `.good`, setzt `rescueReason = "FWHM and noise within group norm"`.
2. `generateReasoning()` wird mit diesem `rescueReason` aufgerufen und produziert `reasoning`-Text, der den Rescue erwähnt.
3. Danach kippt `if ... && indices.count < 8 && (tier == .good || tier == .borderline) ...` den Tier auf `.uncertain`.
4. `QualityBreakdown(..., tier: .uncertain, reasoningText: reasoning, ...)` wird mit dem alten, veralteten `reasoning` gebaut.

Resultat: Frame zeigt Tier = uncertain mit Text "FWHM and noise within group norm — …" — Narrativ einer Rettung, die nicht mehr gilt.

**Kosmetisch aber:** Verwirrt Debugging und Tooltips.

**Fix-Vorschlag:**
```swift
// nach dem uncertain-Block (Zeile 1024):
let finalReasoning = (tier == .uncertain)
    ? "Small group — low confidence"
    : reasoning
// dann finalReasoning statt reasoning in die Breakdown
```

**Test-Gap:** Kein Test checkt Reasoning-Text-Kohärenz nach uncertain-Override.

---

## FINDING-04 [P1] P90-Berechnung liefert bei kleinen Arrays P100

**Ort:** Zeile 629–631 (Rule 1c star P90 floor), analog potentiell in Stage 1.5 Zeilen 1638–1642.

**Beobachtung:**
```swift
let p90 = sortedStars[Int(Double(sortedStars.count) * 0.9)]
```

Bei `count = 5`: `Int(4.5) = 4` → letztes Element (Max, also P100). Bei `count = 10`: `Int(9.0) = 9` → letztes Element. Erst ab `count ≥ 20` wird der tatsächliche P90 erreicht.

**Konsequenz für Rule 1c:** Die Regel "Frame < 15% von P90" wird bei kleinen Gruppen faktisch zu "Frame < 15% vom Maximum" — strenger als dokumentiert. Da minGroupSize = 6, sind kleine Gruppen die Regel nicht die Ausnahme.

**Verifikation:** Analog in Stage 1.5 (Zeile 1638–1642) steht `fwhms[max(0, fwhms.count / 10)]` für P10 — das ist bei count=6 Index 0 (Minimum statt P10). Gleicher Mechanismus.

**Fix-Vorschlag:** Interpolierter Perzentil oder explizite kleine-Gruppe-Behandlung:
```swift
let idx = min(sortedStars.count - 1, Int(Double(sortedStars.count - 1) * 0.9 + 0.5))
let p90 = sortedStars[idx]
```

Sauberer: Helper `percentile(_ p: Double, _ sorted: [Double]) -> Double` einführen, an beiden Stellen nutzen.

---

## FINDING-05 [P1] Frames mit `wSum == 0` verschwinden spurlos aus `result`

**Ort:** Zeile 926.

**Beobachtung:**
```swift
guard wSum > 0 else { continue }
```

Wenn ein Frame alle Metrik-Z-Scores als nil hat (alle Werte im Cleaned-Array nil, weil alle in `cleanXxxValues` → nil oder weil der Frame als Dark-Frame pre-pass erkannt UND nicht per Rule 0/0b garbage markiert wurde — was eigentlich nicht vorkommen sollte), wird `continue` ausgeführt ohne `result[url]` zu setzen.

Das Frame fehlt danach komplett im result-Dict. Downstream:
- Stage 1.5 (Zeile 1667): `guard let bd = result[entry.url] else { continue }` → übersprungen.
- Stage 1.5b (Zeile 1411): analog.
- Stage 4: analog.
- UI / FileListView: zeigt vermutlich kein Quality-Icon.

**Warum potentiell problematisch:** Frames verschwinden "silent". Keine Telemetrie, kein Tier, kein Grund sichtbar.

**Verifikation:** Upstream-Guard bei Zeile 539 (`if entry.noiseMAD == nil && entry.computedStarCount == nil { continue }`) sollte die meisten Fälle abfangen. Aber: ein Frame mit noiseMAD aber ohne FWHM, HFR, PSF, Stars, Trailing (z.B. Messung teilweise gelaufen) würde trotzdem hier landen.

**Fragen an Joerg:** Soll ein solcher Frame `.uncertain` mit explizitem "unmeasured" Reasoning bekommen?

---

## FINDING-06 [P2] `severeFwhmMultiplier = fwhmSanityMultiplier + 0.1` — Single-Flag-Demote-Grenze sehr niedrig

**Ort:** Zeile 1661 (Definition) und Zeile 1721–1726 (Verwendung).

**Beobachtung:**
```swift
let severeFwhmMultiplier = fwhmSanityMultiplier + 0.1
// für Galaxien: fwhmSanityMultiplier = 1.3 → severe = 1.4
// für Emissionsnebel: 1.6 → severe = 1.7
```

Der Single-Flag-Severe-Demote-Pfad:
```swift
guard flags.count >= 2 || (flags.count >= 1 && isSevereOutlier) else { continue }
```

Bedeutet: ein Frame mit FWHM > 1.4× des besten Dezils der Pool-Stichprobe wird allein durch FWHM auf Trash demoted, solange irgendein Flag gesetzt ist (der FWHM-Flag selbst reicht schon — er feuert ab 1.3× P10).

**Warum potentiell problematisch:** 1.4× vom besten Dezil ist nicht unbedingt "severe". Bei gutem Seeing-Block mit P10=2.0" würde ein Frame mit FWHM=2.8" (völlig durchschnittliches Seeing) auf Trash landen. Die intuitive Bedeutung von "severe" wäre eher 1.8×–2.0× P10.

**Kontext-Frage:** War das empirisch kalibriert, oder ist +0.1 ein Workaround aus einem konkreten Incident? Falls Letzteres — welcher Incident?

**Verifikation:** Benchmark-Dataset durchlaufen lassen, False-Positive-Rate bei verschiedenen Multiplier-Werten messen.

---

## FINDING-07 [P2] Rule 7b `starCountDrop` ist bei bimodalen Gruppen (`starWeight == 0`) deaktiviert

**Ort:** Zeile 749.

**Beobachtung:**
```swift
if starWeight > 0, let stars = starsValues[localIdx], let median = starsMedian,
   indices.count >= 8, median > 20 {
    // ... atmospheric attenuation detection
}
```

Die CV-Check (Zeile 480–488) setzt `starWeight = 0` wenn `stddev/mean > 1.0` — also in Gruppen mit extrem heterogenen Sternzahlen (Galaxien, Nebel). Rule 7b wird damit nicht ausgeführt.

**Warum potentiell problematisch:** Rule 7b ist der Cross-Check für "dünne Wolken / Dew / Fog" — genau bei Galaxien-/Nebel-Sessions tritt das auf. Rule 1c (P90 Floor) fängt einen Teil ab, aber ohne den FWHM-OK + SNR-Drop Cross-Check.

**Kontext-Frage:** War das bewusst deaktiviert um False-Positives zu vermeiden, oder übersehen? Die Rule 7b-Implementierung enthält bereits einen FWHM-Plausibilitäts-Check — der sollte eigentlich auch bei bimodalen Gruppen robust sein.

**Fix-Idee:** Den `starWeight > 0` Guard entfernen und stattdessen den FWHM-Plausibilitäts-Check strenger machen.

---

## FINDING-08 [P2] Stage 3 Rule A rettet ohne Sternzahl-/PSF-Flux-Check — Rule B unerreichbar

**Ort:** Zeilen 963–971.

**Beobachtung:**
```swift
// Rule A
if fwhmOK && noiseOK && trailingOK {
    tier = .good
    rescueReason = "FWHM and noise within group norm"
}
// Rule B
else if starsLow && fwhmOK && trailingOK {
    tier = .good
    rescueReason = "Star count dip with normal FWHM — likely transient event"
}
```

Rule A feuert wenn FWHM OK, Noise OK, Trailing OK — ignoriert aber Sternzahl und PSF Flux. Ein Frame mit katastrophaler Sternzahl (dünne Wolke) aber sonst allem OK wird zu Good gerettet. Rule B (die explizit für "Star count dip" da ist) wird nie erreicht wenn Rule A greift, weil `else if`.

**Warum potentiell problematisch:** Die Semantik "fundamentally sound = FWHM + Noise + Trailing alle OK" ignoriert dass ein Frame mit 20% der normalen Sternzahl trotzdem stark attenuiert ist (Photon-Throughput sinkt) — die SNR-Contribution-Anzeige wird dafür bestraft, aber der Tier lügt.

**Fix-Idee:** Rule A sollte zusätzlich `!starsLow` (oder `psfFluxZ > -1.0`) verlangen. Dann kann Rule B greifen wenn Stars low aber FWHM gut.

---

## FINDING-09 [P2] `medianAbsoluteDeviation()` normalisiert NICHT mit 1.4826, `zscores()` tut es — Inkonsistenz

**Ort:** `medianAbsoluteDeviation()` Zeilen 1858–1863. `zscores()` Zeile 1820 (mit `* 1.4826`).

**Beobachtung:**
```swift
// zscores() Zeile 1820
let rawMAD = deviations[deviations.count / 2] * 1.4826  // normalized MAD → σ estimate

// medianAbsoluteDeviation() Zeile 1862
return deviations[deviations.count / 2]  // raw MAD, NICHT normalized
```

Rule 8 (Background Anomaly, Zeile 769–787) nutzt `medianAbsoluteDeviation()` und vergleicht:
```swift
let deviation = (bg - median) / mad
if deviation > bgThreshold { ... }  // bgThreshold beginnt bei 5.0
```

Roher 5-MAD-Threshold entspricht bei normalverteilten Daten ≈ 7.4σ.

**Zwei mögliche Interpretationen:**
1. Threshold wurde empirisch auf rohen MADs kalibriert — funktioniert, ist nur irreführend benannt. Dann Kommentar ergänzen: `// threshold in raw MAD units, NOT σ`.
2. Threshold wurde als "σ-Äquivalent" gedacht und ist damit zu konservativ — False Negatives bei Wolken/Gradienten. Dann entweder `mad *= 1.4826` oder Threshold auf ~3.3 reduzieren.

**Verifikation gegen Kurationsdaten:** Wie viele echte Background-Anomalien werden von Rule 8 aktuell erkannt vs. von anderen Rules aufgefangen? Falls Rule 8 selten feuert — ist es vermutlich zu konservativ.

---

## FINDING-10 [P3] `garbagePercentile` ist deklariert aber unbenutzt

**Ort:** Zeile 207.

**Beobachtung:**
```swift
// Stage 1: absolute garbage detection thresholds (percentile of group)
// If a metric is below this percentile of the group, it's garbage regardless of other metrics
static let garbagePercentile: Double = 0.10  // Bottom 10% is suspicious
```

`grep -rn "garbagePercentile" --include="*.swift"` zeigt **eine einzige** Reference (die Deklaration selbst). Weder in QualityEstimator.swift noch anderswo wird die Konstante gelesen.

**Zwei mögliche Interpretationen:**
1. Geplante Regel wurde nie implementiert — die Beschreibung im Kommentar passt zu Rule 1c (P90 floor), könnte also die ursprüngliche Idee gewesen sein.
2. Refactoring-Überbleibsel — eine frühere Version nutzte das, die aktuellen Rules nutzen `garbageDropFactor` stattdessen.

**Fix-Vorschlag:** Löschen (mit Commit-Message-Link zum Current-Behavior-Docs falls vorhanden). Kein Funktionsverlust.

---

## Zusätzliche Verifikations-Schritte (übergreifend)

1. **Test-Suite durchlaufen:**
   ```
   xcodebuild test -scheme AstroTriage -destination 'platform=macOS'
   ```
   Vor jeder Änderung grün, nach jeder Änderung grün.

2. **Kurations-Dataset prüfen:** Joerg referenzierte im Code ein "4550-frame curation" Dataset (siehe Zeilen 191–198, 792–797). Falls dieses Dataset verfügbar ist — alle Finding-betreffenden Thresholds vor/nach Fix messen (False-Positive-Rate, False-Negative-Rate).

3. **Diagnostic-Log prüfen:** Stage 1.5b schreibt nach `Application Support/AstroBlinkV2/stage15b_diag.txt` (Zeile 1231–1244). Das Log enthält per-Frame FWHM-Dev, Trail-Dev, Ecc, Flag-Count. Nach Fix für FINDING-01: prüfen dass demote-Counts nicht einbrechen (würde bedeuten dass Stage 4 viele davon zuvor gerettet hat).

4. **Ausführungsreihenfolge dokumentieren:** Im Datei-Header-Kommentar der QualityEstimator.swift fehlt eine klare Angabe der tatsächlichen Stage-Reihenfolge. Der aktuelle Header-Kommentar (Zeilen 4–7) erwähnt nur Stages 1, 1.5, 2. Stage 3, 1.5b und 4 fehlen komplett. Vorschlag: am Anfang der Datei einen vollständigen Stage-Ablauf als Kommentar einfügen.

## Out-of-Scope für diese Prüfung

- Die Metrik-Computation selbst (FWHM, HFR, Trailing, etc. — in `StarMetricsCalculator`, `StarDetector`).
- `CalibrationDatabase.meetsAbsoluteFloor()` — Lock-Logik.
- `CommunityDetectionService.meetsCommunityFloor()`.
- UI-Darstellung der Tiers.
- Autopilot-Button-Semantik (Conservative/Balanced/Aggressive).

Falls der prüfende Prozess bei der Verifikation auf Bugs in diesen Bereichen stößt — bitte notieren, aber nicht in diesem Durchgang fixen.
