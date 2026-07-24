terraform {
    required_providers {
        minikube = {
            source = "scott-the-programmer/minikube"
            version = "0.6"
        }

    }
}

provider "minikube" {   
}

provider "kubernetes {
    host = minikube_cluster.hexagone.host
    client_certificate = minikube_cluster.hexagone.client_certificate
    client_key = minikube_cluster.hexagone.client_key
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
        name = 
    }
}