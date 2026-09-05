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

> Viole actuellement INV-1 : l'UI peut afficher « Connected » sur un tunnel mort.

- [ ] **A1** 🔴 Remplacer la détection `connected` par sous-chaîne par un mapping
      explicite du StatusMinor — `Model.js:329`
  - [ ] `sessionStateFromStatus()` ajouté, ancré sur `\bclient connected\b`
  - [ ] `disconnect` testé **après** `client connected` ; défaut final ≠ `connected`
  - [ ] Tests : `Client disconnected`, `Client disconnected by server`,
        `Client disconnecting` → **pas** connecté
  - [ ] Vérif : `node --test` vert, nouveau test nommé présent

- [ ] **A2** 🔴 Délimiter les blocs de `sessions-list` sur la ligne `Path:` (et non
      le séparateur) — `Model.js:269-322`
  - [ ] Flush de l'accumulateur sur nouvelle ligne `Path:` **ou** séparateur
  - [ ] Fixture 2 sessions ajoutée → `sessions.length === 2`, la connectée conservée
  - [ ] Le cas 1 session (fixture existante) reste vert
  - [ ] Vérif : `activeSessionName` renvoie bien la session **connectée**

- [ ] **A3** 🟠 Étendre les états rendus : auth requise, pause, reconnexion, échec
      — `Model.js:368-373`, `Model.stateLabel`, `Panel.qml:59-64`
  - [ ] `sessionState` consomme le mapping de A1
  - [ ] `stateLabel` couvre : Identifiants requis / En pause / Reconnexion… /
        Échec d'authentification / Échec
  - [ ] `colorForState` couvre les nouveaux états (aucun ne tombe en vert)
  - [ ] Tests de table statut → label

- [ ] **A4** 🟠 Ne jamais dégrader vers « connected » ; honorer `configsResult.ok`
      — `Service.qml:110-113`, `:230-233`
  - [ ] `Service.state` : défaut `connecting`/`error` quand la ligne est introuvable
  - [ ] Sur `ok === false` : `lastError` posé **et vue précédente conservée**
        (la liste ne se vide pas)
  - [ ] Test : JSON invalide → `ok:false` (déjà couvert), + vérif du non-écrasement

**Vérification de lot** : `node --test` vert · `qmllint` exit 0 · aucun état ne peut
afficher vert sans `client connected`.

---

## Lot 2 — Intégrité système / processus

> Viole actuellement NF-1 et NF-2 : orphelin à ~20 % CPU, stderr non borné.

- [ ] **A5** 🔴 Supprimer la fuite de processus sur `session-start`
      — `Service.qml:26-31, 78-99, 98-104`
  - [ ] Option retenue : `openvpn3 session-start --timeout SECS` (préférée, cf. A9)
        **ou** `--signal=KILL` sur `timeout`
  - [ ] PoC de non-régression : enfant `trap '' TERM` → **aucun survivant** après
        expiration (ne pas tester avec `sleep`, il meurt sur TERM)
  - [ ] `ps`/`pgrep` : aucun `openvpn3` orphelin après un échec de connexion
  - [ ] Commentaires corrigés (→ A18)

- [ ] **A6** 🟠 Borner stderr **in-band** — `Service.qml:96-97, 400, 436, 461, 465-467`
  - [ ] `capScriptRead` = `2>/dev/null | head -c N` (lectures)
  - [ ] `capScriptAction` = `2>&1 | head -c N` (action)
  - [ ] ⚠️ **`2>&1` jamais appliqué à `configs-list --json`** (corromprait le JSON)
  - [ ] `configsErr`/`sessionsErr` supprimés ; `_actionOutput = boundStored(actionOut.text)`
  - [ ] PoC : flood stderr → RSS quickshell stable (attendu ≈ +0 Mo)

- [ ] **A7** 🟠 Garder `probeProcess` contre la destruction — `Service.qml:203-212, 185-194`
  - [ ] `if (root._destroyed) return` dans `probeProcess.onExited`
  - [ ] `if (root._destroyed) return` dans `probeNext()`

- [ ] **A8** 🟠 Recalibrer le watchdog de lecture — `Service.qml:65, 228, 357`
  - [ ] Réarmement au démarrage de **chaque** Process (préféré) ou intervalle ≥ 27 s
  - [ ] Plus de faux « openvpn3 stopped responding » quand chaque commande respecte
        son propre plafond de 12 s

**Vérification de lot** : PoC orphelin **et** PoC stderr rejoués · `node --test` vert.

---

## Lot 3 — Cas d'usage principal (profils user-locked / 2FA)

> Viole actuellement EX-3. `testamento-profile-userlocked` = le cas d'usage réel.

- [ ] **A9** 🟠 Déléguer `session-start` au terminal flottant — `Service.qml:456-476`
  - [ ] Patron du shell hôte réutilisé (`bar.run` +
        `omarchy-launch-floating-terminal-with-presentation`, argument **quoté**)
  - [ ] Statut `requires user input` → « Identifiants requis » + action
        « Ouvrir un terminal » (plus de « Connecting… » infini)
  - [ ] Plus de blocage de 40 s ; plus de `lastError` affichant un chemin D-Bus
  - [ ] Nettoyage induit : `actionTimeoutSec`, branche 40 s, `_actionOutput`/`firstLine`
        si devenus inutiles
  - [ ] Décider du sort de `actionWatchdog` (**redevient utile** si `timeout` est
        retiré de `session-start`) et le documenter
  - [ ] Test manuel sur un profil demandant des identifiants

**Vérification de lot** : un profil user-locked se connecte réellement · aucun
orphelin après la tentative.

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
| — | — | — | — | *(à remplir au fil des passes)* |
