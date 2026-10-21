# Janek — polski asystent głosowy dla iPhone 17 Pro (iOS 27)

Siri wciąż nie mówi po polsku, więc **Janek** wypełnia tę lukę: reaguje na frazę **„Hej Janek”**,
słucha polecenia po polsku i wykonuje je na telefonie — jak Siri. Polecenia rozumie model językowy:
**na telefonie** (Apple Intelligence albo pobrany model open source — Qwen3, Bielik, Gemma) i/lub
**Claude** (Anthropic) na **Twoim własnym kluczu API** — patrz rozdział 7. Wszystko inne (nasłuch
frazy, rozpoznawanie mowy, synteza głosu, notatki, ustawienia, dane zdrowotne) działa na urządzeniu.

Projekt powstał na podstawie analizy możliwości aplikacji *Mimi* (App Store) i odwzorowuje jej
zakres funkcji.

```
Janek/
├── Janek.xcodeproj           ← otwórz w Xcode 27
├── Config/                   Info.plist, uprawnienia (entitlements)
├── Janek/
│   ├── App/                  punkt wejścia SwiftUI
│   ├── Core/                 AssistantController (maszyna stanów), daty, normalizacja tekstu
│   ├── Speech/               „Hej Janek”, rozpoznawanie mowy pl-PL, synteza mowy, sesja audio
│   ├── AI/                   klient Messages API, pętla agenta z narzędziami, prompt systemowy
│   │   └── Local/            modele na telefonie: router poleceń, Apple Foundation Models, MLX
│   ├── Tools/                33 narzędzia (kalendarz, telefon, mapy, notatki, alarmy, …)
│   ├── Storage/              pęk kluczy (klucz API), ustawienia, baza notatek SwiftData
│   ├── UI/                   ekran główny, onboarding, ustawienia, notatki, arkusze
│   ├── CarPlay/              scena CarPlay (szablon głosowy)
│   ├── Intents/              App Intents: przycisk Czynności, Skróty, Spotlight
│   ├── Resources/Sounds/     dźwięki alarmów i sygnałów
│   └── Assets.xcassets       ikona, kolor akcentu
├── JanekTests/               testy (Swift Testing)
└── Tools/generate_assets.py  generator ikony i dźwięków
```

---

## 1. Uruchomienie

Wymagania: **Xcode 27** (iOS 27 SDK), iPhone z iOS 27 (projekt jest ustawiony na iPhone 17 Pro,
działa na każdym iPhonie z iOS 27), konto Apple Developer i **klucz API Anthropic**.

1. Otwórz `Janek/Janek.xcodeproj`.
2. Target **Janek** → *Signing & Capabilities* → wybierz swój **Team**. Zmień
   *Bundle Identifier* (`pl.janek.assistant`) na własny, np. `com.twojanazwa.janek`.
