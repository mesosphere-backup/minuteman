node('mesos') {
    stage 'build'
    docker.image('centos7').inside {
        sh 'wget https://packages.erlang-solutions.com/erlang/esl-erlang/FLAVOUR_1_general/esl-erlang_19.1~centos~7_amd64.rpm'
        sh 'rpm -ivh esl-erlang_19.1~centos~7_amd64.rpm'
        checkout scm
    }
}
