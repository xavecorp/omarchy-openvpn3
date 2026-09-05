# Durcissement omarchy-openvpn3 — Conception

Décisions techniques et preuves à l'appui de chaque action. Référence commit
`7b96028`. Les identifiants `A1…A19` sont ceux de `tasks.md`.

## Principe directeur

Les défauts trouvés se répartissent en deux familles :

- **Des mensonges** — l'UI ou un commentaire affirme quelque chose de faux
  (« Connected » sur tunnel mort, « tout l'arbre est reapé », « la sortie est
  plafonnée »). Ce sont les plus graves : ils trompent l'utilisateur *et* ont déjà
  masqué des bugs pendant les relectures précédentes.
- **De la complexité non branchée** — ~200 lignes qui n'affectent aucun
  comportement observable.

Aucune de ces familles ne se corrige par ajout de code. La plupart des actions
**retirent** ou **resserrent**.

---

## Lot 1 — Intégrité de l'état affiché

### A1 — Détection `connected` par sous-chaîne

`Model.js:329` : `connected: /connected/i.test(session.status)`.

Preuve exécutée sur le vrai `Model.js` :

```
"Connection, Client connected"           -> connected=true  state=connected
"Connection, Client disconnected"        -> connected=true  state=connected   ❌
"Connection, Client disconnected by server" -> connected=true state=connected ❌
```

`Client disconnected by server` (kick serveur) est un état **persistant** : l'objet
session survit jusqu'au `session-manage --cleanup`. Le widget affiche donc un point
vert et un interrupteur ON sur un tunnel fermé — violation directe de **INV-1**.

**Conception** : remplacer la détection par sous-chaîne par un mapping explicite du
*StatusMinor*, ancré sur les libellés réels du binaire :

```js
function sessionStateFromStatus(status) {
    var s = String(status || "").toLowerCase();
    if (/\bclient connected\b/.test(s))                                return "connected";
    if (/requires user input/.test(s))                                 return "auth";
    if (/authentication failed/.test(s))                               return "error";
    if (/(connection failed|exception|process exited|timeout)/.test(s)) return "error";
    if (/paus/.test(s))                                                return "paused";
    if (/(reconnect|resuming)/.test(s))                                return "connecting";
    if (/disconnect/.test(s))                                          return "disconnected";
    return "connecting";
}
```

L'ordre compte : `disconnect` est testé **après** `client connected`, et le défaut
final est `connecting` (jamais `connected`).

### A2 — Parsing multi-sessions

`Model.js:269-322` découpe les blocs sur `isSeparator()`. Or `sessions-list` n'émet
un séparateur qu'en tête et en pied. Preuve exécutée sur 2 blocs séparés par une
ligne vide :

```
sessions trouvées = 1 (attendu 2)
survivante = "beta" (connecting) — "alpha" (connected) PERDUE
activeSessionName = "beta"
```

`assignSessionField` écrase `path`/`name`/`status` de l'accumulateur à chaque bloc,
et le push n'a lieu qu'au séparateur final. Conséquence : le profil réellement
connecté s'affiche « Off », un clic appelle `connectConfig` sur un tunnel déjà monté,
et `disconnectActive()` cible la mauvaise session.

**Conception** : délimiter sur la ligne `Path:` — chaque bloc en commence exactement
une, et elle est déjà validée par `validatePath`. Flusher l'accumulateur à chaque
nouvelle ligne `Path:` **ou** au séparateur.

> Ce choix est **robuste aux deux formats** (séparateur entre blocs ou ligne vide),
> ce qui lève le seul point non vérifiable directement : le format exact émis par
> openvpn3 en multi-sessions n'a pas pu être capturé sans créer une 2ᵉ session sur
> la machine de l'utilisateur.

### A3 — États non couverts

`Model.js:368-373` ne connaît que `connected`/`connecting`. `stateLabel` sait rendre
`"error"` mais **rien ne le produit** dans le flux de lecture. Table exécutée :

```
"requires user input: Username/password..." -> Connecting…
"Connection paused"                         -> Connecting…
"Authentication failed"                     -> Connecting…
"Client exception"                          -> Connecting…
```

Mot de passe erroné, pause, reconnexion, exception : tous indiscernables et affichés
« Connecting… » **indéfiniment**, icône de barre pulsant en boucle.

**Conception** : consommer le mapping de A1 dans `sessionState`, étendre
`Model.stateLabel` (`Identifiants requis`, `En pause`, `Reconnexion…`,
`Échec d'authentification`, `Échec`) et `Panel.colorForState` (`Panel.qml:59-64`).
A1 et A3 forment un seul chantier cohérent.

