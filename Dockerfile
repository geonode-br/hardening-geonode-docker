ARG DEBIAN_VERSION=bullseye
ARG PYTHON_VERSION=3.8

ARG GEONODE_UID=830
ARG GEONODE_GID=${GEONODE_UID}
ARG GEONODE_HOME=/var/lib/geonode
ARG GEONODE_PROJECT_NAME=geonode_project

# Multi-Stage build + Virtualenv
FROM python:${PYTHON_VERSION}-${DEBIAN_VERSION} AS BUILDER

ARG GEONODE_HOME
ARG GEONODE_PROJECT_NAME

WORKDIR ${GEONODE_HOME}

# Install apt dependencies
RUN apt-get -y update && \
    apt-get install -y \
        # builders
        devscripts \
        build-essential \
        debhelper \
        pkg-kde-tools \
        sharutils \
        # devels
        libgdal-dev \
        libpq-dev \
        libxml2-dev \
        libxslt1-dev \
        zlib1g-dev \
        libjpeg-dev \
        libmemcached-dev \
        libffi-dev \
        # geonode-ldap
        libldap2-dev \
        libsasl2-dev && \
    apt-get -y autoremove && \
    rm -rf /var/lib/apt/lists/*

# create virutalenv
RUN set -xe && \
    python -m venv --symlinks venv && \
    # upgrade basics
    venv/bin/python -m pip install --upgrade \
        wheel

# copy only requirements
COPY src/requirements.txt /tmp

# install geonode project
RUN set -xe && \
    # extra deps
    venv/bin/python -m pip install \
        pygdal==$(gdal-config --version).* \
        flower==0.9.4 && \
    venv/bin/python -m pip install \
        pylibmc \
        sherlock && \
    # geonode base (requirements.txt)
    venv/bin/python -m pip install --upgrade -r /tmp/requirements.txt && \
    # geonode contribs (installed after geonode, because geonode-ldap was installing the latest geonode version, then downgrade to requirements' version)
    venv/bin/python -m pip install \
        "git+https://github.com/GeoNode/geonode-contribs.git#egg=geonode-logstash&subdirectory=geonode-logstash" && \
    venv/bin/python -m pip install \
        "git+https://github.com/GeoNode/geonode-contribs.git#egg=geonode-ldap&subdirectory=ldap" && \
    # clean pip cache
    venv/bin/python -m pip cache purge && \    
    echo "Checking Virtualenv: $(venv/bin/python -m pip check)"

# RUN venv/bin/python -m pip freeze | grep -i geonode && sleep 10000

ARG DEBIAN_VERSION
ARG PYTHON_VERSION

# Release version
FROM python:${PYTHON_VERSION}-slim-${DEBIAN_VERSION} AS RELEASE

ARG GEONODE_UID
ARG GEONODE_GID
ARG GEONODE_HOME
ARG GEONODE_PROJECT_NAME

LABEL maintainer="NDS CPRM"

RUN apt-get -y update && \
    apt-get install -y --no-install-recommends --no-install-suggests \
        zip gettext geoip-bin cron curl \
        postgresql-client-13 memcached \
        sqlite3 spatialite-bin libsqlite3-mod-spatialite \
        libgdal28 libmemcached11 libxslt1.1 \
        gosu cowsay \
        # geonode-ldap
        libldap-2.4-2 \
        libsasl2-2 && \
        # git firefox-esr && \
    ln -s /usr/games/cowsay /usr/bin/cowsay && \
    apt-get -y autoremove && \
    rm -rf /var/lib/apt/lists/*

# Create a geonode user and put shell to load the geonode virtualenv
RUN groupadd -g ${GEONODE_UID} geonode && \
    useradd -g ${GEONODE_GID} -u ${GEONODE_UID} -m -d ${GEONODE_HOME} -s /usr/sbin/nologin geonode && \
    # geonode dirs (logs, statics)
    mkdir -p /mnt/volumes/statics && \
    ln -s /mnt/volumes/statics ${GEONODE_HOME}/statics && \
    # add geonode virtualenv to root and geonode user
    printf "\n# GeoNode VirtualEnv\nalias activate='source %s/venv/bin/activate'\n" ${GEONODE_HOME} | tee -a ~/.bashrc >> ${GEONODE_HOME}/.bashrc && \ 
    echo "printf \"Welcome to GeoNode! Type \'activate\' on shell to initialize the VirtualEnv\" | cowsay -f tux" | tee -a ~/.bashrc >> ${GEONODE_HOME}/.bashrc && \
    # grant content to user geonode
    chown -R geonode:geonode /mnt/volumes/statics ${GEONODE_HOME}/statics ${GEONODE_HOME}/.bashrc    

# Copy virtualenv made in BUILDER
COPY --from=BUILDER ${GEONODE_HOME}/venv ${GEONODE_HOME}/venv

# Copy geonode_project source code
COPY src ${GEONODE_HOME}/venv/src/${GEONODE_PROJECT_NAME}

WORKDIR ${GEONODE_HOME}  

ENV GEONODE_HOME=${GEONODE_HOME} \
    GEONODE_PROJECT_NAME=${GEONODE_PROJECT_NAME}

# Install and configure GeoNode Project on RELEASE
RUN set -xe && \
    # install geonode project (setup.py)
    venv/bin/python -m pip install --upgrade -e venv/src/${GEONODE_PROJECT_NAME} && \
    venv/bin/python -m pip cache purge && \    
    echo "Checking Virtualenv: $(venv/bin/python -m pip check)" && \
    # configure uWSGI and celery scripts    
    chmod +x venv/src/${GEONODE_PROJECT_NAME}/celery.sh \
        venv/src/${GEONODE_PROJECT_NAME}/celery-cmd \
        venv/src/${GEONODE_PROJECT_NAME}/uwsgi-cmd && \
    ln -s $(pwd)/venv/src/${GEONODE_PROJECT_NAME}/celery.sh /usr/bin/celery-commands && \
    ln -s $(pwd)/venv/src/${GEONODE_PROJECT_NAME}/celery-cmd /usr/bin/celery-cmd && \
    ln -s $(pwd)/venv/src/${GEONODE_PROJECT_NAME}/uwsgi-cmd /usr/bin/uwsgi-cmd && \
    # configure other scripts
    chmod +x venv/src/${GEONODE_PROJECT_NAME}/wait-for-databases.sh \
        venv/src/${GEONODE_PROJECT_NAME}/tasks.py \
        venv/src/${GEONODE_PROJECT_NAME}/entrypoint.sh && \
    ln -s $(pwd)/venv/src/${GEONODE_PROJECT_NAME}/wait-for-databases.sh /usr/bin/wait-for-databases

# configure system scripts
RUN set -xe && \
    # cron jobs
    mv venv/src/${GEONODE_PROJECT_NAME}/monitoring-cron /etc/cron.d/monitoring-cron && \
    chmod 0644 /etc/cron.d/monitoring-cron && \
    crontab /etc/cron.d/monitoring-cron && \
    touch /var/log/cron.log && \
    # entrypoint 
    ln -s ${GEONODE_HOME}/venv/src/${GEONODE_PROJECT_NAME}/entrypoint.sh /entrypoint.sh

# Export ports
EXPOSE 8000

# We provide no command or entrypoint as this image can be used to serve the django project or run celery tasks
# ENTRYPOINT [ "/entrypoint.sh" ]
