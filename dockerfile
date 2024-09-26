# use python3.7 as base image
# FROM python:3.8-bookworm
# FROM python:3.10-bookworm
FROM python:3.7-bookworm

# install odoo dependencies
RUN apt update
RUN apt install -y wget software-properties-common build-essential libxslt-dev libzip-dev libldap2-dev libsasl2-dev node-less libpq-dev tmux xfonts-75dpi fontconfig libxrender1 xfonts-base libcups2-dev
RUN apt install -y postgresql-client

RUN wget https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.bookworm_amd64.deb
RUN dpkg -i ./wkhtmltox_0.12.6.1-3.bookworm_amd64.deb
RUN rm ./wkhtmltox_0.12.6.1-3.bookworm_amd64.deb

RUN apt install -y cabextract
RUN wget http://ftp.jp.debian.org/debian/pool/contrib/m/msttcorefonts/ttf-mscorefonts-installer_3.8.1_all.deb
RUN dpkg -i ./ttf-mscorefonts-installer_3.8.1_all.deb
RUN rm ./ttf-mscorefonts-installer_3.8.1_all.deb

# install libreoffice only be needed if there is a module need to use libreoffice featrue
# RUN apt --no-install-recommends -y install libreoffice

RUN groupadd -g 8069 odoo
RUN useradd -r -u 8069 -g 8069 -m -s /bin/bash odoo

RUN mkdir -p /var/log/odoo && \
    chown odoo: /var/log/odoo && \
    mkdir -p /opt/odoo && \
    chown odoo: /opt/odoo

RUN mkdir /opt/odoo/datadir && \
    chown odoo: /opt/odoo/datadir

COPY --chown=odoo:odoo ./entrypoint.sh /opt/odoo/entrypoint.sh
RUN chmod 550 /opt/odoo/entrypoint.sh

COPY --chown=odoo:odoo ./conf/odoo.conf /etc/odoo/odoo.conf
COPY --chown=odoo:odoo ./odoo-base /opt/odoo/odoo-base
COPY --chown=odoo:odoo ./requirements.txt /opt/odoo/requirements.txt

USER odoo

WORKDIR /opt/odoo

RUN export MAKEFLAGS="-j $(nproc)"
RUN pip install -r ./requirements.txt

USER root

COPY --chown=odoo:odoo ./git /opt/odoo/git

USER odoo

# expose the default port of odoo (Will need to be set in the .env file and docker-compose.yml)
EXPOSE 8069
EXPOSE 8072

# set the command to run odoo instance using entrypoint.sh
ENTRYPOINT [ "/opt/odoo/entrypoint.sh" ]
CMD [ "-c", "/etc/odoo/odoo.conf" ]
