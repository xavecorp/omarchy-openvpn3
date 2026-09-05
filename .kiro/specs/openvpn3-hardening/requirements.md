# Durcissement omarchy-openvpn3 — Exigences

**Origine** : revue complète du plugin au commit `7b96028` par trois auditeurs
(QML/Quickshell, openvpn3/UX, sécurité offensive), avec arbitrage et vérification
indépendante des constats les plus graves.

**Statut de départ** : 19 actions identifiées, réparties en 7 lots. Aucune n'est
appliquée. Chaque lot est autonome et peut être livré séparément.

## Verdict initial

| Critère | Verdict au commit `7b96028` |
|---|---|
| Intégrité système | ❌ Compromise — fuite de processus prouvée (openvpn3 orphelin ~20 % CPU) |
| Sécurité | ⚠️ Pas d'injection exploitable (14 charges rejetées), mais épuisement mémoire prouvé |
| Simplicité | ❌ Non atteinte — ~200 lignes mortes sur 986, 3 commentaires mensongers |

## Invariants produits

Ces deux règles arbitrent tout arbitrage de conception :

1. **INV-1 — L'UI ne doit jamais mentir sur la protection.** Ce plugin répond à une
   seule question : « suis-je protégé ? ». Tout mode de défaillance doit dégrader
   vers « inconnu / erreur », **jamais** vers « connecté ».
2. **INV-2 — Simplicité.** Le plugin est une interface minimale vers `openvpn3`.
   Toute propriété, fonction ou timer jamais lu doit être supprimé, pas documenté.
   Aucun commentaire ne doit promettre une garantie non tenue.

## Exigences fonctionnelles

- **EX-1** L'état affiché par profil reflète le statut réel rapporté par openvpn3,
  y compris les états d'échec (authentification, pause, reconnexion, timeout).
- **EX-2** Le plugin fonctionne correctement avec **plusieurs sessions actives**
  simultanées (openvpn3 l'autorise sur des profils distincts).
- **EX-3** Les profils nécessitant une authentification interactive (user-locked,
  2FA, static-challenge) sont utilisables — c'est le cas d'usage principal.
- **EX-4** La liste de profils reste entièrement navigable et lisible quel que soit
  le nombre de profils.
- **EX-5** Un échec de lecture du CLI conserve la dernière vue valide et signale
  l'erreur, sans vider la liste silencieusement.

## Exigences non fonctionnelles

- **NF-1 Intégrité système** — aucune invocation du CLI ne laisse de processus
  orphelin après expiration, watchdog ou destruction du composant.
- **NF-2 Bornage mémoire** — la sortie retenue du CLI est plafonnée **avant**
  bufferisation, stdout **et** stderr.
- **NF-3 Non-régression sécurité** — les défenses existantes sont préservées :
  validation des object paths, épinglage du binaire en chemin absolu, sanitisation
  de tout texte affiché, surface IPC minimale.
- **NF-4 Vérifiabilité** — tout changement de parsing est couvert par un test
  `node --test` avec une fixture au format réel du CLI.
- **NF-5 Honnêteté documentaire** — commentaires et CHANGELOG décrivent le
  comportement réel.

## Périmètre

**Dans le périmètre** : `Model.js`, `Model.test.js`, `Service.qml`, `Panel.qml`,
`BarWidget.qml`, `CHANGELOG.md`, `manifest.json`, `preview/Preview.qml` (gitignoré).

**Hors périmètre — à ne pas dégrader** (parties jugées saines par les trois auditeurs) :

- Validation des object paths D-Bus (`Model.validatePath`, `PATH_TAIL`) et
  sanitisation d'affichage (`Model.clip*`, `Text.PlainText` partout).
- Épinglage du binaire openvpn3 sur une allowlist de chemins absolus (pas de `PATH`).
- Construction d'argv sans interpolation shell (positionnels `"$@"`).
- Surface IPC réduite à `open/close/toggle/refresh` (aucun connect/disconnect exposé).
- Ancrage top-only du `ColumnLayout` de `Panel.qml` (correct, pas de boucle de binding).
- Le fait que le tunnel survive au rechargement du shell (propriété du service D-Bus).

## Vérification

Le projet n'a **ni `package.json`, ni `pnpm`, ni `src/`**.

```bash
node --test                      # parseurs Model.js
qmllint Service.qml Panel.qml    # exit 0 attendu, sans warning
```

`qmllint BarWidget.qml` renvoie **exit 255 sans message** — limite du qmllint
installé sur la syntaxe IPC typée `function open(): void`, identique sur la
baseline. Ce n'est pas un défaut du plugin et ne compte pas comme échec.

## Faits de référence établis (ne pas re-découvrir)

- `openvpn3 sessions-list` **n'a pas** de mode `--json` ; `configs-list --json` oui.
- `"disconnected"` contient la sous-chaîne `"connected"`.
- Les blocs de `sessions-list` ne sont **pas** systématiquement séparés par un
  séparateur ; délimiter sur la ligne `Path:` est robuste aux deux formats.
- openvpn3 refuse deux sessions sur un même profil, mais `sessions-list` n'expose
  pas le config path d'une session → appariement par nom inévitable.
- `cmd | head -c N` ne borne que stdout ; supprimer un collecteur stderr ne suffit pas.
- `timeout --kill-after` n'envoie jamais le KILL si son enfant direct meurt sur TERM.
- `bash -c` lit `BASH_ENV`.
