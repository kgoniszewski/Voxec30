# Voxec30 — symulacja Vox AC30 Top Boost dla iPad Pro (M2)

Samodzielna aplikacja (JUCE **Standalone**, bez AU/VST3) dla iPadOS 27, modelująca obwód
wzmacniacza **Vox AC30 z kanałem Top Boost**: przedwzmacniacz ECC83, pasywny filtr
Treble/Bass, odwracacz fazy, końcówkę mocy 4×EL84 (push-pull, klasa AB, bias katodowy,
**bez sprzężenia zwrotnego**), prostownik lampowy GZ34 (sag) oraz kolumnę 2×12 (konwolucja IR).
Wejście i wyjście są mono, przygotowane pod interfejs **IK Multimedia AXE I/O One**.

* JUCE **9.0.3** (pobierane automatycznie przez CMake `FetchContent`)
* C++20, CMake ≥ 3.25, generator Xcode
* Apple Silicon (arm64), DSP kompilowane z `-O3 -mcpu=apple-m1`, Thin LTO w Release
* Ścieżka audio w 100% lock-free, wszystkie nieliniowości w 4× oversamplingu

---

## 1. Szybki start: wygenerowanie projektu Xcode (macOS 27 + Xcode 27)

Wymagania: macOS 27, Xcode 27 (z iPadOS 27 SDK), CMake ≥ 3.25 (`brew install cmake`),
git oraz konto Apple Developer (do podpisania aplikacji na fizycznym iPadzie).

```bash
git clone https://github.com/kgoniszewski/Voxec30.git
cd Voxec30

# (jeśli macOS ma kilka wersji Xcode)
sudo xcode-select -s /Applications/Xcode.app

# Wygenerowanie projektu Xcode dla iPadOS (JUCE 9.0.3 zostanie pobrane automatycznie)
cmake -S . -B build-ios -G Xcode \
      -DCMAKE_SYSTEM_NAME=iOS \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 \
      -DCMAKE_XCODE_ATTRIBUTE_DEVELOPMENT_TEAM=ABCDE12345     # <- Twój Team ID

# Otwarcie w Xcode 27
open build-ios/VoxAC30.xcodeproj
```

Team ID znajdziesz w Xcode → *Settings… → Accounts* (lub na developer.apple.com → *Membership*).

W Xcode:

1. Wybierz schemat **`VoxAC30_Standalone`** (nie `VoxAC30` — to tylko biblioteka ze współdzielonym kodem).
2. Jako urządzenie docelowe wybierz swojego **iPada Pro** (podłączonego kablem lub przez sieć).
3. *Product → Scheme → Edit Scheme… → Run → Build Configuration* ustaw na **Release**
   (Debug też działa — źródła DSP i tak kompilują się z `-O3`, patrz `VOX_DSP_ALWAYS_O3`).
4. Jeśli Xcode zgłosi problem z podpisem: zakładka *Signing & Capabilities* targetu
   `VoxAC30_Standalone` → zaznacz *Automatically manage signing* i wybierz swój zespół.
   Bundle ID można zmienić w `CMakeLists.txt` (`BUNDLE_ID`).
5. **⌘R** — budowanie i uruchomienie na iPadzie.

Budowanie z wiersza poleceń (bez otwierania Xcode):

```bash
cmake --build build-ios --config Release --target VoxAC30_Standalone -- -allowProvisioningUpdates
# lub:
xcodebuild -project build-ios/VoxAC30.xcodeproj -scheme VoxAC30_Standalone \
           -configuration Release -destination 'generic/platform=iOS' -allowProvisioningUpdates
```

Opcje CMake:

| Opcja | Domyślnie | Znaczenie |
|---|---|---|
| `VOX_JUCE_PATH` | *(puste)* | ścieżka do lokalnej kopii JUCE 9.0.3 zamiast pobierania |
| `VOX_DSP_ALWAYS_O3` | `ON` | źródła DSP zawsze z `-O3` (płynne audio także w Debug) |
| `VOX_BUILD_TESTS` | `OFF` | test offline DSP (tylko desktop) |
| `CMAKE_OSX_DEPLOYMENT_TARGET` | `27.0` | minimalna wersja iPadOS |

---

