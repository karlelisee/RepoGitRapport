FROM ubuntu:24.04

# bash est déjà présent dans l'image ubuntu de base, pas besoin d'installer quoi que ce soit
COPY heartbeat.sh /heartbeat.sh
RUN chmod +x /heartbeat.sh

ENTRYPOINT ["/heartbeat.sh"]
CMD ["heartbeat"]
