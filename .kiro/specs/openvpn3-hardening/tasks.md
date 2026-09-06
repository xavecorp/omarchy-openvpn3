# Durcissement omarchy-openvpn3 — Tâches

**Base** : commit `7b96028`. Aucune action appliquée au démarrage.

## Mode d'emploi

Chaque **lot** est autonome et livrable séparément. Pour reprendre le travail :
cocher au fur et à mesure, et relire l'état des cases avant de démarrer une session.

Ordre recommandé : **Lot 1 → Lot 2 → Lot 3 → Lot 4 → Lot 6 → Lot 5 → Lot 7**.
Le Lot 6 (simplification) est volontairement placé après les correctifs
fonctionnels : plusieurs suppressions dépendent de A9.

Démarrage conseillé (coût faible, risque de régression quasi nul, gain immédiat) :
**A1, A2, A4, A6, A7**.

Agents du projet : `planner-openvpn3` → `developer-qml-openvpn3` →
`reviewer-qml-openvpn3` + `security-openvpn3`.

Vérification à chaque fin de lot :

```bash
node --test                      # doit rester 100% vert
qmllint Service.qml Panel.qml    # exit 0 attendu
```

`qmllint BarWidget.qml` → exit 255 pré-existant (limite du linter), pas un échec.

Légende sévérité : 🔴 BLOQUANT · 🟠 MAJEUR · 🟡 MOYEN · 🔵 MINEUR · ⚪ SIMPLIFICATION

---

## Lot 1 — Intégrité de l'état affiché

> ✅ **Livré** sur `fix/hardening-lot1-state-integrity` (voir journal en fin de fichier).
> Viole actuellement INV-1 : l'UI peut afficher « Connected » sur un tunnel mort.

- [x] **A1** 🔴 Remplacer la détection `connected` par sous-chaîne par un mapping
      explicite du StatusMinor — `Model.js:329`
  - [x] `sessionStateFromStatus()` ajouté, ancré sur `\bclient connected\b`
  - [x] `disconnect` testé **après** `client connected` ; défaut final ≠ `connected`
  - [x] Tests : `Client disconnected`, `Client disconnected by server`,
        `Client disconnecting` → **pas** connecté
  - [x] Vérif : `node --test` vert, nouveau test nommé présent

- [x] **A2** 🔴 Délimiter les blocs de `sessions-list` sur la ligne `Path:` (et non
      le séparateur) — `Model.js:269-322`
  - [x] Flush de l'accumulateur sur nouvelle ligne `Path:` **ou** séparateur
  - [x] Fixture 2 sessions ajoutée → `sessions.length === 2`, la connectée conservée
  - [x] Le cas 1 session (fixture existante) reste vert
  - [x] Vérif : `activeSessionName` renvoie bien la session **connectée**

- [x] **A3** 🟠 Étendre les états rendus : auth requise, pause, reconnexion, échec
      — `Model.js:368-373`, `Model.stateLabel`, `Panel.qml:59-64`
  - [x] `sessionState` consomme le mapping de A1
  - [x] `stateLabel` couvre : Auth required / Paused / Failed (labels **EN**, pas FR —
        cohérence UI ; états reconnect/resuming→connecting, auth-failed→error, donc
        pas de label distinct inatteignable — simplicité)
  - [x] `colorForState` couvre les nouveaux états (aucun ne tombe en vert)
  - [x] Tests de table statut → label