## 2. Podłączenie AXE I/O One

1. Podłącz AXE I/O One do portu USB-C iPada (interfejs jest class-compliant; przy dłuższej grze
   zalecany zasilacz/hub USB-C z Power Delivery).
2. Gitara → wejście **Input 1** (instrumentalne), słuchawki/monitory → **Output 1** (lub para 1/2).
3. Uruchom aplikację i naciśnij **INPUT: MUTED**, aby przełączyć na **INPUT: LIVE**
   (JUCE domyślnie wycisza wejście aplikacji standalone, by uniknąć sprzężenia mikrofon–głośnik iPada).
4. **AUDIO I/O** otwiera ustawienia urządzenia: częstotliwość 48 kHz, bufor 64–128 próbek.
   Aplikacja przy starcie sama ustawia bufor 128, jeśli system zaproponował większy.
5. Ustaw wzmocnienie wejścia w AXE I/O tak, by wskaźnik **IN** przy mocnym uderzeniu
   dochodził do żółtego pola (ok. −12…−6 dBFS). Model zakłada, że 0 dBFS = 1 V szczytowo na siatce V1.

Procesor jest mono: wejście = kanał 1 interfejsu, wyjście = kanał 1 (gdy system otworzy
wyjście stereo, sygnał jest kopiowany na oba kanały — dual-mono).

---

## 3. Interfejs użytkownika

Wektorowy, responsywny interfejs dla orientacji poziomej (11" i 13", także Split View / Stage Manager):

* **VOLUME** – głośność kanału Top Boost (potencjometr logarytmiczny przed lampą mieszającą V3),
* **TREBLE**, **BASS** – interaktywny pasywny filtr Top Boost,
* **CUT** – Tone Cut, działa **odwrotnie** jak w oryginale: obrót w prawo = ciemniej
  (mniejsza rezystancja w gałęzi RC między anodami odwracacza fazy),
* **MASTER** – głośność główna (przed odwracaczem fazy, jak w AC30CC/C2),
* **CAB** – włącza/wyłącza konwolucję kolumny (wyłączone = sygnał „line out” końcówki),
* **LOAD IR** / **DEFAULT IR** – wczytanie własnej odpowiedzi impulsowej (WAV/AIFF/CAF/FLAC) /
  powrót do wbudowanej. Wczytane IR są kopiowane do *Dokumenty/VoxAC30 IR* aplikacji
  (widoczne w aplikacji Pliki) i przywracane po ponownym uruchomieniu,
* wskaźniki IN/OUT, lampka „jewel” reagująca na poziom wyjściowy.

Pokrętła obsługuje się przeciągnięciem palca w pionie/poziomie; podwójne stuknięcie przywraca wartość domyślną.
Wszystkie parametry są w `juce::AudioProcessorValueTreeState`, a stan jest zapisywany automatycznie.

---

## 4. Architektura DSP

```
             ┌──────────────────────────── 4× oversampling (IIR half-band, polyphase) ───────────────────────────┐
 Input 1 ─DC─┤ V1 ECC83 ─ V2a ECC83 ─ V2b CF ─ Top Boost TS ─ VOLUME ─ V3 ECC83 ─ MASTER ─ PI LTP ─ CUT ─ 4×EL84 PP ├─ OT/głośnik ─ IR 2×12 ─ Out
             │      ▲          ▲                                  ▲                          ▲                    │ ▲      │
             │      └──────────┴──────── zasilanie przedwzmacniacza (filtrowane) ◄───────────┴──── GZ34 + C ◄────┘ │      │
             └───────────────────────────────────────────────────────────────────────────────────────────────────┘
```

