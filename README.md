# Rapport de cours - Cloud & Kubernetes

Karl-Elisée Koffi - M1 IA, École Hexagone
Projet : déploiement de l'application `gc` (gestion clients) sur Kubernetes

## Contexte

Le but du cours était de déployer une application complète (API + web + base de données) en passant par toute la chaîne : conteneurisation, orchestration Kubernetes, packaging Helm, déploiement GitOps avec ArgoCD, et provisioning d'infra avec Terraform.

L'appli est composée de :
- une API en Java/Spring Boot (packagée en `.jar`, tourne sur `eclipse-temurin:17-jre`)
- un frontend web
- une base PostgreSQL
- Traefik en reverse proxy pour le routage local

## Conteneurisation avec Docker

Dockerfile de l'API :

```dockerfile
FROM eclipse-temurin:17-jre
COPY *.jar /dist/app.jar
WORKDIR /dist
ENV SERVER_PORT=8080
ENTRYPOINT [ "java", "-jar", "app.jar" ]
EXPOSE ${SERVER_PORT}
```

À retenir : partir d'un JRE plutôt qu'un JDK complet pour garder l'image légère, paramétrer le port via `ENV` plutôt que de le coder en dur, et la différence entre `ENTRYPOINT` (commande fixe) et `CMD`.

Le `docker-compose.yaml` orchestre l'environnement local complet :
- Traefik en reverse proxy, routage par labels (`PathPrefix`, `stripprefix`) plutôt que par ports exposés directement
- PostgreSQL avec persistance sur un volume monté (`./pgsql`)
- Dockhand pour la gestion visuelle des conteneurs
- API et Web, chacun routé via ses propres labels Traefik (`/api`, `/web`)
- un réseau dédié (`tp-db`) pour isoler les services
- un fichier `.env` pour ne pas coder les identifiants en dur

Ce qu'on en retient surtout : le rôle du reverse proxy pour exposer plusieurs services derrière un seul point d'entrée, le fait que `depends_on` ordonne juste le démarrage sans garantir que le service soit "prêt", et la différence entre variables injectées directement vs via `env_file`.

Le script `heartbeat.sh` (boucle infinie qui log périodiquement) a servi de conteneur de test simple pour observer le comportement de Kubernetes (redémarrage, logs, probes) sans dépendre d'une vraie application.

---

## Kubernetes et Minikube

Minikube pour lancer un cluster local sur Mac : `minikube start`, `minikube status`, `minikube dashboard`, `minikube delete`. On est tombé sur un problème classique de driver QEMU (fichier PID verrouillé après un arrêt brutal), réglé en supprimant et relançant le cluster (`minikube delete` puis `start`), avec l'option de passer sur le driver Docker pour plus de stabilité. Pour utiliser une image locale sans registry externe, il faut la builder dans l'environnement Docker de minikube (`eval $(minikube docker-env)`) et mettre `imagePullPolicy: Never` dans le manifest.

Ressources manipulées :

| Ressource | Rôle |
|---|---|
| Secret | données sensibles (mot de passe Postgres) en base64, injecté via `secretKeyRef` |
| ConfigMap | config non sensible (ex : nom de la base), injecté via `configMapKeyRef` |
| Deployment | état désiré de l'app : replicas, image, ports, env, rolling update |
| Service | expose un ensemble de pods (par `selector` sur des labels) à l'intérieur du cluster |
| Ingress | expose un Service à l'extérieur via un nom de domaine |
| PersistentVolumeClaim | stockage persistant (10Gi) pour que Postgres garde ses données entre redéploiements |

L'appli `gc` est découpée en trois Deployments + Services qui communiquent via le DNS interne de Kubernetes : `web` appelle l'API en `http://api`, l'API se connecte à la base en `jdbc:postgresql://bdd/gc`, et `bdd` (Postgres) utilise le PVC pour la persistance. Un Ingress route ensuite le trafic externe (`cloud.hexagone.fr`) vers le Service `web`.

