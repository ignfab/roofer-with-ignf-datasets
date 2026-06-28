# Utiliser roofer avec les jeux de données de l'IGN

**Langue:** [🇬🇧 English](README.md) · [🇫🇷 Français](README.fr.md)

Ce dépôt est un exemple minimal, pensé en priorité pour Docker, qui montre comment utiliser [roofer](https://github.com/3DBAG/roofer) avec les jeux de données de l'[IGN](https://github.com/IGNF) ([BD TOPO](https://cartes.gouv.fr/rechercher-une-donnee/dataset/IGNF_BD-TOPO) et [LIDAR HD](https://cartes.gouv.fr/rechercher-une-donnee/dataset/IGNF_NUAGES-DE-POINTS-LIDAR-HD)) pour produire des bâtiments 3D en LOD2.2. C'est un point de départ pour expérimenter.

`roofer` est l'outil de reconstruction de [3DBAG](https://3dbag.nl/en/viewer) qui transforme des emprises de bâtiments et des nuages de points en modèles de bâtiments 3D. Le projet plus large [3dbag-pipeline](https://github.com/3DBAG/3dbag-pipeline) montre comment ces outils sont utilisés dans des chaînes de traitement de production plus importantes. Ce dépôt se concentre sur un exemple beaucoup plus restreint : partir d'une emprise (*bounding box*) en Lambert-93, télécharger les données IGN nécessaires depuis sa [Géoplateforme](https://www.ign.fr/geoplateforme), et préparer les entrées requises pour exécuter `roofer` et produire des bâtiments 3D.

Le déroulé de ce projet est le suivant :

1. Partir d'une emprise (*bounding box*) en Lambert-93 (`EPSG:2154`)
2. Télécharger les bâtiments `BDTOPO_V3:batiment` depuis le [WFS de l'IGN](https://cartes.gouv.fr/aide/fr/guides-utilisateur/utiliser-les-services-de-la-geoplateforme/diffusion/wfs/) avec prise en charge de la pagination
3. Calculer l'étendue réelle des bâtiments téléchargés
4. Ajouter une zone tampon (*buffer*) configurable autour de cette étendue
5. Interroger `IGNF_NUAGES-DE-POINTS-LIDAR-HD:dalle` depuis le [WFS de l'IGN](https://cartes.gouv.fr/aide/fr/guides-utilisateur/utiliser-les-services-de-la-geoplateforme/diffusion/wfs/) avec prise en charge de la pagination
6. Construire une chaîne de traitement (*pipeline*) PDAL qui diffuse exactement le LiDAR couvrant l'étendue tamponnée, découpé à partir des dalles COPC intersectées
7. Remapper la classification LIDAR HD `67 -> 6`, car `roofer` suit le standard ASPRS LAS et ne considère que la classe `6` comme *bâtiment*, alors que le LIDAR HD de l'IGN place aussi des points de bâtiment dans sa classe non standard `67` (*Divers - bâtis*, c'est-à-dire les structures bâties diverses) ; sans ce remappage, ces points seraient invisibles pour `roofer` et perdus pour la reconstruction des toits
8. Nettoyer et compléter les attributs d'altitude du sol et du toit des bâtiments, sur lesquels `roofer` se rabat lorsqu'une emprise a trop peu de points sol (pour l'altitude du plancher) ou de points toit (pour la hauteur du toit)
9. Exécuter `roofer` sur le fichier LAZ obtenu et le GeoPackage des bâtiments nettoyé


<p align="center">
  <a href="docs/imgs/workflow.png" target="_blank"><img src="docs/imgs/workflow.png" alt="Déroulé du traitement" width="700"></a>
</p>

L'objectif est de garder le code et la configuration utilisateur aussi simples que possible. La machine hôte n'a besoin que de [Docker](https://www.docker.com/).

## Périmètre

- Hôte Linux ou macOS (le traitement lui-même s'exécute toujours dans un conteneur Linux)
- Docker uniquement
- L'emprise d'entrée doit être en `EPSG:2154` pour le moment
- Une seule emprise à la fois
- Pas d'installation locale native

## Prérequis

- Docker installé et disponible dans le `PATH` (Docker Engine sur Linux, Docker Desktop sur macOS)
- Un `bash` POSIX pour exécuter `run.sh` (macOS est livré avec bash 3.2, ce qui est suffisant)
- Un accès réseau vers :
  - `https://data.geopf.fr`
  - les URL de stockage COPC renvoyées par le WFS des dalles LiDAR
  - Docker Hub pour récupérer `3dgi/3dbag-pipeline-tools:2026.06.24`

## Démarrage rapide

Exemple d'exécution du traitement avec une emprise en Lambert-93 centrée sur [Les Espaces d'Abraxas à Noisy-le-Grand](https://cartes.gouv.fr/explorer-les-cartes?c=2.542793,48.839983&z=18&l=ORTHOIMAGERY.ORTHOPHOTOS$GEOPORTAIL:OGC:WMTS(1;1;1;0)&w=&permalink=yes) :

```bash
./run.sh --bbox 666201 6859851 666701 6860351
```

Avec une zone tampon personnalisée (la valeur par défaut est `10` mètres) et un répertoire racine de sortie personnalisé (la valeur par défaut est `./output`) :

```bash
./run.sh --bbox 666201 6859851 666701 6860351 --buffer 15 --out ./example-output
```

Les fichiers de résultats `CityJSONSeq` générés dans `output/run-*/roofer_output/` ou `example-output/run-*/roofer_output/` peuvent être ouverts directement dans [ninja.cityjson.org](https://ninja.cityjson.org/).

<p align="center">
  <img src="docs/imgs/ninja.png" alt="Chargement du fichier CityJSONSeq généré sur ninja.cityjson.org" width="700">
</p>
<p align="center"><em>Ouvrez ou glissez-déposez la sortie CityJSONSeq générée directement dans ninja.cityjson.org.</em></p>

<p align="center">
  <img src="docs/imgs/ninja_viewer.png" alt="Sortie de roofer affichée dans la visionneuse ninja.cityjson.org" width="700">
</p>
<p align="center"><em>Inspectez les bâtiments reconstruits de manière interactive dans la visionneuse.</em></p>

<details>
<summary><strong>Prise en charge des proxy d'entreprise</strong></summary>

Pour la plupart des utilisateurs, il n'y a rien à configurer.

Si vous exécutez ce traitement depuis le réseau de l'IGN ou d'autres réseaux derrière un proxy d'entreprise, exportez vos variables de proxy dans le shell avant d'appeler `run.sh` si elles ne sont pas déjà définies. Le script `run.sh` les transmet à Docker.

Exemple :

```bash
export HTTPS_PROXY=http://proxy.example.com:8080
export HTTP_PROXY=http://proxy.example.com:8080
export NO_PROXY=localhost,127.0.0.1

./run.sh --bbox 666201 6859851 666701 6860351
```

</details>

## Sorties

Le traitement écrit tous les artefacts intermédiaires dans un répertoire d'exécution dédié sous le répertoire racine de sortie (`--out`), afin que le processus reste facile à inspecter et à déboguer. Chaque répertoire d'exécution est nommé `run-YYYYMMDD-HHMMSS`. Les répertoires d'exécution existants contenant des artefacts antérieurs sont refusés par défaut ; passez `--clean` pour vider les répertoires d'exécution marqués avant l'exécution.

Fichiers attendus dans chaque répertoire d'exécution :

- `buildings.gpkg` : emprises de bâtiments téléchargées depuis `BDTOPO_V3:batiment` en `EPSG:2154` et normalisées en `MULTIPOLYGON`
- `building_bbox.json` : l'étendue réelle des bâtiments calculée à partir de la couche de bâtiments téléchargée
- `buffered_bbox.json` : l'étendue des bâtiments après application de la zone tampon définie par l'utilisateur
- `lidar_tiles.gpkg` : les entités de dalles LiDAR renvoyées par `IGNF_NUAGES-DE-POINTS-LIDAR-HD:dalle` pour l'emprise tamponnée
- `pdal_pipeline.json` : la chaîne de traitement PDAL générée
- `lidar_subset.laz` : le sous-ensemble LiDAR découpé écrit par PDAL pour l'emprise tamponnée, avec la classe `67` remappée en `6`
- `buildings_cleaned.gpkg` : les emprises de bâtiments après nettoyage et complétion des attributs, utilisées comme source de polygones pour `roofer`
- `roofer_output/` : la sortie finale au format [CityJSONSeq](https://www.cityjson.org/cityjsonseq/) produite par `roofer`
- `.roofer-run-output` : marqueur utilisé par `run.sh` pour identifier les répertoires d'exécution qu'il est autorisé à nettoyer avec `--clean`

## Ce que font les scripts

### `run.sh`

Point d'entrée côté hôte qui :

- valide les arguments de la ligne de commande
- crée le répertoire racine de sortie et le répertoire de sortie par exécution sur l'hôte
- marque les répertoires d'exécution avec `.roofer-run-output`
- refuse les répertoires d'exécution non vides et non marqués, même lorsque `--clean` est passé
- refuse les répertoires d'exécution marqués contenant des artefacts d'exécution existants, sauf si `--clean` est passé
- transmet les variables d'environnement liées au proxy à Docker
- lance le traitement dans le conteneur

Ligne de commande :

```text
./run.sh --bbox xmin ymin xmax ymax [--buffer meters] [--out path] [--jobs n] [--clean]
```

Arguments :

- `--bbox xmin ymin xmax ymax` requis, emprise d'entrée en `EPSG:2154`
- `--buffer` optionnel, entre `0` et `500` mètres, par défaut `10` mètres
- `--out` optionnel, par défaut `./output` ; c'est le répertoire racine de sortie qui contient les répertoires d'exécution
- `--jobs` optionnel, transmis à `roofer -j`, par défaut `nproc - 1` avec un minimum de `1`
- `--clean` optionnel, vide les répertoires d'exécution marqués sous `--out`

### `scripts/run_workflow.sh`

Traitement côté conteneur qui :

- vérifie que `ogr2ogr`, `ogrinfo`, `pdal`, `roofer`, `python3`, `awk` et `sed` sont présents dans l'image d'exécution
- télécharge les bâtiments depuis `BDTOPO_V3:batiment`
- calcule l'étendue réelle des bâtiments
- applique une zone tampon à cette étendue
- télécharge les emprises de dalles LiDAR depuis `IGNF_NUAGES-DE-POINTS-LIDAR-HD:dalle`
- lit les URL COPC depuis l'attribut `url` des dalles
- génère `pdal_pipeline.json` pour extraire la portion de bâtiment nécessaire à la reconstruction
- exécute `pdal pipeline`
- nettoie et complète les attributs des bâtiments avec `set_building_attributes.sh` (nécessite `sqlite3`)
- exécute `roofer`

### `scripts/build_pdal_pipeline.py`

Petit utilitaire Python qui :

- lit le jeu de données local des emprises de dalles LiDAR avec `ogrinfo -json`
- lit les URL COPC depuis la propriété `url` définie dans le schéma
- génère une chaîne de traitement PDAL avec un `readers.copc` par dalle

Ligne de commande :

```text
python3 scripts/build_pdal_pipeline.py \
  --tiles lidar_tiles.gpkg \
  --layer lidar_tiles \
  --bbox xmin ymin xmax ymax \
  --output-pipeline pdal_pipeline.json \
  --laz-output lidar_subset.laz
```

Arguments :

- `--tiles` : chemin vers le jeu de données local des emprises de dalles LiDAR, typiquement le `lidar_tiles.gpkg` généré
- `--layer` : nom de la couche d'emprises de dalles LiDAR à lire dans `--tiles` (par ex. `lidar_tiles`)
- `--bbox` : emprise d'extraction tamponnée en `EPSG:2154`, utilisée comme `bounds` PDAL sur chaque `readers.copc`
- `--output-pipeline` : chemin du `pdal_pipeline.json` généré
- `--laz-output` : chemin du fichier LAZ découpé écrit par la chaîne de traitement PDAL générée

### `scripts/set_building_attributes.sh`

Post-traite un GeoPackage de bâtiments pour nettoyer et compléter les attributs d'altitude du sol et du toit sur lesquels `roofer` se rabat lorsqu'une emprise a trop peu de points sol (pour l'altitude du plancher) ou de points toit (pour la hauteur du toit).

Le script :

- supprime les entités ayant des géométries NULL
- complète l'altitude minimale du sol manquante à partir de l'altitude maximale du sol
- complète l'altitude maximale du sol manquante à partir de l'altitude minimale du sol
- complète l'altitude minimale du toit manquante à partir de l'altitude maximale du toit
- complète l'altitude maximale du toit manquante à partir de l'altitude minimale du toit
- calcule la hauteur de bâtiment manquante avec :
  `altitude maximale du toit - altitude minimale du sol`
- reconstruit les altitudes de toit manquantes avec :
  `altitude du sol + hauteur du bâtiment`
- reconstruit les altitudes de sol manquantes avec :
  `altitude du toit - hauteur du bâtiment`

Ligne de commande :

```text
bash scripts/set_building_attributes.sh \
  --input buildings.gpkg \
  --output buildings_cleaned.gpkg \
  --layer buildings \
  --ground-min-field altitude_minimale_sol \
  --ground-max-field altitude_maximale_sol \
  --roof-min-field altitude_minimale_toit \
  --roof-max-field altitude_maximale_toit \
  --height-field hauteur \
  --verbose 1
```

Arguments :

- `--input` : GeoPackage de bâtiments d'entrée (lecture seule)
- `--output` : GeoPackage de sortie créé par le script
- `--layer` : nom de la couche de bâtiments dans le GeoPackage (par défaut : `buildings`)
- `--ground-min-field` : nom du champ pour l'`altitude minimale du sol` (par défaut : `altitude_minimale_sol`)
- `--ground-max-field` : nom du champ pour l'`altitude maximale du sol` (par défaut : `altitude_maximale_sol`)
- `--roof-min-field` : nom du champ pour l'`altitude minimale du toit` (par défaut : `altitude_minimale_toit`)
- `--roof-max-field` : nom du champ pour l'`altitude maximale du toit` (par défaut : `altitude_maximale_toit`)
- `--height-field` : nom du champ pour la `hauteur du bâtiment` (par défaut : `hauteur`)
- `--verbose` : niveau de verbosité :
    - `0` : mode silencieux
    - `1` : étapes principales de traitement et résumé
    - `2` : diagnostics SQL détaillés et statistiques par étape


## Notes

- L'image d'exécution est `3dgi/3dbag-pipeline-tools:2026.06.24`.
- Les binaires des outils de cette image se trouvent sous `/opt/3dbag-pipeline/tools/bin`, c'est pourquoi le traitement exporte explicitement ce chemin avant d'exécuter GDAL, PDAL et roofer.
- Le téléchargement des bâtiments utilise le pilote WFS de GDAL via `ogr2ogr`.
- `roofer` traite les polygones d'entrée uniquement comme des emprises 2D (*roofprints*) et ignore tout `Z` présent dans leur géométrie. Toutes les altitudes sont dérivées du nuage de points LiDAR, les attributs `altitude_*` n'étant utilisés que comme valeurs de repli (voir l'étape 8). Le téléchargement des bâtiments aplatit donc les géométries en 2D (`ogr2ogr -dim 2`), ce qui est sans perte pour ce traitement puisque le `Z` des polygones serait de toute façon ignoré par `roofer`.
- L'implémentation s'appuie sur la prise en charge de la pagination par GDAL et n'implémente aucun code de pagination WFS personnalisé.
- L'extraction LiDAR conserve le découpage diffusé sur chaque entrée `readers.copc`. Elle ne découpe pas des dalles entières après téléchargement.
- La seule transformation spécifique au LiDAR dans cet exemple est le remappage de classe `67 -> 6`, qui aligne la classe *bâtis divers* de l'IGN sur la classe ASPRS `6` que `roofer` attend pour les bâtiments (voir l'étape 7).
- Le livrable final de ce traitement minimal est la sortie native `CityJSONSeq` de `roofer`.
- La taille de l'emprise détermine directement le temps d'exécution et la fiabilité. Une emprise plus grande signifie plus de bâtiments et plus de dalles LiDAR, tous récupérés via des requêtes WFS paginées : chaque page supplémentaire est un aller-retour réseau de plus qui peut expirer ou être interrompu côté serveur, de sorte que les très grandes zones sont à la fois plus lentes et plus susceptibles d'échouer en cours de téléchargement. L'emprise n'est volontairement pas plafonnée dans le code, car la bonne taille dépend de votre machine, de votre réseau et de votre patience. **Pour les grandes zones, privilégiez le découpage du travail en plusieurs exécutions plus petites plutôt que d'émettre une seule requête très volumineuse.** Le `--buffer` est une expansion secondaire appliquée automatiquement autour de l'étendue des bâtiments, il est donc plafonné à `500` mètres pour se prémunir contre des téléchargements incontrôlés accidentels.

## Références

- Page produit IGN LIDAR HD : <https://cartes.gouv.fr/rechercher-une-donnee/dataset/IGNF_NUAGES-DE-POINTS-LIDAR-HD>
- Descriptif de contenu IGN LIDAR HD (nomenclature de classification, incl. la classe `67`) : <https://geoservices.ign.fr/sites/default/files/2024-09/DC_LiDAR_HD_1-0.pdf>
- Page produit IGN BDTOPO : <https://cartes.gouv.fr/rechercher-une-donnee/dataset/IGNF_BD-TOPO>
- Descriptif de contenu IGN BDTOPO : <https://data.geopf.fr/annexes/ressources/documentation/DC_BDTOPO_3-5.pdf>
- Service WFS de l'IGN : <https://cartes.gouv.fr/aide/fr/guides-utilisateur/utiliser-les-services-de-la-geoplateforme/diffusion/wfs/>
- Prise en main de Roofer : <https://innovation.3dbag.nl/roofer/getting_started.html>
- Documentation CLI de Roofer : <https://innovation.3dbag.nl/roofer/cli_application.html>
- Prérequis d'entrée de Roofer : <https://innovation.3dbag.nl/roofer/data_requirements.html>
- PDAL `readers.copc` : <https://pdal.io/en/2.8.4/stages/readers.copc.html>
- PDAL `filters.assign` : <https://pdal.io/en/2.8.4/stages/filters.assign.html>
