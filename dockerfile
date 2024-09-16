# use python3.7 as base image
# FROM python:3.8-bookworm
# FROM python:3.10-bookworm
FROM python:3.7-bookworm

# install odoo dependencies
RUN apt -y install wget software-properties-common build-essential libxslt-dev libzip-dev libldap2-dev libsasl2-dev node-less libpq-dev tmux xfonts-75dpi fontconfig libxrender1 xfonts-base libcups2-dev
RUN apt --no-install-recommends -y install libreoffice
RUN wget https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.bookworm_amd64.deb
RUN dpkg -i ./wkhtmltox_0.12.6.1-3.bookworm_amd64.deb

# create an odoo user and give that user sudo privilege
RUN groupadd -g 8069 odoo
RUN useradd -r -u 8069 -g 8069 -m -s /bin/bash odoo
# RUN echo "odoo ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# copy the source code to the image
COPY ./entrypoint.sh /opt/odoo/entrypoint.sh
RUN chmod 550 /opt/odoo/entrypoint.sh

COPY ./git /opt/odoo/git
COPY ./odoo-base /opt/odoo/odoo-base
COPY ./requirements.txt /opt/odoo/requirements.txt

RUN mkdir -p /opt/odoo/datadir
RUN chown -R odoo: /opt/odoo

COPY ./conf/odoo.conf /etc/odoo/odoo.conf
RUN chown odoo: /etc/odoo/odoo.conf

# set the working directory to /opt/odoo
WORKDIR /opt/odoo

# install odoo python dependecies
RUN export MAKEFLAGS="-j $(nproc)"
RUN pip install -r ./requirements.txt

# expose the default port of odoo
EXPOSE 8069
EXPOSE 8072

USER odoo

# set the command to run odoo instance using entrypoint.sh
ENTRYPOINT [ "/opt/odoo/entrypoint.sh" ]
CMD ["-c", "/etc/odoo/odoo.conf"]
