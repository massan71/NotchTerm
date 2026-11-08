# NotchTerm

Terminale a tendina (stile Quake) per macOS che esce dal notch. Premi la scorciatoia e il notch
si allarga in un terminale vero; premila di nuovo e rientra.

## Compilare e avviare

Bastano i Command Line Tools (non serve Xcode):

```bash
make run        # compila e avvia build/NotchTerm.app
make install    # copia in /Applications e avvia
```

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

⌘C copia · ⌘V incolla · ⌘A seleziona tutto · ⌘K pulisci · ⌘+ / ⌘− / ⌘0 dimensione testo · ⌘, impostazioni

## Aprire da script

```bash
osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("net.sangalli.notchterm.toggle", $(), $(), true)'
```

Sostituisci `toggle` con `newtab` per una nuova scheda o con `settings` per le impostazioni. Utile per Raycast, Comandi Rapidi o skhd.

## Struttura

- `Sources/NotchTerm/NotchShape.swift` — forma del notch e misure del notch hardware
- `Sources/NotchTerm/NotchController.swift` — pannello, animazione, gestione schede e scorciatoie
- `Sources/NotchTerm/TerminalSession.swift` — una scheda: terminale SwiftTerm + shell
- `Sources/NotchTerm/TabBar.swift` — linguette nell'header
- `Sources/NotchTerm/Config.swift` — configurazione JSON e ricarica automatica
- `Sources/NotchTerm/Themes.swift` — temi inclusi e materiale di sfondo
- `Sources/NotchTerm/Settings.swift` — finestra Impostazioni (SwiftUI)
- `Sources/NotchTerm/HotKey.swift` — scorciatoia globale (Carbon, nessun permesso richiesto)
- `Sources/NotchTerm/main.swift` — app e menu nella barra

## Requisiti

- macOS 13 o successivo (Liquid Glass richiede macOS 26+)
- Command Line Tools o Xcode con Swift 5.9+

## Licenza

[MIT](LICENSE) © 2026 Max Sangalli. Usa [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT) per l'emulazione del terminale.
