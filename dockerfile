# use python3.8 as base image
FROM python:3.8-bookworm

# install gcsfuse dependencies
RUN apt update && \
    apt install -y nfs-common

# install odoo dependencies
RUN apt -y install git build-essential libxslt-dev libzip-dev libldap2-dev libsasl2-dev node-less libpq-dev

# create an odoo user and give that user sudo privilege
RUN groupadd -g 8069 odoo
RUN useradd -r -u 8069 -g 8069 -m -s /bin/bash odoo
# RUN echo "odoo ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# copy the source code to the image
RUN mkdir /opt/odoo
RUN mkdir /opt/odoo/datadir

COPY ./conf/odoo.conf /etc/odoo/odoo.conf
COPY ./git /opt/odoo/git
COPY ./odoo-base /opt/odoo/odoo-base

# set the working directory to /opt/odoo
WORKDIR /opt/odoo

# install odoo python dependecies
RUN export MAKEFLAGS="-j $(nproc)"
RUN pip install wheel
RUN pip install -r ./odoo-base/requirements.txt

# expose the default port of odoo
EXPOSE 8069
EXPOSE 8072

# set the command to run odoo instance using entrypoint.sh
ENTRYPOINT ["python", "/opt/odoo/odoo-base/odoo-bin"]
CMD ["-c", "/etc/odoo/odoo.conf"]

