FROM centos:7.2.1511
RUN rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
RUN rpm --import https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-7
RUN rpm --import https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-7Server
RUN rpm --import https://packages.erlang-solutions.com/rpm/erlang_solutions.asc
RUN yum install -y yum-plugin-ovl && yum clean all
RUN yum install -y wget iproute && yum clean all
RUN yum install -y epel-release && yum clean all
RUN yum groupinstall -y "Development Tools" "Development Libraries" && yum clean all
RUN wget http://packages.erlang-solutions.com/erlang-solutions-1.0-1.noarch.rpm
RUN rpm -Uvh erlang-solutions-1.0-1.noarch.rpm
RUN yum install -y esl-erlang-19.1 && yum clean all
RUN yum install -y python-pip && yum clean all
RUN pip install codecov