### A4 — Modes de défaillance penchant vers « connected »

Deux chemins, tous deux contraires à **INV-1** :

- `Service.qml:110-113` : si `activeName !== ""` et `rowByName` renvoie `null`,
  l'état dérivé vaut `"connected"`.
- `Service.qml:230-233` : `applyReads` ignore `configsResult.ok`. Sur JSON invalide
  (`Model.js:110-112` renvoie `ok:false`), `configs` devient `[]` → le panneau
  affiche « No configs — import one with… » **sans aucune erreur**, faisant
  « disparaître » tous les profils (viole aussi **EX-5**).

**Conception** : défaut `"connecting"` (ou `"error"`) au lieu de `"connected"` ; et
sur `ok === false`, poser `lastError` en **conservant** la vue précédente.

---

## Lot 2 — Intégrité système / processus

### A5 — Fuite de processus (le plus grave)

Les commentaires `Service.qml:26-31` et `:78-99` affirment que `timeout` reape tout
le groupe, TERM puis KILL après 2 s. **Reproduit et réfuté** avec un enfant qui
ignore SIGTERM (`trap '' TERM`), sous l'argv exact de `wrap()` :

```
timeout exit=124 (expiration)
--- 4 s après expiration ---
1252993  PPID 1133  PGID 1252990  stubborn.sh   ← SURVIVANT, reparenté
```

Mécanisme : `timeout` envoie TERM au groupe ; son enfant direct `bash` meurt ; il le
récolte et **sort immédiatement, sans jamais atteindre l'échéance du `--kill-after`**.
Le petit-enfant qui ignore TERM survit. Or `openvpn3 session-start` **ignore
SIGTERM** (mesuré : survit 2 s après TERM à ~20 % CPU).

> Cela réconcilie les deux auditeurs : le test de l'auditeur sécurité utilisait
> `sleep`, qui meurt sur TERM — d'où « aucun survivant ». Les deux mesures sont
> correctes ; c'est le cas « enfant récalcitrant » qui compte.

Impact : chaque connexion échouée laisse un `openvpn3` à ~20 % CPU **et** un
`openvpn3-service-client` à ~39 % jusqu'au reboot. Invalide aussi
`Component.onDestruction` et le commentaire de `actionWatchdog`.

**Conception, par ordre de préférence** :

1. **Retirer `session-start` du wrapper `timeout`** et utiliser l'option native
   `openvpn3 session-start --timeout SECS` : openvpn3 abandonne proprement **et
   démonte sa propre session**. Résout A5 et A9 ensemble.
2. Si `timeout` reste : `--signal=KILL` (le KILL au groupe à l'expiration atteint
   bien un récalcitrant).
3. Dans tous les cas : **corriger les commentaires** (voir A18).

### A6 — stderr échappe au cap

`Service.qml:96-97` : `"$@" | /usr/bin/head -c N` — seul **stdout** traverse `head`.
PoC :

```
stdout capé   : 100 octets
stderr passé  : 500 000 octets   ← aucun plafond
```

Mesure de l'auditeur sécurité (2 Gio sur stderr, RSS de quickshell) :

| Variante | Pic RSS | Delta |
|---|---|---|
| Code actuel | 421 760 Ko | **+198 Mo** |
| Collecteurs stderr supprimés | 477 456 Ko | **+253 Mo** (toujours vulnérable) |
| `2>&1 \| head -c N` | 224 156 Ko | +0,5 Mo ✅ |
| `2>/dev/null \| head -c N` | 223 476 Ko | +0 Mo ✅ |

**Résultat décisif : supprimer les collecteurs ne corrige rien** — Quickshell
tamponne le stderr non parsé quand même. Le cap doit être **in-band**.

**Conception** : deux scripts distincts selon l'usage.

```qml
// Lectures : stderr n'est jamais lu (Service.qml:400,436) → jeté à la source.
readonly property string capScriptRead:
    "set -o pipefail; \"$@\" 2>/dev/null | /usr/bin/head -c " + maxStoredChars
// Action : le texte d'erreur est nécessaire → fusionné DANS le cap.
readonly property string capScriptAction:
    "set -o pipefail; \"$@\" 2>&1 | /usr/bin/head -c " + maxStoredChars
```

⚠️ **Ne jamais appliquer `2>&1` à `configs-list --json`** : un warning openvpn3 sur
stderr corromprait le flux et ferait échouer `JSON.parse` (interaction directe avec
A4). C'est la raison d'être des deux scripts.

Bénéfice annexe : avec `2>&1` sur l'action, `firstLine` verra le vrai message
d'erreur au lieu du `Session path:` inutile de A9.

