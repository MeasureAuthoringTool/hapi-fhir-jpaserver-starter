FROM alpine AS alpine
RUN wget -O newrelic-agent.jar https://download.newrelic.com/newrelic/java-agent/newrelic-agent/current/newrelic-agent.jar

FROM docker.io/library/maven:3.9.9-eclipse-temurin-17 AS build-hapi
WORKDIR /tmp/hapi-fhir-jpaserver-starter

COPY pom.xml .
COPY server.xml .
RUN mvn -ntp dependency:go-offline

COPY src/ /tmp/hapi-fhir-jpaserver-starter/src/
RUN mvn clean install -DskipTests -Djdk.lang.Process.launchMechanism=vfork

FROM build-hapi AS build-distroless
RUN mvn package -DskipTests spring-boot:repackage -Pboot
RUN mkdir /app && \
    cp /tmp/hapi-fhir-jpaserver-starter/target/ROOT.war /app/main.war


########### bitnami tomcat version is suitable for debugging and comes with a shell
########### it can be built using eg. `docker build --target tomcat .`
FROM bitnami/tomcat:10.1 AS tomcat

USER root
RUN rm -rf /opt/bitnami/tomcat/webapps/ROOT && \
    mkdir -p /opt/bitnami/hapi/data/hapi/lucenefiles && \
    chown -R 1001:1001 /opt/bitnami/hapi/data/hapi/lucenefiles && \
    chmod 775 /opt/bitnami/hapi/data/hapi/lucenefiles

RUN mkdir -p /target && chown -R 1001:1001 target
USER 1001

COPY --chown=1001:1001 catalina.properties /opt/bitnami/tomcat/conf/catalina.properties
COPY --chown=1001:1001 server.xml /opt/bitnami/tomcat/conf/server.xml
COPY --from=build-hapi --chown=1001:1001 /tmp/hapi-fhir-jpaserver-starter/target/ROOT.war /opt/bitnami/tomcat/webapps/ROOT.war
#COPY --from=build-hapi --chown=1001:1001 /tmp/hapi-fhir-jpaserver-starter/opentelemetry-javaagent.jar /app

ENV ALLOW_EMPTY_PASSWORD=yes

RUN curl -O https://s3.amazonaws.com/rds-downloads/rds-ca-2019-root.pem \
    && curl -O https://s3.amazonaws.com/rds-downloads/rds-ca-2019-us-east-1.pem \
    && keytool -import -keystore $JAVA_HOME/lib/security/cacerts -trustcacerts -storepass "changeit" -alias "AWSrdsRootCACert" -file rds-ca-2019-root.pem --noprompt \
    && keytool -import -keystore $JAVA_HOME/lib/security/cacerts -trustcacerts -storepass "changeit" -alias "AWSrdsIntCACert" -file rds-ca-2019-us-east-1.pem --noprompt \
    && rm -rf /usr/local/tomcat/conf/logging.properties


########### distroless brings focus on security and runs on plain spring boot - this is the default image
FROM gcr.io/distroless/java17-debian12:nonroot AS default
# 65532 is the nonroot user's uid
# used here instead of the name to allow Kubernetes to easily detect that the container
# is running as a non-root (uid != 0) user.
USER 65532:65532
WORKDIR /app
#CMD ["/app/main.war"]
#FROM tomcat:9-jdk11-corretto-al2

COPY --chown=nonroot:nonroot --from=build-distroless /app /app
COPY --chown=nonroot:nonroot --from=alpine newrelic-agent.jar /app/newrelic-agent.jar

ENTRYPOINT ["java", "--class-path", "/app/main.war", "-Dloader.path=main.war!/WEB-INF/classes/,main.war!/WEB-INF/,/app/extra-classes", "org.springframework.boot.loader.PropertiesLauncher"]
