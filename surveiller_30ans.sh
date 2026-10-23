#!/usr/bin/env bash
# Surveille les produits Pokémon « 30 ans » (et surtout l'UPC 30 ans, FR et EN) sur :
#   cardmaniac.ch, tamoricards.ch, poke-swiss.ch (Shopify)
#   geek-online.ch, mix-image.ch               (WooCommerce)
# et envoie une notification sur le téléphone via ntfy.
#
# Alertes :
#   🔥 UPC 30 ans commandable (achat ou précommande)            priorité 5
#   👀 Nouvelle fiche UPC 30 ans (pas encore commandable)        priorité 4
#   ✅ Produit 30 ans de nouveau disponible / précommande ouverte priorité 4
#   🆕 Nouveau produit 30 ans en ligne                            priorité 3
#   ℹ️ Produit ajouté (même caché) dans une catégorie 30 ans      priorité 3
#   ⚠️ Un site ne répond plus depuis 30 min (et quand il revient) priorité 3
#
# Pour ne pas se faire bloquer, chaque site est interrogé avec modération
# (Shopify toutes les 3 min, WooCommerce toutes les 2 min) et laissé en pause
# automatiquement s'il répond « trop de requêtes ».
#
# Usage :
#   NTFY_TOPIC=mon-sujet ./surveiller_30ans.sh             # boucle infinie
#   NTFY_TOPIC=mon-sujet ./surveiller_30ans.sh --test      # notification de test
#   NTFY_TOPIC=x ./surveiller_30ans.sh --apercu            # affiche ce qui est vu, sans notifier
# Variables facultatives : DUREE_MAX (s, 0 = sans limite), ETAT_FICHIER,
#   NOTIF_DEMARRAGE (1 par défaut ; 0 = pas de message « surveillance démarrée »).
#
# Dépendances : bash, curl, jq, perl (présents sur macOS et sur GitHub Actions).

set -u

DUREE_MAX="${DUREE_MAX:-0}"
NOTIF_DEMARRAGE="${NOTIF_DEMARRAGE:-1}"
ETAT="${ETAT_FICHIER:-$(dirname "$0")/etat_30ans.tsv}"
TOPIC="${NTFY_TOPIC:?Définis NTFY_TOPIC (le nom de ton sujet ntfy)}"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36"
PANNE_APRES=1800      # alerte si un site ne répond plus depuis 30 min
PAUSE_MIN=600         # pause minimale après un « trop de requêtes » (10 min)
PAUSE_MAX=3600        # pause maximale (1 h)

# --- Filtres sur les titres (insensibles à la casse)
TRENTE_ANS='\b30 ?(ans|jahre|th|e\b|ᵉ)|30-jahre|me ?5\.5'
UPC='ultra.?premium|\bupc\b'
ANCIENNE_UPC='sword|shield|épée|bouclier|swsh|terapagos|charizard|glurak|dracaufeu|\b151\b|\b20(1[0-9]|2[0-5])\b'
SCELLE='display|etb|elite|dresseur|top-trainer|bundle|booster|blister|tripack|tin|coffret|collection|kollektion|box|poster|classeur|binder|ordner|sticker|premium|upc|deck|pack'
EXCLURE='\b(jp|jpn|jap)\b|japan|japonais|japanisch|chinese|chinois|korean|coréen'

# --- Sites : « nom|type|adresse|chemins (Shopify) ou recherches (WooCommerce)|catégories à compter|intervalle (s) »
SITES=(
  "cardmaniac|shopify|https://cardmaniac.ch|/collections/pokemon-sammelkartenspiel-30-jahre/products.json?limit=250 /collections/pre-order/products.json?limit=250 /products.json?limit=100|pokemon-sammelkartenspiel-30-jahre pre-order|180"
  "tamoricards|shopify|https://tamoricards.ch|/products.json?limit=250||180"
  "poke-swiss|shopify|https://poke-swiss.ch|/collections/precommande-pokemon-30th-celebration/products.json?limit=250 /collections/coffrets-coffrets-premium/products.json?limit=250 /products.json?limit=100|precommande-pokemon-30th-celebration coffrets-coffrets-premium|180"
  "geek-online|woo|https://geek-online.ch|30 30th celebration ultra+premium||120"
  "mix-image|woo|https://mix-image.ch|30 30th celebration ultra+premium||120"
)

