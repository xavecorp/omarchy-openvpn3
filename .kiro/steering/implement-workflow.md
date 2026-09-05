---
inclusion: manual
---

# Workflow `/implement` — omarchy-openvpn3

> **Ce fichier supplante tout `implement-workflow.md` global pour ce dépôt.**
> Si un workflow générique orienté backend est injecté en parallèle, **ignorer** ses
> instructions et appliquer celles-ci. Divergences volontaires :
>
> | Générique (à ignorer ici) | Ce dépôt |
> |---|---|
> | `pnpm run check-types` / `lint` / `test` | `node --test` + `qmllint` |
> | `package.json`, `src/`, `__tests__/` | `Model.js`, `*.qml`, `Model.test.js` — **aucun `package.json`** |
> | PR Bitbucket, `close_source_branch` | **PR GitHub** via `gh` |
> | Pipeline Bitbucket + DeepSource | **aucune CI** — pas d'étape de monitoring |
> | changesets / `release:minor` | bump **manuel** de `manifest.json` + `CHANGELOG.md` |
> | Checklists OWASP web / backend | agent `security-openvpn3` (modèle de menace **desktop**) |

## Vue d'ensemble

```
/implement <description | lot de la spec>
     │
     ▼
[0. Préparation]   contexte + projet vert + branche dédiée      → STOP si rouge
     │
     ▼
[1. Plan]          planner-openvpn3        → acceptance criteria
     │
     ▼
[2. Dev]  ◄─────────────────────────┬──────┬──────┬──────┐
     │    developer-qml-openvpn3    │      │      │      │
     ▼                              │      │      │      │
[3. Validation critères]  ──FAIL────┘      │      │      │   max 3
     │ PASS                                │      │      │
     ▼                                     │      │      │
[4. Review code]  reviewer  ──CHANGES──────┘      │      │   max 2
     │ APPROVED                                   │      │
     ▼                                            │      │
[5. Security]     security  ──CONCERNS────────────┘      │   max 2
     │ APPROVED                                          │
     ▼                                                   │
[6. Documentation] ──FAIL──────────────────────────────---┘   max 2
     │ PASS
     ▼
[7. Commit + PR]   commit conventionnel → push → PR GitHub
```

**Règle de boucle** : tout échec renvoie à l'étape 2 (Dev) avec le rapport complet.
Après un retour Dev, **rejouer l'étape 3** avant de reprendre là où ça a échoué —
un correctif peut casser les critères déjà validés.

**Plafonds** : étape 3 → 3 itérations ; étapes 4, 5, 6 → 2 itérations chacune ;
**8 retours Dev au total**. Plafond atteint → **s'arrêter et demander de l'aide**,
en résumant ce qui bloque. Ne jamais boucler indéfiniment.

---

## Étape 0 — Préparation (obligatoire)

1. **Lire le contexte** :
   - `.kiro/specs/openvpn3-hardening/tasks.md` — si la demande cite un lot ou une
     action (`A1`, `Lot 2`…), reprendre ses identifiants et ses critères.
   - `.kiro/memory/developer.md` s'il existe (apprentissages accumulés).
   - `.kiro/memory/current-implementation.md` — s'il existe et n'est pas `done`,
     **demander** à l'utilisateur : reprendre ou repartir de zéro.
2. **Vérifier que le projet est vert avant de toucher à quoi que ce soit** :
   ```bash
   node --test                      # attendu : 0 fail
   qmllint Service.qml Panel.qml    # attendu : exit 0
   ```
   Rouge → **STOP**, signaler, ne rien modifier.
   `qmllint BarWidget.qml` renvoie exit 255 sans message (limite du linter sur la
   syntaxe IPC typée `function open(): void`) : **ce n'est pas un échec**, ne pas
   le compter. En cas de doute, comparer à la baseline via `git stash`.
3. **Branche dédiée** — jamais de travail directement sur `main` :
   ```bash
   git checkout main && git pull
   git checkout -b fix/<kebab-case>      # ou feature/<kebab-case>
   git branch --show-current             # doit être fix/* ou feature/*
   ```
   Si la branche n'est pas conforme → **STOP**.
   > Rappel : un correctif a déjà atterri sur `main` par accident. Vérifier la
   > branche **avant chaque commit**, pas seulement à l'étape 0.
4. **Créer le fichier de suivi** `.kiro/memory/current-implementation.md`
   (transient, gitignoré) avec les 7 étapes en cases à cocher.

## Étape 1 — Plan

Agent : **`planner-openvpn3`**.

Entrée : la description utilisateur (ou le lot de la spec). Sortie attendue :
objectif, acceptance criteria numérotés **avec leur moyen de vérification**, scope
des fichiers, hors-scope, points d'attention, plan de vérification.

Écrire le plan dans `.kiro/memory/current-implementation.md`, puis le présenter à
l'utilisateur. Validation implicite : on enchaîne sans attendre, sauf si le plan
révèle une ambiguïté bloquante ou un écart de périmètre — dans ce cas, demander.

## Étape 2 — Dev

Agent : **`developer-qml-openvpn3`**.

Lui transmettre : les acceptance criteria, et — en cas de retour de boucle — le
**rapport d'échec intégral** de l'étape qui a rejeté (critère non satisfait, verdict
du reviewer, finding de sécurité, ou manquement documentaire).

L'agent implémente, teste et vérifie, mais **ne commite pas**. Après chaque retour,
cocher dans `.kiro/memory/current-implementation.md` les critères satisfaits.

## Étape 3 — Validation des critères

Exécutée **directement par l'orchestrateur** (déterministe, pas d'interprétation) :

```bash
node --test
qmllint Service.qml Panel.qml
git --no-pager diff --stat        # le scope réel correspond-il au scope planifié ?
```