### A7 — `probeProcess` non gardé

Les `onExited` de `configsProcess` (`:404`), `sessionsProcess` (`:438`) et
`actionProcess` (`:463`) ouvrent sur `if (root._destroyed) return`.
`probeProcess.onExited` (`:203-212`) **ne l'a pas**, et `probeNext()` (`:185-194`)
non plus : `Component.onDestruction` pose `_destroyed`, met `probeProcess.running =
false` → SIGTERM → `onExited` arrive ensuite et **relance un Process** sur un
composant en destruction. Seul trou de couverture des latches.

**Conception** : `if (root._destroyed) return` en tête de `probeProcess.onExited`
**et** de `probeNext()`.

### A8 — Watchdog de lecture mal calibré

`readTimeoutSec: 12` s'applique **par commande**, mais `refresh()` arme un watchdog
unique de **15 s** pour la chaîne séquentielle `configs-list` → `sessions-list`,
dont le budget légitime est **24 s**. Un openvpn3 lent mais sain (11 s + 5 s) voit
sa lecture tuée à 15 s avec le message **faux** « openvpn3 stopped responding ».

**Conception** : réarmer le watchdog au démarrage de **chaque** `Process` (préférable),
ou `interval: (readTimeoutSec * 2 + 3) * 1000`.

---

## Lot 3 — Cas d'usage principal

### A9 — Profils à authentification interactive

`Service.qml:456-476` : pas de `stdinEnabled`. Test réel sur profil `auth-user-pass`
avec l'argv exact du plugin :

```
stdout : Session path: /net/openvpn/v3/sessions/a45da48f...
         Auth User name: Auth Password:   (× des milliers)
stderr : ** ERROR **  Empty input not allowed  (× des milliers, boucle serrée)
exit 124 après 40 s
```

openvpn3 **ne renonce pas** sur stdin fermé. Parcours utilisateur réel :

1. Bascule du switch → « Connecting… » pendant **40 s**.
2. À 40 s, `lastError` affiche **`Session path: /net/openvpn/v3/sessions/a45d…`**
   (première ligne non vide de stdout+stderr) — un chemin D-Bus, rien sur les
   identifiants manquants.
3. **La session est créée** avant toute demande de credentials, avec le statut
   `Configuration requires user input` et un backend à 39 % CPU.
4. Au poll suivant : `connected:false` → `"connecting"` → **« Connecting… » à vie**.
5. Le switch reste ON. Seule sortie : le terminal.

Le profil de test de l'utilisateur s'appelle `testamento-profile-userlocked` :
c'est **le** cas d'usage.

**Conception** : le plugin ne peut structurellement pas fournir stdin → il ne doit
pas essayer. Déléguer au terminal, avec le patron déjà utilisé par le shell hôte
(`/usr/share/omarchy/shell/plugins/panels/network/Panel.qml:670-672`) :

```qml
root.bar.run("omarchy-launch-floating-terminal-with-presentation "
             + Util.shellQuote("openvpn3 session-start --config-path " + row.configPath))
```

Et nommer l'état : `requires user input` → « Identifiants requis » + action
« Ouvrir un terminal », au lieu de « Connecting… ».

**Effet de bord vertueux** — disparaissent : `actionTimeoutSec`, `actionWatchdog`,
la branche 40 s, le `firstLine`/`_actionOutput`, et le risque d'orphelin A5 sur la
commande la plus longue. `Service.qml` ne garde en `Process` que deux lectures et un
`session-manage --disconnect` (non interactif, instantané). **C'est à la fois le
correctif fonctionnel et la plus grosse simplification disponible.**

---

## Lot 4 — Robustesse UI

### A10 — Absence de `Flickable`

