FROM centos:7.2.1511
RUN yum install -y wget epel-release
RUN yum groupinstall -y "Development Tools" "Development Libraries"
RUN wget http://packages.erlang-solutions.com/erlang-solutions-1.0-1.noarch.rpm
RUN rpm -Uvh erlang-solutions-1.0-1.noarch.rpm
RUN yum install -y esl-erlang-19.1
