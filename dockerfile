# you can setup this variable to the version of python you want to use in .env file and build the image using docker-compose.yml file
ARG PYTHON_VERSION=3.10-bookworm

FROM python:$PYTHON_VERSION

ARG POSTGRESQL_VERSION

# install odoo dependencies
RUN apt update; \
    apt install -y wget software-properties-common build-essential libxslt-dev libzip-dev libldap2-dev libsasl2-dev node-less libpq-dev tmux xfonts-75dpi fontconfig libxrender1 xfonts-base libcups2-dev

RUN wget https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.bookworm_amd64.deb; \
    dpkg -i ./wkhtmltox_0.12.6.1-3.bookworm_amd64.deb; \
    rm ./wkhtmltox_0.12.6.1-3.bookworm_amd64.deb

RUN apt install -y cabextract; \
    wget http://ftp.jp.debian.org/debian/pool/contrib/m/msttcorefonts/ttf-mscorefonts-installer_3.8.1_all.deb; \
    dpkg -i ./ttf-mscorefonts-installer_3.8.1_all.deb; \
    rm ./ttf-mscorefonts-installer_3.8.1_all.deb

# install libreoffice only be needed if there is a module need to use libreoffice featrue
# RUN apt --no-install-recommends -y install libreoffice

RUN if [ -n "$POSTGRESQL_VERSION" ]; then \
        apt install -y postgresql-common; \
        bash /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y; \
        apt install -y postgresql-client-$POSTGRESQL_VERSION; \
    else \
        apt install -y postgresql-client; \
    fi

RUN groupadd -g 8069 odoo; \
    useradd -r -u 8069 -g 8069 -m -s /bin/bash odoo

RUN mkdir -p /var/log/odoo; \
    chown odoo: /var/log/odoo; \
    mkdir -p /opt/odoo; \
    chown odoo: /opt/odoo; \
    mkdir /var/lib/odoo; \
    chown odoo: /var/lib/odoo

COPY ./utilities/getinfo-odoo_base.sh /usr/local/bin/getinfo-odoo_base
COPY ./utilities/getinfo-odoo_git_addons.sh /usr/local/bin/getinfo-odoo_git_addons
RUN chmod 555 /usr/local/bin/getinfo-odoo_base; \
    chmod 555 /usr/local/bin/getinfo-odoo_git_addons

COPY --chown=odoo:odoo ./requirements.txt /opt/odoo/requirements.txt

USER odoo

WORKDIR /opt/odoo

RUN export MAKEFLAGS="-j $(nproc)"; \
    pip install -r ./requirements.txt

USER root

COPY --chown=odoo:odoo ./conf/odoo.conf /etc/odoo/odoo.conf

COPY --chown=odoo:odoo ./odoo-base /opt/odoo/odoo-base

COPY --chown=odoo:odoo ./utilities/odoo-shell /usr/local/bin/odoo-shell
COPY --chown=odoo:odoo ./utilities/odoo-module-upgrade /usr/local/bin/odoo-module-upgrade
RUN chmod 550 /usr/local/bin/odoo-shell; \
    chmod 550 /usr/local/bin/odoo-module-upgrade

COPY --chown=odoo:odoo ./entrypoint.sh /opt/odoo/entrypoint.sh
RUN chmod 550 /opt/odoo/entrypoint.sh

COPY --chown=odoo:odoo ./git /opt/odoo/git

USER odoo

# expose the default port of odoo (Will need to be set in the .env file and docker-compose.yml)
EXPOSE 8069
EXPOSE 8072

# set the command to run odoo instance using entrypoint.sh
ENTRYPOINT [ "/opt/odoo/entrypoint.sh" ]