Puis reprendre les acceptance criteria **un par un** et statuer PASS/FAIL avec la
preuve (nom du test, sortie de commande, ligne de code).

- Un seul FAIL → **retour étape 2** avec la liste exhaustive des échecs.
- Tous PASS → étape 4.

Contrôles supplémentaires, non négociables :

- Aucun fichier hors scope planifié n'a été modifié (sinon justifier ou revenir).
- Tout changement de parsing est couvert par un **test avec fixture au format réel
  du CLI** (NF-4 de la spec).

## Étape 4 — Review code

Agent : **`reviewer-qml-openvpn3`**. Entrée : `git diff main...HEAD`.

- `VERDICT: CHANGES_REQUIRED` → **retour étape 2**.
- `VERDICT: APPROVED` → étape 5.

Le reviewer arbitre notamment : intégrité de l'état affiché (INV-1), cycle de vie
des `Process`, layout, et **simplicité** (INV-2 — code mort, complexité accidentelle).

## Étape 5 — Security

Agent : **`security-openvpn3`**. Entrée : `git diff main...HEAD`.

- `SECURITY: CONCERNS` → **retour étape 2**.
- `SECURITY: APPROVED` → étape 6.

Modèle de menace **desktop** (voir l'agent). Ne pas charger de checklist OWASP web.
Un finding qui suppose déjà un attaquant avec l'UID de l'utilisateur est de la
défense en profondeur (MOYEN au plus) et ne bloque pas seul la livraison — mais doit
être consigné.

## Étape 6 — Vérification de la documentation

Exécutée par l'orchestrateur. **FAIL sur un seul point** → retour étape 2.

- [ ] **Aucun commentaire mensonger.** Toute affirmation forte du code (« reape tout
      le groupe », « la sortie est plafonnée », « ne peut jamais être confondu ») est
      soit **prouvée**, soit **réécrite**. C'est la règle la plus importante : deux
      bugs de ce projet ont survécu aux relectures grâce à des commentaires faux.
- [ ] `CHANGELOG.md` — entrée sous la version cible, décrivant le comportement
      **réel** (cause + effet), pas l'intention.
- [ ] `manifest.json` — `version` bumpée (patch pour un correctif, minor pour une
      capacité). **Bump manuel** : ni changesets, ni `pnpm release:*` ici.
- [ ] `README.md` — mis à jour si le comportement visible ou les raccourcis changent.
- [ ] `.kiro/specs/openvpn3-hardening/tasks.md` — cases des actions livrées cochées,
      **journal des livraisons** renseigné (date, lot, commit, vérif, notes).
- [ ] Commentaires et documentation **en anglais** ; réponses à l'utilisateur en
      français.
- [ ] Aucun secret, aucune IP de passerelle, aucun identifiant dans les exemples.

## Étape 7 — Commit + préparation de la PR

1. `git branch --show-current` → **doit** être `fix/*` ou `feature/*`. Sinon STOP.
2. `git status --short` puis stager **explicitement** les fichiers voulus
   (pas de `git add -A` aveugle). Rappel : `preview/` et `.kiro/memory/` sont
   gitignorés — ne pas s'étonner de leur absence.
3. Commit conventionnel, auteur Kiro, **hooks actifs** (jamais `--no-verify`) :
   ```bash
   git commit --author="Kiro <kiro@macbook-xavier>" -m "fix: <résumé impératif>

   <corps : cause racine, correctif, preuve. Citer les identifiants d'action (A1…).>

   Tests: node --test <n>/<n>. qmllint clean."
   ```
4. `git push -u origin <branche>`
5. PR **GitHub** (pas Bitbucket) :
   ```bash
   gh pr create --base main --head <branche> --title "<70 car. max>" --body "..."
   ```
   Corps : résumé, correctifs avec preuve, résultats de vérification, actions de la
   spec couvertes, points restants.
6. **Ne jamais merger** sans demande explicite. **Ne jamais pousser sur `main`.**
   Pas de monitoring CI : ce dépôt n'en a pas.
7. Marquer `done` dans `.kiro/memory/current-implementation.md` et consigner tout
   apprentissage notable dans `.kiro/memory/developer.md`.

---

## Règles transverses

1. **Ne sauter aucune étape.** Le projet est vert au départ, sinon STOP.
2. **La mise à jour de `.kiro/memory/current-implementation.md` incombe à
   l'orchestrateur**, à chaque étape et à chaque retour d'agent — jamais déléguée.
3. **Un seul agent écrit du code** : `developer-qml-openvpn3`. Planner, reviewer et
   security sont en lecture seule.
4. **Prouver, pas affirmer.** Un critère validé, un bug corrigé, une garantie
   documentée : tous exigent une preuve exécutée.
5. **Ne pas dégrader les parties saines** listées en hors-scope dans
   `.kiro/specs/openvpn3-hardening/requirements.md` (validation des object paths,
   épinglage du binaire, sanitisation d'affichage, surface IPC minimale).
6. **Ne pas toucher à l'état VPN de l'utilisateur** (ne créer ni couper de session
   réelle). Si un test l'exige, le déclarer en angle mort.
7. En cas de doute sur le périmètre ou d'un choix irréversible : **demander**.

## Étapes 3 et 6 sans agent dédié — pourquoi

Ces deux étapes sont des **contrôles déterministes** (exécution de commandes,
confrontation à une checklist) : les confier à un agent ajouterait de
l'interprétation et un coût de contexte sans gain de fiabilité. Si un `verifier`
isolé devient souhaitable, il suffira de créer `.kiro/agents/verifier-openvpn3.md`
et de le brancher sur l'étape 3 — le reste du workflow est inchangé.