| Blok | Plik | Model |
|---|---|---|
| a) Preamp 12AX7 | `Source/dsp/TriodeModel.*` | Równania triody **Korena** (12AX7: μ=100, Ex=1.4, Kg1=1060, Kp=600, Kvb=300). Prosta obciążenia `Vp = B+ − Rp·Ip(Vgk, Vpk)` rozwiązywana **offline** (bisekcja, gwarantowana zbieżność) do tablicy 4096 punktów → w wątku audio tylko interpolacja. Dynamika: napięcie katody `Vk` śledzi prąd z ‑stałą `Rk·Ck` (kompresja, przesunięcie biasu), **prąd siatki** (miękka dioda + rezystor „grid stopper”) ładuje kondensator sprzęgający → *blocking distortion*. Sag zasilania przez skalowanie napięciowe charakterystyki. |
| b) Top Boost Tone Stack | `Source/dsp/TopBoostToneStack.*` | Dokładna funkcja przenoszenia 3. rzędu pasywnej drabinki TMB (Yeh & Smith, DAFx‑06) z wartościami AC30 TB: 50 pF, 2×22 nF, potencjometry 1 MΩ (log), 100 kΩ, **stały 10 kΩ zamiast potencjometru Middle**. Biliniowa dyskretyzacja przy 192 kHz, TDF‑II w podwójnej precyzji, współczynniki liczone tylko przy zmianie pokręteł. |
| c) Phase Inverter + Power Amp | `Source/dsp/AC30Circuit.cpp`, `Source/dsp/PowerAmpEL84.*` | PI: para długoogonowa (tanh z prądu ogona, niesymetryczne obciążenia 82k/100k → parzyste harmoniczne). **Tone Cut** jako półka RC między anodami PI. Końcówka: 2×2 EL84 (pentoda w stylu Korena dopasowana do ~47 mA spoczynkowo), **wspólny rezystor katodowy 50 Ω/250 µF** – dynamiczne przesunięcie biasu i zniekształcenia skrośne klasy AB, prąd siatek mocy (blocking), ograniczenie wychylenia anody przez chwilowe B+ minus napięcie „kolana”. **Brak globalnego NFB** → wysoka impedancja wyjściowa: rezonans głośnika (~95 Hz) i podbicie wysokich od indukcyjności cewki. |
| d) Zasilacz GZ34 | `Source/dsp/PowerSupplyGZ34.h` | Dioda próżniowa (prawo Childa‑Langmuira: R zależne od prądu) + uzwojenie + kondensator 32 µF. Prostownik tylko **ładuje** kondensator → asymetryczny atak/powrót („oddychanie”). Prąd obciążenia = rzeczywisty prąd katod EL84 + siatek ekranujących + przedwzmacniacz. Osobny, wolniejszy (RC 60 ms) współczynnik dla szyn przedwzmacniacza. |
| e) Kolumna (IR) | `Source/dsp/CabinetIR.*` | `juce::dsp::Convolution` (NonUniform, head 256 → **zero dodatkowej latencji**), mono, trim + normalizacja. Ładowanie IR wyłącznie w wątku komunikatów — silnik JUCE przekazuje je do wątku audio przez kolejkę lock‑free z przenikaniem. |
| Oversampling | `Source/dsp/AC30Circuit.*` | `juce::dsp::Oversampling<float>` 4× (2 stopnie, polifazowe IIR half‑band, max quality, latencja całkowita) obejmuje **wszystkie** sekcje nieliniowe i sag. |

### Zasady real-time (lock-free)

* Parametry czytane z `std::atomic<float>*` (`getRawParameterValue`) raz na blok; wygładzanie
  własne (rampy co 32 próbki) — bez zipper noise, bez blokad.
* Cała pamięć (tablice lamp, filtry oversamplingu, bufory) alokowana w `prepareToPlay()`.
* Mierniki: `std::atomic<float>` z `exchange()` w wątku GUI.
* `juce::ScopedNoDenormals` + jawne zerowanie denormali/NaN w stanach IIR; końcowe zabezpieczenie ±1.

Zmierzone na desktopie x86 (test offline): ~9% jednego rdzenia dla toru wzmacniacza 4× OS przy 48 kHz;
M2 ma znacznie więcej zapasu.

---

## 5. Odpowiedź impulsowa Celestion Alnico Blue

`Resources/IR/AlnicoBlue_2x12.wav` jest wbudowywany w aplikację przez `juce_add_binary_data`
(każdy plik `.wav` w `Resources/IR/` jest dołączany automatycznie).

