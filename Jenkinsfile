node('mesos') {
    stage 'build'
    def centos7 = docker.image('centos7.2.1511');
    centos7.pull();

    centos7.inside {
        sh 'wget https://packages.erlang-solutions.com/erlang/esl-erlang/FLAVOUR_1_general/esl-erlang_19.1~centos~7_amd64.rpm'
        sh 'rpm -ivh esl-erlang_19.1~centos~7_amd64.rpm'
        checkout scm
        sh 'ip link add webserver type dummy'
        sh 'ip link set webserver up'
        sh 'ip addr add 1.1.1.1/32 dev webserver'
        sh 'ip addr add 1.1.1.2/32 dev webserver'
        sh 'ip addr add 1.1.1.3/32 dev webserver'
        sh 'mkdir /tmp/htdocs'
        sh 'modprobe ip_vs_wlc'
        sh 'make'
        sh 'make check'
        sh './elvis rock'
    }
}
