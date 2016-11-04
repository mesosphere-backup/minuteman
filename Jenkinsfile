node('mesos') {
    stage 'build'
    checkout scm
    def myImage = docker.build "erlang19.1"
    
    myImage.inside("--privileged=true --net=bridge") {
        checkout scm
        sh 'yum install -y yum install -y kernel-$(uname -r) && yum clean all'
        sh 'ip addr add 1.1.1.1/32 dev lo'
        sh 'ip addr add 1.1.1.2/32 dev lo'
        sh 'ip addr add 1.1.1.3/32 dev lo'
        sh 'mkdir /tmp/htdocs'
        sh 'modprobe ip_vs_wlc'
        sh 'make'
        sh 'make check'
        sh './elvis rock'
        sh './rebar3 cover'
        sh 'codecov -X gcov -f _build/test/covertool/minuteman.covertool.xml'
    }
}
