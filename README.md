# NotchTerm

Terminale a tendina (stile Quake) per macOS che esce dal notch. Premi la scorciatoia e il notch
si allarga in un terminale vero; premila di nuovo e rientra.

## Installare

Scarica `NotchTerm-x.y.z.zip` dalle [Release](https://github.com/massan71/NotchTerm/releases), estrai e sposta
`NotchTerm.app` in Applicazioni. L'app non è notarizzata: la prima volta macOS la blocca. Apri
Impostazioni di Sistema → Privacy e sicurezza → "Apri comunque", oppure da Terminale:

```bash
xattr -dr com.apple.quarantine /Applications/NotchTerm.app
```

## Compilare e avviare

Bastano i Command Line Tools (non serve Xcode):

```bash
make run        # compila e avvia build/NotchTerm.app
make install    # copia in /Applications e avvia
```

`build.sh` produce un'app universale (Apple Silicon + Intel); `ARCH=arm64 ./build.sh` compila solo una architettura.

L'app vive nella barra dei menu (icona terminale) e non ha icona nel Dock.
Scorciatoia predefinita: **⌃`** (Control + backtick).

## Impostazioni

Menu nella barra → **Impostazioni…** (o ⌘, dentro il terminale). Quattro sezioni: Generale (scorciatoia
con registrazione dal vivo, schermo, comportamento, avvio al login), Aspetto (temi, materiale, font, forma),
Animazione (con pulsante di prova) e Shell. Le modifiche si applicano subito e vengono salvate in `config.json`,
scrivendo solo le voci cambiate.

## Liquid Glass

I temi `glass` e `glass-clear` usano il materiale Liquid Glass di macOS 26+ (`NSGlassEffectView`): il desktop
si vede attraverso il pannello, sfocato, con un bordo luminoso. Sulle versioni precedenti si ripiega su una
sfocatura classica. Il materiale si può usare anche con gli altri temi: `"material": "glass"`.

## Avviso a fine comando

Lanci una build lunga e chiudi il terminale: quando finisce, il notch si allarga con il comando, l'esito
(✓ o ✗ con il codice d'uscita) e la durata. Un clic sull'avviso riapre il terminale su quella scheda.
Se il terminale è aperto su un'altra scheda, quella scheda mostra ✓ o ✗ nel titolo.

Per default l'avviso compare per i comandi che durano almeno 10 secondi; si regola in Impostazioni → Shell
o con `commandNotify` nel config.

Funziona con **zsh** (la shell predefinita di macOS) grazie a una piccola integrazione che NotchTerm attiva
da solo: zsh parte con `ZDOTDIR` puntato a `~/Library/Application Support/NotchTerm/shell-integration/zsh`,
il cui `.zshenv` ripristina subito il tuo `ZDOTDIR`, carica i tuoi file di avvio come sempre e aggiunge due hook.
Si disattiva con `"shellIntegration": false`.

Con altre shell basta emettere a fine comando la sequenza
`ESC ] 7501 ; id=notchterm : state=done|error : title=<comando in base64> : msg=<"codice durata" in base64> BEL`
(e `state=working` all'inizio).

## Spotify e Apple Music

NotchTerm segue il brano in riproduzione su Spotify o Apple Music:

- **Mini-player** a destra del notch quando il terminale è aperto: copertina, titolo, artista e ⏮ ⏯ ⏭.
  Clic sul titolo per aprire il lettore.
- **Avviso al cambio brano**: a terminale chiuso il notch si allarga per qualche secondo con copertina e
  comandi, come la Dynamic Island. Con il mouse sopra resta aperto.

Il brano lo si legge dalle notifiche che i lettori già pubblicano, senza permessi. Per comandare la
riproduzione macOS chiede una volta il permesso di **Automazione**. NotchTerm non avvia mai il lettore.
Le copertine di Spotify arrivano dal servizio oEmbed pubblico di Spotify.
Tutto si regola in Impostazioni → Musica.

## Personalizzazione

Il file di configurazione è `~/.config/notchterm/config.json` (si apre dal menu, o con ⌘, dentro il terminale).
Si ricarica **da solo al salvataggio**. Basta scrivere le chiavi da cambiare, per le altre valgono i default.

| Chiave | Default | Descrizione |
|---|---|---|
| `hotkey` | `"ctrl+`"` | Es. `"option+space"`, `"cmd+shift+t"`, `"f12"` |
| `width`, `height` | `0.55`, `0.45` | ≤ 1 = frazione dello schermo, altrimenti pixel |
| `theme` | `"notch"` | `notch`, `glass`, `glass-clear`, `dracula`, `nord`, `gruvbox`, `tokyo-night`, `catppuccin`, `solarized-dark`, `paper` |
| `colors` | `{}` | Override: `background`, `foreground`, `cursor`, `selection`, `ansi` (16 colori `#RRGGBB`) |
| `material` | dal tema | `solid`, `blur`, `glass` (Liquid Glass), `glass-clear` |
| `opacity` | dal tema | Opacità della tinta di sfondo (0–1) |
| `borderOpacity` | dal tema | Intensità del bordo luminoso (0 = nessuno) |
| `font` | `{"name": "", "size": 13}` | Nome vuoto = SF Mono |
| `cursorStyle` | `"block-blink"` | `block`, `bar`, `underline`, con `-blink` opzionale |
| `cornerRadius` | `22` | Raggio degli angoli in basso |
| `earRadius` | `10` | Raccordi concavi in alto, come il notch hardware |
| `padding` | `14` | Margine attorno al testo |
| `animation` | `{"style": "spring", "duration": 0.42, "damping": 0.82}` | `spring`, `ease`, `none`; `damping` più basso = più rimbalzo |
| `hideOnFocusLoss` | `true` | Si chiude quando clicchi altrove |
| `screen` | `"notch"` | `notch`, `main`, `mouse` |
| `shell`, `shellArgs` | `$SHELL`, `["-l"]` | Shell da avviare |
| `workingDirectory` | `"~"` | Cartella iniziale |
| `env` | `{}` | Variabili d'ambiente aggiuntive |
| `restartShellOnExit` | `true` | Riavvia la shell dopo `exit` |
| `showHeader` | `true` | Titolo/cartella a sinistra del notch |
| `optionAsMeta` | `true` | Option come Meta (readline/emacs) |
| `newTabInheritsDirectory` | `true` | Le nuove schede si aprono nella cartella della scheda corrente |
| `maxTabWidth` | `170` | Larghezza massima di una linguetta |
| `media` | `{"enabled": true, "showInHeader": true, "peekOnTrackChange": true, "peekDuration": 4}` | Spotify / Apple Music |
| `commandNotify` | `{"enabled": true, "minDuration": 10, "notifyOnSuccess": true}` | Avviso a fine comando |
| `shellIntegration` | `true` | Integrazione zsh (serve all'avviso a fine comando) |
| `fallbackNotchWidth` | `190` | Larghezza del notch simulato sugli schermi senza notch |

Esempio:

```json
{
  "hotkey": "option+space",
  "theme": "tokyo-night",
  "width": 1000,
  "height": 0.5,
  "material": "glass",
  "opacity": 0.3,
  "font": { "name": "JetBrains Mono", "size": 14 },
  "animation": { "style": "spring", "damping": 0.65 }
}
```

## Schede

Le linguette stanno a sinistra del notch, il pulsante **+** a destra. Con una sola scheda si vede solo il titolo.
Clic per selezionare, × o clic centrale per chiudere.

| Scorciatoia | Azione |
|---|---|
| ⌘T | Nuova scheda (nella cartella corrente) |
| ⌘W | Chiudi scheda (sull'ultima: nasconde il pannello e riavvia la shell) |
| ⌘1 … ⌘8, ⌘9 | Vai alla scheda n / all'ultima |
| ⌃Tab, ⌃⇧Tab | Scheda successiva / precedente |
| ⌘⇧] ⌘⇧[ (o ⌘⇧→ ⌘⇧←) | Scheda successiva / precedente |
| ⌘⌥← / ⌘⌥→ | Sposta la scheda |

Quando la shell di una scheda termina (`exit`) la scheda si chiude; se era l'ultima, la shell riparte.

## Altre scorciatoie dentro il terminale

⌘F cerca nello storico (⌘G / ⌘⇧G successivo / precedente, Esc chiude) · ⌘C copia · ⌘V incolla · ⌘A seleziona tutto · ⌘K pulisci · ⌘+ / ⌘− / ⌘0 dimensione testo · ⌘, impostazioni

## Aprire da script

```bash
osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("net.sangalli.notchterm.toggle", $(), $(), true)'
```

Sostituisci `toggle` con `newtab` per una nuova scheda, `settings` per le impostazioni o `peek` per mostrare l'avviso del brano. Utile per Raycast, Comandi Rapidi o skhd.

## Struttura

- `Sources/NotchTerm/NotchShape.swift` — forma del notch e misure del notch hardware
- `Sources/NotchTerm/NotchController.swift` — pannello, animazione, gestione schede e scorciatoie
- `Sources/NotchTerm/TerminalSession.swift` — una scheda: terminale SwiftTerm + shell
- `Sources/NotchTerm/TabBar.swift` — linguette nell'header
- `Sources/NotchTerm/Config.swift` — configurazione JSON e ricarica automatica
- `Sources/NotchTerm/Themes.swift` — temi inclusi e materiale di sfondo
- `Sources/NotchTerm/ShellIntegration.swift` — hook zsh per inizio/fine comando
- `Sources/NotchTerm/NowPlaying.swift` — Spotify / Apple Music: stato, comandi, copertine
- `Sources/NotchTerm/MediaViews.swift` — mini-player e avvisi dal notch (brano, fine comando)
- `Sources/NotchTerm/Settings.swift` — finestra Impostazioni (SwiftUI)
- `Sources/NotchTerm/HotKey.swift` — scorciatoia globale (Carbon, nessun permesso richiesto)
- `Sources/NotchTerm/main.swift` — app e menu nella barra

## Requisiti

- macOS 13 o successivo (Liquid Glass richiede macOS 26+)
- Command Line Tools o Xcode con Swift 5.9+

## Licenza

[MIT](LICENSE) © 2026 Max Sangalli. Usa [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT) per l'emulazione del terminale.
