# Janek – notatki z sesji (stan na 2026-10-21)

Plik do wznowienia pracy w nowej sesji: „przeczytaj `Janek/SESSION_NOTES.md` i kontynuuj”.

## Stan repozytorium

- `main` – zawiera PR #1–#4 (aplikacja Janek, tryb lokalny, pierwsza poprawka mikrofonu, ostrzeżenia Xcode).
- `claude/loving-archimedes-7ekz5o` – **niescalone** poprawki (do testu na iPhonie, potem PR do `main`):
  1. przyciski uprawnień pokazują błędy / otwierają Ustawienia; diagnostyka mikrofonu,
  2. brak awarii przy odtwarzaniu silnika audio; koniec pętli błędów rozpoznawania (kAFAssistantErrorDomain 1700),
  3. `AVAudioEngine` tworzony leniwie po włączeniu nagrywania (przyczyna formatu 0 Hz), brak audio przed końcem onboardingu,
  4. brak awarii przy zmianie modelu MLX (limit pamięci podręcznej MLX, szeregowanie wczytywania, kontrola pamięci),
  5. pewne polecenia lokalne: `PolishTimeParser`, kontrola intencji (pytanie nic nie tworzy), `calendar_agenda`,
     generowanie ze schematem (`GeneratedCommand` + `MLXFoundationModels`), nowe modele (Gemma 4 E2B/E4B,
     Qwen3 4B Instruct 2507, Qwen3.5 9B), ekran „Test modelu”.

## Środowisko użytkownika

- Mac mini M4, macOS 27, Xcode 27, iPhone 17 Pro (iOS 27), konto Apple Developer: Personal Team
  (HealthKit i Increased Memory Limit mogą być niedostępne – sprawdzić).
- Symulator: audio wejściowe bywa zepsute (0 Hz, `no device with given ID`) – testy głosu na iPhonie.

## Do zrobienia / sprawdzenia

- [ ] Build w Xcode po ostatnich zmianach (MLXFoundationModels, `GeneratedCommand` – nie kompilowane poza macOS).
- [ ] Na iPhonie: „Test modelu” dla obu zgłoszonych poleceń; porównanie Gemma 4 E2B vs E4B.
- [ ] Jeśli działa – PR z gałęzi `claude/loving-archimedes-7ekz5o` do `main`.
- [ ] Opcjonalnie: przejście z `SFSpeechRecognizer` + `installTap` (przestarzałe w iOS 27) na SpeechAnalyzer.

## Weryfikacja logiki bez Xcode

Logikę (parser czasu, router, klient API, detektor „Hej Janek”) kompilowano i testowano na Linuksie
(Swift 6.1) z atrapami frameworków iOS. Testy Swift Testing są w `Janek/JanekTests/` (⌘U w Xcode).