`Panel.qml:118` appelle `fittedContentHeight(column.implicitHeight)` **sans le
paramètre `cap`**, contrairement à l'étalon Docker (`fittedContentHeight(…,
Style.space(680))`). `KeyboardPanel.fittedContentHeight` écrête bien à
`availableCardHeight`, mais `column` est ancré `top/left/right` **sans bottom** : sa
hauteur reste son `implicitHeight`, indépendante du plafond. Et **rien ne clippe** :
`BorderSurface` est un `Rectangle` (`clip:false`), `contentHolder` et
`PanelKeyCatcher` sont des `Item`.

Chiffrage avec les tokens réels (carte ≈ 41 px, pas ≈ 55 px, en-tête ≈ 85 px,
inset 32 px, 1080p, barre 40 px) :

| Profils | Conséquence |
|---|---|
| ~16 | limite du budget (≈ 988 px) |
| 20 | débordement ≈ 197 px (~3,5 lignes) |
| 30 | débordement ≈ 747 px (~13,5 lignes) |

Au-delà de ~16 profils, les lignes sont peintes **hors carte** (texte flottant sans
fond sur le bureau) puis **hors écran, inatteignables** — ni scroll ni molette. Le
`Text` d'erreur, dernier enfant, devient invisible en même temps. `clampCursor()`
autorise le curseur jusqu'au dernier index sans `ensureVisible`.

**Conception** : reprendre le patron Docker —
`Flickable { clip: true; contentHeight: column.implicitHeight; boundsBehavior:
StopAtBounds; interactive: contentHeight > height; ScrollBar.vertical }` +
`ensureVisible()` appelé depuis `moveCursor`, et passer le `cap`.

> Réfutation retenue : **pas** de boucle de binding. `column.implicitHeight` dépend
> de `column.width` ← `contentWidth`, qui ne dépend d'aucune hauteur ; et `column`
> n'étant pas ancré en bas, `contentHeight` ne le réalimente pas. L'ancrage
> top-only est correct et délibéré — c'est l'absence de clipping le défaut.

### A11 — Hauteur de carte

`Panel.qml:266` : `cardRow.implicitHeight + Style.spacing.xl` (=10), alors que
`cardRow` absorbe `topMargin + bottomMargin = Style.spacing.md * 2` (=12). La
`RowLayout` reçoit 2 px de moins que nécessaire et comprime son contenu sur **chaque**
ligne. → `+ Style.spacing.md * 2`.

---

## Lot 5 — Durcissement sécurité

### A12 — `BASH_ENV`

Reproduit via le wrapper exact du plugin :

```
$ BASH_ENV=/tmp/benv.sh /usr/bin/timeout 5 /usr/bin/bash -c 'set -o pipefail; "$@" | head -c 1000' openvpn3-wrap /usr/bin/echo hello
INJECTED_VIA_BASH_ENV
hello
```

`bash -c` **lit `BASH_ENV`** même non interactif : du code arbitraire s'exécute
toutes les 5 s si la variable est présente dans l'environnement hérité.

Ce **n'est pas** une frontière de privilèges (qui peut poser la variable a déjà l'UID
de l'utilisateur) → **MOYEN**, défense en profondeur. `LD_PRELOAD` /
`LD_LIBRARY_PATH` sont sans intérêt ici (`/usr/bin/openvpn3` n'est pas setuid) ;
`IFS` est sans effet sur `"$@"` quoté.

**Conception** : `clearEnvironment: true` + `environment: ({ PATH: "/usr/bin" })`.
Faisabilité **prouvée** pour `configs-list --json`, `sessions-list` et
`session-manage` (`env -i` → exit 0, sortie complète). **Reste à valider pour
`session-start`** — non testé pour ne pas créer de session réelle.

### A13 — `PATH_TAIL` trop permissif

`Model.js:28` autorise `/` et `.`, donc
`/net/openvpn/v3/configuration/../../sessions/aaaa` passe la validation. Désamorcé
en aval (openvpn3 répond `Invalid D-Bus path`), donc **FAIBLE**. Les vrais tails ne
contiennent ni `/` ni `.` → resserrer à `/^[A-Za-z0-9_-]+$/`.

### A14 — Texte d'erreur brut

`Service.qml:465-469` affiche la première ligne de stdout+stderr du CLI. Un échec de
connexion peut contenir l'IP/port de la passerelle. Exposition locale à l'écran du
propriétaire du profil (risque : capture d'écran, screencast). Optionnel : mapper sur
un vocabulaire fixe, ou ne montrer le détail que sur action explicite.

> Vérifié sain par ailleurs : le parseur ne retient **jamais** `Connected to:`,
> `PID`, `Device` ni `Owner` — seuls `Config name`, `Status` et le path sont stockés,
> et `Status` n'est jamais rendu tel quel.

---

## Lot 6 — Simplification (INV-2)

Code mort confirmé par grep sur les 3 `.qml` (attention au faux positif de
sous-chaîne : `parseConfigsList` vs `parseConfigsListJson`) :

| # | Symbole | Preuve | Gain |
|---|---|---|---|
| A15 | `Model.parseConfigsList` + `isHeaderRow`, `firstColumn`, `WEEKDAY_PREFIX`, `nameFromRecord` | 0 référence QML — seul `--json` est utilisé | ~115 l. + 4 tests |
| A16 | `configPathForName`, `sessionPathForName`, `sessionPathForConfigPath`, `heroText` | 0 référence QML (les 4) | ~30 l. + 2 tests |
| A17 | `errorHold` (Timer) | **Aucun `onTriggered`, aucun lecteur de `.running`** — les 4 appels n'ont aucun effet | 5 l. + 4 appels |
| A17 | `refreshing` | écrit 5×, lu 0× (0 en Panel/BarWidget) | 6 l. |
| A6 | `configsErr`, `sessionsErr` | déclarés, jamais lus, bufferisent pour rien | 2 l. |

`isSeparator` reste nécessaire à `parseSessionsList` — ne pas le supprimer.

Note sur `errorHold` : son commentaire promet « keeps an action error on screen long
enough to read » — fonctionnalité **inexistante**. C'est précisément pourquoi le
message de A9 est écrasé en moins d'une seconde. Deux issues acceptables :
l'implémenter (`onTriggered: root.lastError = ""` + lecture par le panneau) ou le
supprimer. **INV-2 privilégie la suppression.**

### A18 — Commentaires et CHANGELOG mensongers

- `Service.qml:26-31, 78-99` — promettent un reaping complet du groupe → réfuté (A5).
- `Service.qml:81-88` — « at most maxStoredChars bytes ever leave the child » →
  réfuté (A6, stderr).
- `CHANGELOG.md:41-44` — même affirmation sur le cap.

Ces affirmations ont permis aux deux trous de survivre aux relectures précédentes.
À corriger **avec** le code, jamais séparément.

### Note sur les watchdogs QML

`watchdog` (15 s vs `timeout` 12 s) et `actionWatchdog` (45 s vs 40 s) sont
aujourd'hui inatteignables : `timeout` gagne toujours et `onExited` les arrête.
**Ne pas les supprimer aveuglément** :

- `watchdog` doit être **corrigé** (A8), pas retiré — il protège contre un
  `onExited` qui n'arriverait jamais.
- `actionWatchdog` **redevient utile** si A9 retire `timeout` de `session-start`.

---

## Lot 7 — Ambiguïté résiduelle nom/path

### A19

Points encore keyés par nom : `Model.buildRows` → `sessionByName`
(`Model.js:349, 359-366`), `Model.activeSessionName` (`:376-388`, renvoie un **nom**),
`Service.state` (`Service.qml:114`), `Service.disconnectActive` (`:296`),
`BarWidget.activeConfigPath` (`BarWidget.qml:63-67`).

Preuve exécutée, deux profils nommés `work`, seul `/bbbb` monté :

```json
[{"name":"work","configPath":".../aaaa","sessionPath":".../sessions/1111","state":"connected"},
 {"name":"work","configPath":".../bbbb","sessionPath":".../sessions/1111","state":"connected"}]