- [x] **A4** 🟠 Ne jamais dégrader vers « connected » ; honorer `configsResult.ok`
      — `Service.qml:110-113`, `:230-233`
  - [x] `Service.state` : défaut `connecting` quand la ligne est introuvable
  - [x] Sur `ok === false` : `lastError` posé **et vue précédente conservée**
        (la liste ne se vide pas), **et** vue marquée stale → `state` = `error`
        (pas de vert périmé — durcissement issu de l'audit sécurité)
  - [x] Test : JSON invalide → `ok:false` (déjà couvert)

**Vérification de lot** : `node --test` vert · `qmllint` exit 0 · aucun état ne peut
afficher vert sans `client connected`.

---

## Lot 2 — Intégrité système / processus

> ✅ **Livré** sur `fix/hardening-lot2-3-process-and-auth` (voir journal).
> Corrige NF-1 et NF-2 : orphelin à ~20 % CPU, stderr non borné.

- [x] **A5** 🔴 Supprimer la fuite de processus sur `session-start`
      — `Service.qml` wrap()
  - [x] Retenu : `session-start` **délégué au terminal** (A9) → n'est plus lancé par
        un Process ; le seul Process d'action restant (`session-manage --disconnect`)
        passe par `wrap()` avec **`--signal=KILL`**
  - [x] PoC enfant `trap '' TERM` sous `wrap()` `--signal=KILL` → **0 survivant**
        après expiration (pendant : 3 process ; après : 0)
  - [x] Commentaires corrigés (A18) — plus de promesse de reaping complet

- [x] **A6** 🟠 Borner stderr **in-band** — `Service.qml`
  - [x] `capScriptRead` = `"$@" 2>/dev/null | head -c N` (lectures)
  - [x] `capScriptAction` = `"$@" 2>&1 | head -c N` (disconnect)
  - [x] ⚠️ `2>&1` **jamais** appliqué à `configs-list --json` (JSON préservé — PoC OK)
  - [x] `configsErr`/`sessionsErr`/`actionErr` supprimés ; `_actionOutput` supprimé
  - [x] PoC : flood combiné capé à N octets ; stderr de lecture jeté

- [x] **A7** 🟠 Garder `probeProcess` contre la destruction
  - [x] `if (root._destroyed) return` dans `probeProcess.onExited`
  - [x] `if (root._destroyed) return` dans `probeNext()`

- [x] **A8** 🟠 Recalibrer le watchdog de lecture
  - [x] Réarmement au démarrage de **chaque** lecture (configs puis sessions)
  - [x] Plus de faux « openvpn3 stopped responding » quand chaque commande respecte
        son propre plafond de 12 s

**Vérification de lot** : PoC orphelin (KILL) **et** PoC stderr rejoués · `node --test` 35/35.

---

## Lot 3 — Cas d'usage principal (profils user-locked / 2FA)

> ✅ **Livré** sur `fix/hardening-lot2-3-process-and-auth` (voir journal).
> Corrige EX-3. `testamento-profile-userlocked` = le cas d'usage réel.

- [x] **A9** 🟠 Déléguer `session-start` au terminal flottant
  - [x] Patron du shell hôte réutilisé — **côté Panel/BarWidget** (qui ont `bar` ;
        Service est headless) : `bar.run(launcher + " " + Util.shellQuote(cmd))`,
        repli `Quickshell.execDetached`. Argv shell-quoté (double couche, PoC sûr)
  - [x] Statut `requires user input` → `Auth required` (Lot 1), toggle → ouvre le terminal
  - [x] Plus de blocage 40 s ; plus de `lastError` affichant un chemin D-Bus
  - [x] Nettoyage induit : `Service.connectConfig`/`toggleConfig` supprimés,
        `startArgv` (validation + argv) ajouté, décision connect/disconnect en UI,
        `_actionOutput` supprimé, `actionTimeoutSec` 40→12 s, `Service.busy` (mort) supprimé
  - [x] `actionWatchdog` conservé (backstop du disconnect), intervalle recalibré, documenté
  - [ ] ⏳ Test manuel sur un profil demandant des identifiants — **à faire par l'utilisateur**
        (nécessite un vrai profil user-locked et un rendu shell live)

**Vérification de lot** : logique prouvée par PoC ; connexion réelle d'un profil
user-locked à confirmer par l'utilisateur (angle mort assumé — pas de shell graphique ici).

---

## Lot 4 — Robustesse UI

> Viole actuellement EX-4 au-delà de ~16 profils.

- [ ] **A10** 🟠 Ajouter `Flickable` + clipping + scroll — `Panel.qml:118, 150-152, 76-80`
  - [ ] `Flickable { clip: true; boundsBehavior: StopAtBounds;
        interactive: contentHeight > height }` + `ScrollBar.vertical`
  - [ ] `cap` passé à `fittedContentHeight` (patron Docker)
  - [ ] `ensureVisible()` appelé depuis `moveCursor` (curseur clavier toujours visible)
  - [ ] Test manuel : 30 profils → tout atteignable, rien peint hors carte, message
        d'erreur toujours visible

- [ ] **A11** 🔵 Corriger la hauteur de carte (2 px) — `Panel.qml:266`
  - [ ] `cardRow.implicitHeight + Style.spacing.md * 2` (au lieu de `xl`)

---

## Lot 5 — Durcissement sécurité

- [ ] **A12** 🟡 Assainir l'environnement des sous-processus — les 4 `Process`
  - [ ] `clearEnvironment: true` + `environment: ({ PATH: "/usr/bin" })`
  - [ ] ⚠️ **Valider `session-start`** sous env vide avant de généraliser
        (les 3 autres commandes sont déjà prouvées OK avec `env -i`)
  - [ ] Non-régression : les 3 lectures/actions fonctionnent toujours

- [ ] **A13** 🔵 Resserrer `PATH_TAIL` à `/^[A-Za-z0-9_-]+$/` — `Model.js:28`
  - [ ] Test : `.../../sessions/aaaa` rejeté ; un vrai tail accepté

- [ ] **A14** 🔵 *(optionnel)* Vocabulaire d'erreur fixe au lieu du texte CLI brut
      — `Service.qml:465-469`

---

## Lot 6 — Simplification (INV-2, ~200 lignes)

> À faire **après** le Lot 3 : plusieurs suppressions dépendent de A9.

- [ ] **A15** ⚪ Supprimer `parseConfigsList` + `isHeaderRow`, `firstColumn`,
      `WEEKDAY_PREFIX`, `nameFromRecord` — `Model.js:162-260` (~115 l.)
  - [ ] ⚠️ **Conserver `isSeparator`** (requis par `parseSessionsList`)
  - [ ] Export retiré + 4 tests correspondants supprimés
  - [ ] `node --test` toujours vert

- [ ] **A16** ⚪ Supprimer `configPathForName`, `sessionPathForName`,
      `sessionPathForConfigPath`, `heroText` — `Model.js:432-464` (~30 l.)
  - [ ] Exports retirés + 2 tests supprimés
  - [ ] ⚠️ Vérifier au préalable qu'A19 ne les réutilise pas

- [ ] **A17** ⚪ Supprimer le code inerte de `Service.qml`
  - [ ] `errorHold` (Timer sans `onTriggered` ni lecteur) + ses 4 appels
        — *ou* l'implémenter (`onTriggered: lastError = ""`) ; INV-2 → suppression
  - [ ] `refreshing` (écrit 5×, lu 0×)

- [ ] **A18** ⚪ Aligner commentaires et CHANGELOG sur la réalité
      — `Service.qml:26-31, 78-99, 81-88` · `CHANGELOG.md:41-44`
  - [ ] Plus aucune promesse de reaping complet du groupe non tenue
  - [ ] Plus aucune promesse de bornage de sortie non tenue
  - [ ] À livrer **avec** A5/A6, jamais séparément

---

## Lot 7 — Ambiguïté résiduelle nom/path

- [ ] **A19** 🟠 Unifier l'identité sur les object paths
      — `Model.js:349, 359-366, 376-388` · `Service.qml:114, 296` · `BarWidget.qml:63-67`
  - [ ] `activeSessionName` → renvoie une `sessionPath` (renommée `activeSessionPath`)
  - [ ] `rowByName` éliminé de `Service.state`, `disconnectActive`,
        `BarWidget.activeConfigPath`
  - [ ] Deux profils homonymes → l'action est **refusée**, pas devinée
  - [ ] Contrainte CLI documentée (`sessions-list` n'expose pas le config path,
        pas de mode JSON)
  - [ ] Test : 2 profils homonymes, 1 seul monté → pas de `sessionPath` partagée,
        pas de déconnexion croisée
  - [ ] ⚠️ Dépend de A2 (sans quoi le multi-sessions est de toute façon faussé)

---

## Points ouverts à trancher

- [ ] **P1** `openvpn3 sessions-list; echo $?` **à l'état déconnecté** — si le code
      de sortie est non nul, le rejet strict `exitCode !== 0` (`Service.qml:444-448`)
      afficherait une erreur permanente hors connexion. Adapter le cas échéant.
- [ ] **P2** Valider `session-start` sous `clearEnvironment` (bloque A12).
- [ ] **P3** Capturer le format réel d'un `sessions-list` multi-sessions (confort
      seulement : A2 est robuste aux deux formats).

---

## Journal des livraisons

| Date | Lot(s) | Commit | Vérif | Notes |
|---|---|---|---|---|
| 2026-09-05 | Lot 1 (A1–A4) | c22085d (PR #2, mergée) | `node --test` 35/35 · qmllint exit 0 | Review APPROVED ; Security APPROVED après 1 durcissement (vue stale → `error`). Labels EN. |
| 2026-09-05 | Lot 2 (A5–A8) + Lot 3 (A9) | _(à compléter au commit)_ | 35/35 · qmllint exit 0 · PoC A5(KILL)/A6(caps) | A9 : session-start délégué au terminal (Service headless → logique en UI). Review APPROVED après retrait de `Service.busy` mort ; Security APPROVED (quoting terminal double-couche prouvé sûr). Bump minor 0.3.0. **Test manuel user-locked à faire par l'utilisateur.** |