Quelques points qui ont posé question ou valent la peine d'être notés :
- un Service ne pointe jamais un pod directement, il matche des labels - ça permet au Deployment de remplacer les pods sans casser la connectivité
- séparer Secret et ConfigMap est une bonne pratique même si les deux s'injectent pareil en variable d'env, seul le Secret est encodé
- le mot de passe Postgres a été créé directement en CLI plutôt que via un manifeste : `kubectl create secret generic bdd-secret --from-literal=password=pass123`
- les probes en `exec` (`pg_isready -U postgres`) servent pour les services qui n'ont pas d'endpoint HTTP à checker
- l'Ingress a besoin d'un Ingress Controller installé dans le cluster (l'addon `ingress` de minikube, vu aussi côté Terraform)
- un fichier YAML peut contenir plusieurs ressources séparées par `---`
- `kubectl apply -f fichier.yaml` cible un fichier précis, `kubectl apply -f .` applique tout un dossier - piège rencontré en appliquant par erreur un `docker-compose.yaml`, qui n'a pas les champs `apiVersion`/`kind` attendus par Kubernetes

Pour explorer le cluster sans taper `kubectl get` en boucle : le dashboard graphique (`minikube dashboard`) et surtout **k9s**, une interface terminal (TUI) qui reprend une syntaxe proche de kubectl (`:pods`, `:svc`, `:ns` pour changer de vue) et permet de voir les logs, ouvrir un shell dans un pod ou le supprimer directement depuis l'interface - pratique pour repérer vite un pod en `CrashLoopBackOff` ou `Pending`.

---

## Helm

Helm sert de gestionnaire de paquets pour Kubernetes : templatiser et versionner le déploiement plutôt que de dupliquer des manifestes bruts par environnement.

- `Chart.yaml` : métadonnées (nom, version du chart, `appVersion`)
- `values.yaml` : config par défaut injectée dans les templates (image, tag, replicas, ressources, ingress, autoscaling, probes...)
- `.helmignore` : exclut des fichiers du packaging, sur le modèle d'un `.gitignore`

Le vrai intérêt, c'est le templating (syntaxe Go) : `image: hexagone-api:{{ .Values.image.tag }}` dans le Deployment de l'API, ou `host: {{ .Values.host }}` dans l'Ingress - la valeur vient de `values.yaml` (`tag: "1.0"`, `host: "cloud.hexagone.fr"`) et peut être surchargée par environnement sans toucher aux templates.

Le fichier `NOTES.txt` s'affiche automatiquement après un `helm install`/`upgrade` réussi et peut lui aussi être templaté (ex : rappeler l'URL d'accès via `{{ .Values.host }}`).

Bonne pratique notée : ne pas fixer de limites de ressources par défaut, pour rester compatible avec des environnements contraints comme Minikube.

---

## ArgoCD (GitOps)

ArgoCD synchronise automatiquement le cluster avec l'état décrit dans un dépôt Git - principe du GitOps.

Installation dans un namespace dédié (`argocd`) via le manifeste officiel, accès à l'UI via `kubectl port-forward svc/argocd-server -n argocd 8080:443` (HTTPS avec certif auto-signé, avertissement navigateur normal), login `admin` avec le mot de passe récupéré dans le Secret `argocd-initial-admin-secret` (décodé en base64).

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gc
  namespace: argocd
spec:
  project: default
  source:
    repoURL: "https://github.com/karlelisee/gc-devops.git"
    targetRevision: main
    path: helm/gc-app
    helm:
      releaseName: gc-staging
  destination:
    server: "https://kubernetes.default.svc"
    namespace: gc-staging
  syncPolicy:
    automated:
      enabled: true
```

Une `Application` relie un dépôt Git à une destination dans le cluster ; `helm.releaseName` permet d'utiliser directement un chart Helm comme source ; `syncPolicy.automated` fait que tout push sur `main` est appliqué automatiquement, sans intervention manuelle.

## GitHub

Le dépôt `gc-devops` sert de source de vérité : code applicatif, charts Helm et manifestes K8s, référencé directement par ArgoCD (`repoURL`, `targetRevision`). Ça a permis de voir le principe de séparation entre dépôt applicatif et dépôt infra/config, courant en GitOps.

## Terraform

Terraform provisionne l'infra elle-même (le cluster), pas seulement les ressources à l'intérieur, via le provider `scott-the-programmer/minikube`.

```hcl
terraform {
    required_providers {
        minikube = {
            source  = "scott-the-programmer/minikube"
            version = "0.6"
        }
    }
}

provider "minikube" {}

provider "kubernetes" {
    host                   = minikube_cluster.hexagone.host
    client_certificate     = minikube_cluster.hexagone.client_certificate
    client_key             = minikube_cluster.hexagone.client_key
    cluster_ca_certificate = minikube_cluster.hexagone.cluster_ca_certificate
}

resource "minikube_cluster" "hexagone" {
    addons = [
        "ingress",
        "headlamp"
    ]
}

resource "kubernetes_namespace_v1" "gc_staging_ns" {
    metadata {
        name = "gc-staging"
    }
}
```

Le cluster Minikube est déclaré comme une ressource Terraform, avec ses addons (`ingress`, `headlamp`), plutôt que créé à la main. Les deux providers se chaînent : `minikube` crée le cluster, et ses sorties (host, certificats) alimentent le provider `kubernetes`, qui gère ensuite des ressources internes comme le namespace. Le fichier `.terraform.lock.hcl` verrouille les versions de providers pour garder l'infra reproductible entre environnements.

## Prometheus & Grafana

Vus comme la brique d'observabilité classique d'une stack cloud-native : Prometheus collecte et stocke les métriques (CPU, mémoire, requêtes HTTP, état des pods), Grafana les affiche en dashboards pour suivre la santé de l'appli et du cluster en temps réel, en complément des logs (`kubectl logs`) et du dashboard Kubernetes natif.

## Vue d'ensemble

Terraform provisionne le cluster (Minikube + addons) → Docker construit les images (API, Web) → GitHub héberge le code, les charts Helm et les manifestes K8s → Helm packages l'application → ArgoCD synchronise automatiquement le cluster avec le dépôt Git → Kubernetes fait tourner l'application (Deployments, Secrets, ConfigMaps, PVC, Services) → Prometheus/Grafana supervisent le tout.

## Ce que j'en retiens

- conteneuriser une appli Java avec Docker, orchestrer un environnement multi-services avec Compose et Traefik
- déployer et déboguer sur un cluster local (Minikube) : Secrets, ConfigMaps, Deployments, Services, PVC, Ingress
- diagnostiquer des erreurs courantes (mauvais fichier ciblé par `kubectl apply`, driver de VM bloqué, image introuvable dans le cluster)
- packager une appli avec Helm pour la rendre réutilisable entre environnements
- mettre en place un flux GitOps avec ArgoCD, où Git devient la source de vérité du cluster
- naviguer et déboguer un cluster rapidement en terminal avec k9s, en plus de kubectl et du dashboard
- provisionner l'infra elle-même avec Terraform plutôt qu'à la main
- comprendre le rôle de l'observabilité (Prometheus/Grafana) dans une stack cloud-native