rowByName(rows,"work").configPath = .../aaaa
```

Les deux lignes affichent « Connected » et **partagent la même `sessionPath`** :
basculer `/aaaa` déconnecte la session de `/bbbb` — exactement ce que le commentaire
`Service.qml:262-268` prétend impossible. La validation par path est correcte **en
aval** ; c'est l'appariement **en amont** qui est par nom, donc le path transporté
est déjà le mauvais.

**Contrainte incontournable** : `sessions-list` n'expose pas le config path d'une
session, et il n'existe pas de mode JSON. L'appariement par nom est donc imposé par
le CLI.

**Conception** : (a) faire renvoyer une `sessionPath` par `activeSessionName`
(renommée `activeSessionPath`), ce qui élimine `rowByName` de `Service.state`,
`disconnectActive` et `BarWidget.activeConfigPath` ; (b) **refuser l'action** quand
deux profils partagent un nom, au lieu de deviner ; (c) documenter honnêtement la
contrainte CLI.

> Réfutation retenue : le scénario « deux sessions depuis le même profil » est
> **impossible** — openvpn3 répond `A session with this configuration profile is
> already running`. Il n'y a donc pas de session invisible non arrêtable.

---

## Points ouverts à trancher avant clôture

1. **Code de sortie de `sessions-list` sans session active** — si non nul, le rejet
   strict `exitCode !== 0` (`Service.qml:444-448`) afficherait une erreur permanente
   à l'état déconnecté. À vérifier par `openvpn3 sessions-list; echo $?` une fois
   déconnecté. `strings` confirme le libellé `No sessions available`, bien matché.
2. **`session-start` sous `clearEnvironment`** (A12) — non testé pour ne pas créer
   de session VPN réelle.
3. **Format exact du séparateur multi-sessions** — non capturé (nécessiterait une 2ᵉ
   session sur la machine). Sans impact : le correctif A2 est robuste aux deux formats.
