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

> ✅ **Livré** sur `fix/hardening-lot4-ui-scroll` (voir journal). Corrige EX-4.

- [x] **A10** 🟠 Ajouter `Flickable` + clipping + scroll
  - [x] `Flickable { clip: true; boundsBehavior: StopAtBounds;
        interactive: contentHeight > height }` + `ScrollBar.vertical` (AsNeeded)
  - [x] `cap` `Style.space(680)` passé à `fittedContentHeight` (patron Docker)
  - [x] `ensureVisible()` appelé depuis `moveCursor` (curseur clavier visible)
  - [x] `import QtQuick.Controls` ajouté (ScrollBar) ; ColumnLayout conservé avec
        `width: scrollArea.width` (choix documenté, pas de binding loop — qml6 6s OK)
  - [ ] ⏳ Test manuel 30 profils — **à faire par l'utilisateur** (rendu shell live)

- [x] **A11** 🔵 Hauteur de carte : `cardRow.implicitHeight + Style.spacing.md * 2`

---

## Lot 5 — Durcissement sécurité

> ✅ **Livré** sur `fix/hardening-lot5-7-env-and-identity` (voir journal).

- [x] **A12** 🟡 Assainir l'environnement des sous-processus — les 4 `Process`
  - [x] `clearEnvironment: true` + `environment: ({ PATH: "/usr/bin" })`
  - [x] P2 **levé** : `session-start` n'est plus un Process (délégué terminal) ;
        les 4 Process restants prouvés OK sous `env -i` ; BASH_ENV fermé (PoC)
- [x] **A13** 🔵 `PATH_TAIL` resserré à `/^[A-Za-z0-9_-]+$/` — traversée `../..` rejetée,
      vrais tails acceptés (PoC)
- [ ] **A14** 🔵 *(optionnel, NON fait)* Vocabulaire d'erreur fixe — reporté (facultatif)

---

## Lot 6 — Simplification (INV-2, ~235 lignes)

> ✅ **Livré** sur `fix/hardening-lot6-simplify` (voir journal). -235 lignes nettes.

- [x] **A15** ⚪ Supprimer `parseConfigsList` + `isHeaderRow`, `firstColumn`,
      `WEEKDAY_PREFIX`, `nameFromRecord` (~148 l.)
  - [x] ⚠️ `isSeparator`/`toLines` **conservés** (requis par `parseSessionsList`)
  - [x] Export retiré ; tests morts supprimés, tests-fixtures migrés vers JSON
  - [x] `node --test` vert (35 → 30)

- [x] **A16** ⚪ Supprimer `configPathForName`, `sessionPathForName`,
      `sessionPathForConfigPath`, `heroText` (~34 l.)
  - [x] Exports retirés ; 0 usage QML confirmé (A19 n'en dépend pas)

- [x] **A17** ⚪ Supprimer le code inerte de `Service.qml`
  - [x] `errorHold` (Timer sans `onTriggered` ni lecteur) + ses appels
  - [x] `refreshing` (écrit 5×, lu 0×) ; `lastError` reste géré correctement

- [x] **A18** ⚪ Commentaires : déjà rendus honnêtes au Lot 2-3 (confirmé par lecture).
      CHANGELOG historique **non réécrit** (reflète ce qui était cru alors) ; le
      comportement réel est documenté depuis 0.3.0.

---

## Lot 7 — Ambiguïté résiduelle nom/path

> ✅ **Livré** sur `fix/hardening-lot5-7-env-and-identity` (voir journal).

- [x] **A19** 🟠 Unifier l'identité sur les object paths
  - [x] `activeSessionName` → `activeSessionPath` (renvoie une sessionPath)
  - [x] `rowByName` **supprimé** ; nouveau `rowBySessionPath` (refuse si 0 ou >1 match)
  - [x] `Service.state`/`disconnectActive`/`disconnectConfig`/`BarWidget.activeConfigPath`
        résolvent par path ; action **refusée** (lastError) sur homonymes
  - [x] Nom affiché **re-dérivé** depuis la row (jamais d'object path à l'écran)
  - [x] Contrainte CLI documentée (`sessions-list` sans config path ni JSON →
        appariement par nom dans buildRows, borné par le refus en aval)
  - [x] Tests : 2 profils homonymes 1 monté → rowBySessionPath null → refus (PoC + test)

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
| 2026-09-05 | Lot 2 (A5–A8) + Lot 3 (A9) | d4b9042 (PR #3, mergée) | 35/35 · qmllint exit 0 · PoC A5(KILL)/A6(caps) | A9 : session-start délégué au terminal (Service headless → logique en UI). Review APPROVED après retrait de `Service.busy` mort ; Security APPROVED. Bump minor 0.3.0. **Test manuel user-locked à faire.** |
| 2026-09-05 | Lot 4 (A10–A11) | 297c18a (PR #4) | 35/35 · qmllint 0 · qml6 6s sans binding loop | Flickable+clip+scroll+ensureVisible ; carte +md*2. Review+Security APPROVED. Bump patch 0.3.1. **Test manuel 30 profils à faire.** |
| 2026-09-05 | Lot 6 (A15–A18) | 2dda901 (PR #5) | 30/30 · qmllint 0 | -235 lignes code mort. Review+Security APPROVED. Bump patch 0.3.2. ⚠️ Conflit CHANGELOG/version attendu vs PR#4 (ordre de merge). |
| 2026-09-05 | Lot 5 (A12–A13) + Lot 7 (A19) | _(à compléter)_ | 36/36 · qmllint 0 · PoC BASH_ENV fermé + refus homonymes | Branche partie du Lot 6. clearEnvironment (BASH_ENV neutralisé), PATH_TAIL resserré, identité par sessionPath (refus sur homonymes, nom re-dérivé). Review+Security APPROVED. Bump minor 0.4.0. A14 (optionnel) non fait. |