3. Podłącz iPhone'a, wybierz go jako cel i naciśnij **⌘R**.
4. Przy pierwszym uruchomieniu wklej klucz API (utworzysz go na
   [console.anthropic.com](https://console.anthropic.com/settings/keys)) i nadaj uprawnienia
   mikrofonu oraz rozpoznawania mowy.
5. Powiedz **„Hej Janek, która godzina?”**.

> Symulator nie ma prawdziwego mikrofonu i rozpoznawania mowy na urządzeniu — testuj na iPhonie.
> W symulatorze możesz wpisywać polecenia w polu tekstowym.

### Uprawnienia (capabilities)

| Capability | Gdzie | Uwagi |
|---|---|---|
| **HealthKit** | `Config/Janek.entitlements` (już ustawione) | Wymaga płatnego konta Apple Developer. Na darmowym koncie (*Personal Team*) usuń klucze HealthKit z pliku entitlements — narzędzia zdrowia zgłoszą wtedy niedostępność. |
| **Background Modes → Audio** | `Info.plist` (już ustawione) | Nasłuch „Hej Janek” przy zablokowanym ekranie. |
| **MusicKit** | App ID w portalu Apple Developer → *App Services* → MusicKit | Tylko do wyszukiwania w katalogu Apple Music; biblioteka lokalna działa bez tego. |
| **CarPlay** | `Config/Janek-CarPlay.entitlements` | Wymaga zgody Apple — patrz rozdział 5. |
| **Increased Memory Limit** | `Config/Janek.entitlements` (już ustawione) | Pozwala wczytać model lokalny (2–4 GB). Na darmowym koncie usuń ten klucz — wtedy używaj mniejszego modelu (Qwen3 4B) albo tylko Claude. |

Pakiety Swift (Xcode pobierze je sam przy pierwszym otwarciu — *File → Packages → Resolve Package
Versions*, jeśli nie): [`mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm) 3.32.x,
[`swift-huggingface`](https://github.com/huggingface/swift-huggingface),
[`swift-transformers`](https://github.com/huggingface/swift-transformers).

---

## 2. Co potrafi

| Obszar | Przykładowe polecenia | Realizacja na iOS |
|---|---|---|
| **Kalendarz i przypomnienia** | „Zapisz spotkanie z Anią w przyszły wtorek o dziesiątej”, „Przesuń dentystę na czwartek”, „Co mam jutro?”, „Odwołaj spotkanie z Tomkiem” | EventKit (`EKEvent`, `EKReminder`). Wyrażenia „w przyszły wtorek”, „za dwie godziny”, „jutro rano” rozwiązuje Claude na podstawie bieżącej daty dołączanej do każdego polecenia. |
| **Telefon i wiadomości** | „Zadzwoń do mamy”, „Napisz do Tomka na WhatsAppie, że będę o ósmej”, „Wyślij SMS do Kasi…” | Numer znajdowany lokalnie w Kontaktach (z obsługą polskiej odmiany: „do Ani” → „Ania”). `tel://`, `facetime://`, `MFMessageComposeViewController`, `wa.me`, `tg://`, `sgnl://`. |
| **Nawigacja i miejsca** | „Prowadź do Rynku w Krakowie”, „Gdzie jest najbliższa apteka?”, „Gdzie jestem?” | MapKit (`MKLocalSearch`, `openInMaps`), CoreLocation; opcjonalnie Google Maps/Waze. |
| **Notatki** | „Zanotuj…”, „Dopisz mleko do listy zakupów”, „Przeczytaj notatkę o urlopie” | Własna baza SwiftData na urządzeniu; treść czytana lokalnie. |
| **Timery i budziki** | „Minutnik na 12 minut”, „Obudź mnie jutro o 6:30”, „Przypominaj o lekach o 8 i 20” | **AlarmKit** (dzwoni mimo trybu cichego i skupienia) z własnymi dźwiękami; zapasowo powiadomienia lokalne *time-sensitive*. |
| **Kontakty** | „Jaki jest numer do Pawła?”, „Dodaj kontakt…”, „Zmień numer Kasi na…” | Contacts (`CNContactStore`, `CNSaveRequest`). Numery czytane lokalnie. |
| **Muzyka** | „Włącz Dawida Podsiadło”, „Następny utwór”, „Pauza” | MediaPlayer (biblioteka), MusicKit (katalog Apple Music). |
| **Zdrowie i aktywność** | „Ile kroków dziś zrobiłem?”, „Jaki mam puls?”, „Zacznij trening biegowy” | HealthKit (`HKStatisticsQueryDescriptor`, `HKWorkoutBuilder`). **Dane zdrowotne nie opuszczają telefonu** — patrz rozdział 4. |
| **Zdjęcia i dokumenty** | „Zrób zdjęcie”, „Zrób PDF z listą rzeczy na wyjazd”, „Utwórz plik tekstowy…” | Aparat (`UIImagePickerController`), PDF (`UIGraphicsPDFRenderer`), pliki w *Pliki → Na moim iPhonie → Janek*. |
| **Aplikacje i skróty** | „Otwórz Spotify”, „Uruchom skrót Dobranoc” | Schematy URL znanych aplikacji, `shortcuts://run-shortcut`. Skróty dają dostęp do HomeKit, e-maila i wszystkiego, co potrafią Skróty. |
| **Pytania ogólne** | „Jaka jutro pogoda w Gdańsku?”, „Ile to 15% z 240?” | Wiedza modelu + narzędzie `web_search` (wyłączane w ustawieniach). |
| **W samochodzie** | „Hej Janek…” bez dotykania telefonu | Scena CarPlay z `CPVoiceControlTemplate`, dźwięk przez głośniki auta. |

---

## 3. Jak to działa

```
 mikrofon ─► AVAudioEngine ─► SFSpeechRecognizer (pl-PL, na urządzeniu)
                                  │ transkrypcje częściowe
                                  ▼
                        WakeWordDetector  „hej janek / hey janek / hej janku / hejjanek…”
                                  │ wykryto → sygnał dźwiękowy + haptyka
                                  ▼
                 nasłuch polecenia (koniec po ~1,3 s ciszy)
                                  │ tekst polecenia
                                  ▼
 ConversationAgent ─► Claude Messages API (narzędzia, prompt cache, fallback)
        ▲    │ tool_use
        │    ▼
        │  ToolRegistry ─► EventKit / Contacts / MapKit / AlarmKit / HealthKit / …
        │    │ tool_result (dane prywatne → czytane lokalnie, do modelu tylko potwierdzenie)
        └────┘
                                  │ odpowiedź tekstowa
                                  ▼
                 AVSpeechSynthesizer (głos pl-PL, ściszanie muzyki) ─► znów „Hej Janek”
```

* **Słowo kluczowe.** iOS nie udostępnia aplikacjom własnych słów-kluczy na poziomie systemu
  (jak „Hej Siri”), więc Janek prowadzi ciągłe rozpoznawanie mowy na urządzeniu
  (`requiresOnDeviceRecognition`) i szuka frazy w transkrypcji — z tolerancją błędów
  (odległość Levenshteina, odmiana „Janku”, sklejenia „hejjanek”). Czułość ustawisz w aplikacji.
  Żądanie rozpoznawania jest restartowane co 50 s (limit długości), a po frazie zaczyna się nowe
  żądanie w trybie dyktowania z interpunkcją. Można też powiedzieć wszystko jednym tchem:
  „Hej Janek, zadzwoń do mamy”.
* **Dopytywanie.** Gdy odpowiedź Janka kończy się pytajnikiem, od razu słucha odpowiedzi — bez
  ponownego „Hej Janek”. Kontekst rozmowy trwa 3 minuty.
* **Model.** Domyślnie `claude-opus-5-5` z niskim poziomem *effort* (szybkie odpowiedzi głosowe);
  w ustawieniach możesz wybrać Sonnet 5.5 lub Haiku 5.5 (najtańszy). Stały prompt systemowy i
  definicje narzędzi są cache'owane (`cache_control`), a bieżąca data trafia do wiadomości
  użytkownika, żeby nie unieważniać cache. Włączony jest `fallbacks: "default"`
  (`server-side-fallback-2026-07-01`) — gdy klasyfikator bezpieczeństwa odrzuci zapytanie, serwer
  sam ponowi je na odpowiednim modelu. Historia rozmowy jest tylko dopisywana (bloki `thinking`
  odsyłane bez zmian).

### Tryb w tle, przycisk Czynności i ograniczenia iOS

* **W tle** nasłuch działa dzięki trybowi audio (iOS pokazuje pomarańczową kropkę). Gdy aplikacja
  zostanie **zamknięta z przełącznika aplikacji**, iOS jej nie wznowi — wtedy użyj:
  * **przycisku Czynności** (iPhone 17 Pro): *Ustawienia → Przycisk Czynności → Skrót →
    „Hej Janek”*,
  * skrótu „Hej Janek” / „Zapytaj Janka” w Skrótach, Spotlight lub na ekranie blokady.
* **SMS/WhatsApp:** iOS nie pozwala aplikacjom wysyłać wiadomości bez potwierdzenia — Janek
  przygotowuje wiadomość, a Ty naciskasz *Wyślij* (w CarPlay służy do tego interfejs auta).
* **Połączenia:** iOS może poprosić o potwierdzenie numeru przed nawiązaniem połączenia.
* **Aparat** wymaga, by Janek był na ekranie.

---

## 4. Prywatność

* Bez konta, bez rejestracji, bez serwera pośredniczącego — aplikacja łączy się tylko z
  `api.anthropic.com`, na Twoim kluczu.
* Klucz API: pęk kluczy iOS, `ThisDeviceOnly` (bez synchronizacji iCloud).
* Nasłuch „Hej Janek” i rozpoznawanie mowy: na urządzeniu.
* Do Anthropic trafia transkrypcja polecenia i to, czego model potrzebuje (np. tytuły wydarzeń
  z kalendarza, nazwy miejsc).
* **Nie** trafiają do Anthropic: numery telefonów i adresy kontaktów, treść notatek, dane
  zdrowotne — te narzędzia czytają wynik lokalnie syntezatorem mowy i odsyłają modelowi tylko
  potwierdzenie (`ToolOutput.privateReadout`).

---

## 5. CarPlay

Kod sceny CarPlay jest gotowy (`CarPlay/CarPlaySceneDelegate.swift`, wpis w `Info.plist`), ale
aplikacje CarPlay wymagają **uprawnienia przyznawanego przez Apple**:

1. Złóż wniosek: <https://developer.apple.com/carplay/> → *Request CarPlay entitlement*,
   kategoria **Voice-based conversation**.
2. Po akceptacji dodaj uprawnienie do App ID i wygeneruj profil.
3. W ustawieniach targetu zmień `CODE_SIGN_ENTITLEMENTS` na `Config/Janek-CarPlay.entitlements`.
4. Testuj w symulatorze CarPlay (*Xcode → Open Developer Tool → Simulator → I/O → External
   Displays → CarPlay*) albo w aucie.

Bez uprawnienia aplikacja działa normalnie na iPhonie, a scena CarPlay po prostu się nie pojawi.

---

## 6. Rozwijanie

* **Nowe narzędzie:** utwórz strukturę zgodną z `AssistantTool` w `Janek/Tools/` (nazwa, opis po
  polsku, schemat JSON wejścia, `run`) i dopisz ją do `ToolRegistry.tools`. Opis narzędzia jest
  instrukcją dla modelu — pisz go jak dla nowego współpracownika.
* **Dane prywatne:** zwracaj `.privateReadout(…)`, aby wynik przeczytać lokalnie.
* **Inne słowo kluczowe:** `WakeWordDetector` (`name`, `nameForms`, `greetings`) oraz
  `contextualStrings` w `SpeechListener`.
* **Dźwięki/ikona:** `python3 Tools/generate_assets.py`.
* **Testy:** ⌘U (detektor frazy, normalizacja tekstu, daty, budowanie zapytań do API).

---

## 7. Model na telefonie zamiast (albo obok) Claude

*Ustawienia → Model na telefonie* — trzy tryby:

| Tryb | Jak działa | Klucz API |
|---|---|---|
| **Hybrydowy** (domyślny) | Model na telefonie próbuje obsłużyć polecenie. Gdy nie jest pewien, polecenie jest złożone, to pytanie o wiedzę albo ekran jest zablokowany — przejmuje Claude. | zalecany |
| **Tylko Claude** | Jak w wersji 1.0. | wymagany |
| **Tylko na telefonie** | Zero tokenów, działa offline. Tylko proste polecenia. | niepotrzebny |

**Silniki lokalne**

* **Apple Intelligence** (framework Foundation Models) — wbudowany w iOS, generowanie z wymuszoną
  strukturą (`@Generable`, nazwa narzędzia ograniczona do znanych wartości). Gdy iOS zgłosi
  obsługę polskiego (`supportsLocale(pl_PL)`), tryb automatyczny wybierze go sam.
* **MLX** — modele open source pobierane z Hugging Face w aplikacji:
  * **Qwen3 4B** (`mlx-community/Qwen3-4B-4bit`, ≈2,3 GB) — domyślny, najpewniejszy JSON,
  * **Bielik 4.5B v3** (`futurist-ai/Bielik-4.5B-v3.0-Instruct-MLX-4bit`, ≈3 GB) — polski model SpeakLeash,
  * **Gemma 3n E4B** (`mlx-community/gemma-3n-E4B-it-lm-4bit`, ≈3,9 GB).

**Co obsługuje model lokalny** (`LocalCommandRouter.specs`): minutniki, budziki, muzykę, połączenia,
wiadomości, notatki, przypomnienia, nowe wydarzenia w kalendarzu, nawigację, kontakty, zdrowie,
trening, aplikacje i skróty. Przesuwanie/odwoływanie spotkań, plan dnia, pytania ogólne i
rozmowa zawsze idą do Claude.

**Jak to działa:** mały model dostaje zwięzły prompt (lista 18 narzędzi, tabela najbliższych dni z
datami, przykłady) i zwraca jeden obiekt JSON `{"tool": …, "args": …}`. Aplikacja go
**waliduje** (znane narzędzie, wymagane argumenty, poprawne daty w przyszłości, sensowne wartości) —
każda wątpliwość oznacza przekazanie do Claude. Potwierdzenie głosowe („Minutnik na 10 minut.”)
powstaje z szablonu z poprawną polską odmianą, a nie z modelu.

**Ograniczenia**

* iOS nie pozwala używać GPU w tle, więc **modele MLX działają tylko przy otwartej aplikacji**.
  Przy zablokowanym ekranie (i w CarPlay) w trybie hybrydowym polecenie przejmuje Claude, a model
  jest zwalniany z pamięci. Apple Intelligence nie ma tego ograniczenia.
* Pierwsze polecenie po uruchomieniu czeka kilka sekund na wczytanie modelu (aplikacja wczytuje go
  z wyprzedzeniem, gdy wraca na ekran). Potem odpowiedź trwa zwykle 1–3 s.
* Model lokalny nie zna rozmowy z Claude — gdy Claude o coś dopytał, odpowiedź wraca do Claude.
* MLX nie działa w symulatorze — testuj na iPhonie.
