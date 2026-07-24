FROM eclipse-temurin:17-jre

COPY *.jar /dist/app.jar

WORKDIR /dist

ENV SERVER_PORT=8080

ENTRYPOINT [ "java", "-jar", "app.jar" ]

EXPOSE ${SERVER_PORT}