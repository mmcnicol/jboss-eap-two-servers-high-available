FROM eclipse-temurin:11-jdk-jammy

ARG WILDFLY_VERSION=26.1.3.Final
ENV WILDFLY_VERSION=${WILDFLY_VERSION} \
    JBOSS_HOME=/opt/jboss/wildfly \
    PATH=/opt/jboss/wildfly/bin:$PATH

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl unzip netcat-openbsd \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -r jboss && useradd -r -g jboss -m -d /opt/jboss jboss

# Public download -- no Red Hat login needed. WILDFLY_VERSION is the open-source
# upstream release nearest to your JBoss EAP 7.4 (EAP 7.4's server core tracks
# WildFly ~26). Override with --build-arg WILDFLY_VERSION=x.y.z if you need a
# different one.
RUN curl -fL -o /tmp/wildfly.zip \
      "https://github.com/wildfly/wildfly/releases/download/${WILDFLY_VERSION}/wildfly-${WILDFLY_VERSION}.zip" \
    && unzip -q /tmp/wildfly.zip -d /opt/jboss \
    && mv /opt/jboss/wildfly-${WILDFLY_VERSION} ${JBOSS_HOME} \
    && rm /tmp/wildfly.zip \
    && chown -R jboss:jboss ${JBOSS_HOME}

COPY cli/ /opt/jboss/cli/
COPY entrypoint.sh /opt/jboss/entrypoint.sh

# Normalize line endings in case these files were edited/saved on Windows.
RUN sed -i 's/\r$//' /opt/jboss/entrypoint.sh /opt/jboss/cli/*.cli \
    && chmod +x /opt/jboss/entrypoint.sh \
    && chown -R jboss:jboss /opt/jboss/cli /opt/jboss/entrypoint.sh

USER jboss
WORKDIR ${JBOSS_HOME}

EXPOSE 8080 9990 9999

ENTRYPOINT ["/opt/jboss/entrypoint.sh"]