APERCU=0
notifier() { # priorité, titre, message, lien
  echo "$(date '+%F %T') [$1] $2 — $3 ${4:-}"
  (( APERCU )) && return
  curl -s -o /dev/null --max-time 15 \
    -H "Title: $2" -H "Priority: $1" -H "Tags: pokemon" ${4:+-H "Click: $4"} \
    -d "$3" "https://ntfy.sh/$TOPIC"
}
journal() { echo "$(date '+%F %T') $*"; }

case "${1:-}" in
  --test)   notifier 5 "Test alerte Pokémon 30 ans" "Les notifications fonctionnent ✅" "https://cardmaniac.ch"; exit 0 ;;
  --apercu) APERCU=1 ;;
esac

DIR="$(mktemp -d)"; trap 'rm -rf "$DIR"' EXIT

# Télécharge une adresse dans un fichier ; affiche le code HTTP (000 si pas de réponse).
telecharger() { # url, fichier
  local code
  code="$(curl -s -A "$UA" --max-time 20 -D "$DIR/entetes" -o "$2" -w '%{http_code}' "$1" 2>/dev/null)"
  echo "${code:-000}"
}

# Interroge un site. Écrit « clé<TAB>dispo<TAB>titre<TAB>prix<TAB>lien » dans $DIR/donnees.
# Retour : 0 = OK, 1 = erreur, 2 = « trop de requêtes » (site à laisser en pause).
interroger() { # type, adresse, chemins, catégories
  local type="$1" base="$2" chemins="$3" categories="$4" c code
  : > "$DIR/brut"; : > "$DIR/donnees"
  for c in $chemins; do
    if [[ "$type" == shopify ]]; then
      code="$(telecharger "$base$c" "$DIR/page")"
    else
      code="$(telecharger "$base/wp-json/wc/store/v1/products?search=$c&per_page=100" "$DIR/page")"
    fi
    [[ "$code" == 429 || "$code" == 430 || "$code" == 503 ]] && return 2
    [[ "$code" == 200 ]] || return 1
    if [[ "$type" == shopify ]]; then
      jq -c '.products[]?' "$DIR/page" >> "$DIR/brut" 2>/dev/null || return 1
    else
      jq -c '.[]?' "$DIR/page" >> "$DIR/brut" 2>/dev/null || return 1
    fi
  done

  if [[ "$type" == shopify ]]; then
    jq -rs --arg site "$base" 'unique_by(.id)[]
      | . as $p
      | (if (.variants | length) > 1 then .variants[] else .variants[0] end) as $v
      | ($p.title + (if ($p.variants | length) > 1 then " (" + $v.title + ")" else "" end)) as $titre
      | [$site + "/products/" + $p.handle + "#" + ($v.id | tostring),
         ($v.available | tostring), $titre, "CHF " + $v.price,
         $site + "/products/" + $p.handle] | @tsv' "$DIR/brut" > "$DIR/donnees" || return 1
    # Nombre de produits par catégorie, y compris les produits encore cachés.
    if [[ -n "$categories" ]]; then
      code="$(telecharger "$base/collections.json?limit=250" "$DIR/page")"
      [[ "$code" == 429 || "$code" == 430 ]] && return 2
      [[ "$code" == 200 ]] && jq -r --arg site "$base" --arg l "$categories" '.collections[]?
        | select(.handle as $h | ($l | split(" ") | index($h)))
        | ["compte:" + $site + "/collections/" + .handle, (.products_count | tostring),
           "Catégorie « " + .title + " »", "", $site + "/collections/" + .handle] | @tsv' \
        "$DIR/page" >> "$DIR/donnees" 2>/dev/null
    fi
  else
    jq -rs 'unique_by(.id)[]
      | [.permalink, ((.is_in_stock or .is_on_backorder) | tostring),
         (.name | gsub("&#8211;"; "–") | gsub("&#8217;"; "’") | gsub("&amp;"; "&") | gsub("&#[0-9]+;"; "")),
         "CHF " + (((.prices.price | tonumber) / pow(10; .prices.currency_minor_unit)) | tostring),
         .permalink] | @tsv' "$DIR/brut" > "$DIR/donnees" || return 1
  fi
  return 0
}

