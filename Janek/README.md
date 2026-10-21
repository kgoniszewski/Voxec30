# Janek — polski asystent głosowy dla iPhone 17 Pro (iOS 27)

Siri wciąż nie mówi po polsku, więc **Janek** wypełnia tę lukę: reaguje na frazę **„Hej Janek”**,
słucha polecenia po polsku i wykonuje je na telefonie — jak Siri. Polecenia rozumie model językowy
**Claude** (Anthropic) na **Twoim własnym kluczu API**; wszystko inne (nasłuch frazy, rozpoznawanie
mowy, synteza głosu, notatki, ustawienia, dane zdrowotne) działa na urządzeniu.

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
