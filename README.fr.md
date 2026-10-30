# fxaudit

**Trouve ce qui plante, ce qui fuit et ce qui rend ton serveur FiveM exploitable, avant tes joueurs.**

fxaudit est un analyseur statique de ressources FiveM, écrit en Lua 5.4 pur, sans aucune dépendance.
Il comprend le dialecte CfxLua, le `fxmanifest.lua`, la séparation client/serveur et plus de 7 000 natives.

[English version](README.md)

## Pourquoi

- **Pour les fondateurs :** vérifie un script acheté ou téléchargé avant de l'installer, avec un score par ressource.
- **Pour les développeurs :** repère les variables non définies, les fuites et les events exploitables, dans ton terminal ou en CI.
- **Sûr par conception :** fxaudit n'exécute jamais ce qu'il analyse, ni le manifest, ni son propre fichier de configuration.

## Ce qu'il détecte

| Catégorie | Exemples |
|---|---|
| **Syntaxe** | toutes les erreurs d'un fichier d'un coup, avec la ligne du bloc resté ouvert |
| **Variables** | globales non définies entre fichiers, fuites de globales, locales inutilisées ou masquées, usage avant déclaration, fautes de frappe avec suggestion, natives client appelées côté serveur |
| **Logique** | `not a == b`, `x == 1 or "b"`, code inatteignable, clés de table en double, suppression pendant une boucle, mauvais arguments de `string.format` |
| **Sécurité** | données du client atteignant argent, items ou commandes sans contrôle, `source` lu après un `Wait`, injection SQL, code téléchargé puis exécuté, obfuscation, webhooks exposés |
| **Performance** | `while true` sans `Wait`, boucles permanentes à chaque frame, SQL dans une boucle, diffusion à tous dans une boucle rapide |
| **Fuites** | handlers enregistrés en boucle, tables de joueurs jamais nettoyées, modèles et DUI non libérés, focus NUI bloqué |
| **Manifest** | fichiers manquants, globs sans résultat, pages UI non déclarées, imports `@ressource/fichier` cassés |
| **Events** | `RegisterNetEvent` manquant, handlers ou exports inexistants |

`fxaudit rules` liste les 80+ règles, et `fxaudit explain FX400` détaille l'une d'elles.

## Installation

Il faut [Lua 5.4](https://www.lua.org/download.html). Sous Windows : `winget install DEVCOM.Lua`.

```sh
git clone https://github.com/badidu09/fxaudit.git
cd fxaudit
lua bin/fxaudit scan C:/chemin/vers/resources
```

## Utilisation

```sh
fxaudit scan ./resources                    # tout un dossier de serveur
fxaudit scan ./resources/mon_script         # ou une seule ressource
fxaudit scan . -s high                      # seulement high et critical
fxaudit scan . --all                        # ajoute les remarques de niveau info
fxaudit scan . -f json -o rapport.json      # sortie pour un script
fxaudit scan . -f sarif -o fxaudit.sarif    # GitHub code scanning
```

Pour ignorer une alerte : `-- fxaudit-ignore FX203` sur la ligne concernée ou juste au-dessus, ou `-- fxaudit-ignore-file FX202` pour tout le fichier.

La configuration (`.fxaudit.lua`) et la GitHub Action sont décrites dans le [README anglais](README.md#configuration).

## Limites

À lire avant de te fier à un score.

- **Un bon score ne prouve pas qu'une ressource est sûre.** L'analyse statique ne voit pas tout, et un attaquant déterminé peut lui cacher du code.
- **Les fichiers protégés ne sont pas analysés.** Les fichiers escrow et précompilés sont signalés par `FX710`, et fxaudit ne dit rien de ce qu'ils font. Il n'essaiera jamais de les déchiffrer.
- **Il existe des faux positifs.** Certaines alertes portent la mention `(medium confidence)` ou `(low confidence)` : ce sont des endroits à regarder, à ignorer quand ils sont faux.
- **L'analyse reste dans une seule fonction.** Ce que fait une fonction appelée n'est pas suivi.
- **Seul le Lua est analysé.** Les scripts JavaScript et C# ne sont pas lus.
- **Rien ne tourne en jeu.** fxaudit n'a pas été lancé dans FXServer : il travaille sur les fichiers, en ligne de commande.

## Licence

[MIT](LICENSE)