Dołączony plik to **syntetyczne**, minimalnofazowe przybliżenie (generator `Tools/generate_default_ir.py`:
rezonans ~75–110 Hz, wycięcie basu przez otwartą tylną ściankę, „chime” 2,3 kHz i 4 kHz, stromy
spadek powyżej 5,5 kHz, odbicia od tylnej fali i podłogi). Dla autentycznego brzmienia zalecane jest
**zastąpienie go zmierzonym IR** (np. oficjalne IR Celestion „Alnico Blue” w 2×12 open‑back):

* na stałe: podmień `Resources/IR/AlnicoBlue_2x12.wav` (zachowaj nazwę) i ponownie uruchom `cmake`,
* w locie: przycisk **LOAD IR** w aplikacji.

```bash
python3 Tools/generate_default_ir.py   # regeneracja syntetycznego IR (wymaga numpy)
```

---

## 6. Budowanie na desktopie i test offline (opcjonalnie)

Ten sam `CMakeLists.txt` buduje wersję macOS/Linux (wygodne do pracy nad DSP):

```bash
cmake -S . -B build-mac -G Xcode -DVOX_BUILD_TESTS=ON
cmake --build build-mac --config Release --target VoxAC30_Standalone VoxAC30_OfflineTest
./build-mac/VoxAC30_OfflineTest_artefacts/Release/VoxAC30_OfflineTest render.wav
```

Test renderuje syntetyczne szarpnięcia strun i sinus przez cały model dla kilku ustawień, sprawdza
NaN/Inf, DC, poziomy, losową automatyzację pokręteł i podaje THD oraz obciążenie CPU, np.:

```
setting           peak    rms dB        dc     THD%
clean           0.1230    -37.01  -0.00000     2.08
edge            0.4396    -24.50  -0.00000     7.78
crunch          0.6542    -12.74  -0.00002    21.36
cranked         0.6809    -11.13  -0.00003    47.56
```

---

## 7. Struktura repozytorium

```
CMakeLists.txt                 konfiguracja (iPadOS Standalone, flagi, zasoby, test)
Source/
  PluginProcessor.h/.cpp       VoxAC30Processor (juce::AudioProcessor, APVTS, lock-free processBlock)
  PluginEditor.h/.cpp          VoxAC30Editor (UI dotykowe, IR loader, ustawienia audio)
  Parameters.h                 ID i layout parametrów APVTS
  dsp/DspUtils.h               filtry, rampy, saturatory, potencjometry log
  dsp/TriodeModel.h/.cpp       model Korena + stopień wspólnej katody (12AX7)
  dsp/TopBoostToneStack.h/.cpp filtr Top Boost (3. rząd)
  dsp/PowerAmpEL84.h/.cpp      4×EL84 push-pull klasa AB, bias katodowy, bez NFB
  dsp/PowerSupplyGZ34.h        prostownik GZ34 + sag
  dsp/AC30Circuit.h/.cpp       pełny tor z 4× oversamplingiem
  dsp/CabinetIR.h/.cpp         konwolucja IR
  gui/VoxLookAndFeel.h/.cpp    wektorowe pokrętła „chicken-head”, panel
Resources/IR/                  odpowiedzi impulsowe wbudowywane w aplikację
Tools/generate_default_ir.py   generator syntetycznego IR
Tests/OfflineRenderTest.cpp    test offline DSP
```

---

## 8. Uproszczenia modelu (świadome)

* Stopnie triodowe są modelem **quasi-statycznym** (nieliniowość z tablicy + wolne stany: katoda,
  kondensatory sprzęgające, prąd siatki) zamiast pełnego solwera State‑Space/WDF z pojemnościami
  Millera — to standardowy kompromis jakość/CPU dla urządzeń mobilnych.
* Topologia Top Boost jest odwzorowana równaniem drabinki TMB z wartościami elementów AC30
  (stały rezystor 10 k zamiast Middle); oryginalny układ Voxa różni się nieco okablowaniem
  potencjometru Treble, co daje drobne różnice w interakcji pokręteł.
* Nie modelujemy tętnień sieci 50/100 Hz ani nasycenia rdzenia transformatora wyjściowego.
* Wartości kalibracyjne (dzielniki między stopniami, `inputVoltsPerFullScale`) są w `AC30Circuit.h`.

*Vox, AC30 i Celestion są znakami towarowymi ich właścicieli; projekt jest niezależną symulacją
i nie jest z nimi powiązany.*