# Garde les produits 30 ans scellés (hors JP/CN/KR) et toutes les nouvelles UPC ; marque les UPC.
filtrer() {
  perl -CSD -Mutf8 -ne '
    chomp; my ($cle, $dispo, $titre, $prix, $lien) = split /\t/;
    if ($cle =~ /^compte:/) { print "$_\tcompte\n"; next }
    next if $titre =~ /'"$EXCLURE"'/i;
    my $upc = $titre =~ /'"$UPC"'/i && $titre !~ /'"$ANCIENNE_UPC"'/i;
    my $trente = $titre =~ /'"$TRENTE_ANS"'/i && $titre =~ /'"$SCELLE"'/i;
    print "$_\t", ($upc ? "upc" : "30ans"), "\n" if $upc || $trente;'
}

# Compare avec l'état précédent, écrit les alertes (« prio<TAB>titre<TAB>message<TAB>lien »)
# sur la sortie standard et met à jour le fichier d'état.
comparer() { # fichier_nouveau, premier_passage(0/1)
  perl -CSD -Mutf8 -e '
    my ($etat, $nouveau, $premier) = @ARGV; my (%ancien, %vu);
    if (open my $f, "<", $etat) { while (<$f>) { chomp; my @c = split /\t/; $ancien{$c[0]} = \@c } }
    open my $n, "<", $nouveau or die;
    while (<$n>) {
      chomp; my ($cle, $dispo, $titre, $prix, $lien, $type) = split /\t/; next unless $cle;
      $vu{$cle} = [$cle, $dispo, $titre, $prix, $lien, $type];
      my $a = $ancien{$cle}; my ($site) = $lien =~ m{https?://([^/]+)};
      if ($type eq "compte") {
        print "3\tℹ️ $site : produit ajouté dans une catégorie 30 ans\t$titre : $a->[1] → $dispo produits (souvent une future précommande)\t$lien\n"
          if $a && $dispo > $a->[1];
        next;
      }
      if ($type eq "upc") {
        if ($dispo eq "true" && (!$a || $a->[1] ne "true")) {
          print "5\t🔥 UPC 30 ANS COMMANDABLE sur $site\t$titre — $prix\t$lien\n";
        } elsif (!$a && !$premier) {
          print "4\t👀 Nouvelle fiche UPC sur $site (pas encore commandable)\t$titre — $prix\t$lien\n";
        }
        next;
      }
      next if $premier;
      if (!$a) {
        print "3\t🆕 Nouveau produit 30 ans sur $site\t$titre — $prix" . ($dispo eq "true" ? " (disponible)" : " (pas encore disponible)") . "\t$lien\n";
      } elsif ($dispo eq "true" && $a->[1] ne "true") {
        print "4\t✅ Disponible sur $site\t$titre — $prix\t$lien\n";
      }
    }
    # On garde aussi les anciennes entrées (un site injoignable ne doit pas tout « oublier »).
    $vu{$_} //= $ancien{$_} for keys %ancien;
    open my $o, ">", "$etat.tmp" or die; print $o join("\t", @{$vu{$_}}), "\n" for sort keys %vu; close $o;
    rename "$etat.tmp", $etat;
  ' "$ETAT" "$1" "$2"
}

# --- État par site, en mémoire : prochain passage, dernier succès, pause actuelle, panne signalée
lire()   { cat "$DIR/$1_$2" 2>/dev/null || echo "${3:-0}"; }
ecrire() { echo "$3" > "$DIR/$1_$2"; }

# --- Boucle principale

etat_vide=0; [[ -s "$ETAT" ]] || etat_vide=1
debut=$(date +%s)
for s in "${SITES[@]}"; do ecrire "${s%%|*}" ok "$debut"; done
journal "Démarrage (état : $ETAT)"
premier_tour=1

while :; do
  maintenant=$(date +%s)
  for s in "${SITES[@]}"; do
    IFS='|' read -r nom type base chemins categories intervalle <<< "$s"
    (( maintenant >= $(lire "$nom" prochain) )) || continue

    interroger "$type" "$base" "$chemins" "$categories"; resultat=$?
    maintenant=$(date +%s)

    if (( resultat == 0 )); then
      ecrire "$nom" ok "$maintenant"; ecrire "$nom" pause 0
      ecrire "$nom" prochain $(( maintenant + intervalle ))
      if [[ -f "$DIR/panne_$nom" ]]; then
        rm -f "$DIR/panne_$nom"
        notifier 3 "✅ $nom répond de nouveau" "La surveillance de $nom a repris normalement." "$base"
      fi
      filtrer < "$DIR/donnees" > "$DIR/filtre"
      ecrire "$nom" nb "$(grep -vc $'\tcompte$' "$DIR/filtre")"
      if (( APERCU )); then
        awk -F'\t' '{ printf "%-5s | %-6s | %s | %s\n", $2, $6, $3, $4 }' "$DIR/filtre"
        continue
      fi
      premier=0; (( etat_vide )) && [[ ! -f "$DIR/vu_$nom" ]] && premier=1
      touch "$DIR/vu_$nom"
      while IFS=$'\t' read -r prio titre message lien; do
        notifier "$prio" "$titre" "$message" "$lien"
      done < <(comparer "$DIR/filtre" "$premier")
    elif (( resultat == 2 )); then
      pause=$(lire "$nom" pause); pause=$(( pause * 2 )); (( pause < PAUSE_MIN )) && pause=$PAUSE_MIN; (( pause > PAUSE_MAX )) && pause=$PAUSE_MAX
      ecrire "$nom" pause "$pause"; ecrire "$nom" prochain $(( maintenant + pause ))
      journal "$nom : trop de requêtes, pause de $(( pause / 60 )) min"
    else
      ecrire "$nom" prochain $(( maintenant + intervalle ))
      journal "$nom : pas de réponse valable, nouvel essai dans $(( intervalle / 60 )) min"
    fi

    # Panne prolongée : prévenir une seule fois.
    if (( maintenant - $(lire "$nom" ok) >= PANNE_APRES )) && [[ ! -f "$DIR/panne_$nom" ]]; then
      touch "$DIR/panne_$nom"
      notifier 3 "⚠️ $nom ne répond plus" "Pas de réponse valable depuis plus de 30 min. Le script réessaie automatiquement." "$base"
    fi
  done

  if (( premier_tour )); then
    premier_tour=0
    resume=""; total=0
    for s in "${SITES[@]}"; do
      nom="${s%%|*}"
      if [[ "$(lire "$nom" ok)" -gt "$debut" ]]; then n=$(lire "$nom" nb); total=$(( total + n )); resume="$resume $nom ✅($n)"
      else resume="$resume $nom ⏸"; fi
    done
    journal "Premier tour :$resume"
    (( APERCU )) && exit 0
    (( NOTIF_DEMARRAGE )) && notifier 2 "Surveillance Pokémon 30 ans démarrée" \
      "$total produits 30 ans suivis.$resume (⏸ = site en pause, nouvel essai automatique)"
  fi

  if (( DUREE_MAX > 0 && $(date +%s) - debut >= DUREE_MAX )); then
    journal "Durée maximale atteinte, arrêt."; exit 0
  fi
  sleep 20
done
